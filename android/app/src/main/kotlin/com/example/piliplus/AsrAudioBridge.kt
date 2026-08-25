package com.example.piliplus

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.EventChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * ASR 音频 PCM 桥：MediaCodec 解码音轨（URL）→ 16kHz 单声道 float PCM
 * 按块（20ms）节流推送，每块 320 个 float（LITTLE_ENDIAN 字节序）。
 * 事件：PCM 块 → byte[]；自然结束 → String "ended"
 */
class AsrAudioBridge(
    private val sink: EventChannel.EventSink?,
    private val context: Context,
) {

    companion object {
        private const val TAG = "AsrAudioBridge"
        private const val TARGET_RATE = 16000
        private const val BLOCK_SAMPLES = 320 // 20ms @16k
        private const val BLOCK_MS = 20L
        private const val PCM_16BIT = 2
        private const val PCM_FLOAT = 4
        private val MAIN = Handler(Looper.getMainLooper())
        private val UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
    }

    private var thread: Thread? = null
    private val lock = Object()
    @Volatile private var running = false
    // 调试：发送的 PCM 落盘（应用外部目录，便于 adb pull 对比验证）
    private var pcmOut: java.io.FileOutputStream? = null

    fun start(url: String, startMs: Long, note: String = "") {
        Log.i(TAG, "start urlLen=${url.length} startMs=$startMs note=$note")
        stop()
        try {
            val dir = context.getExternalFilesDir(null)
            if (dir != null) {
                val f = java.io.File(dir, "asr_pcm.raw")
                pcmOut = java.io.FileOutputStream(f)
                Log.i(TAG, "pcm dump -> ${f.absolutePath}")
            }
        } catch (_: Exception) {}
        running = true
        thread = Thread({
            try {
                decodeLoop(url, startMs)
            } catch (e: Exception) {
                Log.e(TAG, "decode failed: ${e.message}")
            } finally {
                synchronized(lock) { running = false }
                MAIN.post { sink?.success("ended") }
            }
        }, "asr-audio-decode").apply {
            isDaemon = true
            start()
        }
    }

    fun stop() {
        synchronized(lock) { running = false }
        thread?.interrupt()
        thread = null
        try {
            pcmOut?.flush()
            pcmOut?.close()
        } catch (_: Exception) {
        }
        pcmOut = null
    }

    /** 全速解码整段音轨 → 16k mono float32 LE 写文件（不节流，供整段识别生成字幕） */
    fun decodeAll(url: String, outPath: String) {
        Log.i(TAG, "decodeAll urlLen=${url.length} out=$outPath")
        stop()
        running = true
        thread = Thread({
            try {
                decodeLoop(url, 0L, dumpFile = java.io.File(outPath))
                Log.i(TAG, "decodeAll done: $outPath")
                MAIN.post { sink?.success("alldone:$outPath") }
            } catch (e: Exception) {
                Log.e(TAG, "decodeAll failed: ${e.message}")
                MAIN.post { sink?.success("allfailed:${e.message}") }
            } finally {
                synchronized(lock) { running = false }
            }
        }, "asr-audio-decode-all").apply {
            isDaemon = true
            start()
        }
    }

    private fun decodeLoop(url: String, startMs: Long, dumpFile: java.io.File? = null) {
        val extractor = MediaExtractor()
        var dumpOut: java.io.FileOutputStream? = null
        try {
            if (dumpFile != null) {
                dumpOut = java.io.FileOutputStream(dumpFile)
            }
            extractor.setDataSource(
                url,
                mapOf("User-Agent" to UA, "Referer" to "https://www.bilibili.com"),
            )
            val trackIndex = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it)
                    .getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: run {
                Log.e(TAG, "no audio track")
                return
            }
            extractor.selectTrack(trackIndex)
            val format = extractor.getTrackFormat(trackIndex)
            Log.i(
                TAG,
                "track=$trackIndex mime=${format.getString(MediaFormat.KEY_MIME)} " +
                    "rate=${format.getInteger(MediaFormat.KEY_SAMPLE_RATE)} " +
                    "ch=${format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)}",
            )
            val codec = MediaCodec.createDecoderByType(
                format.getString(MediaFormat.KEY_MIME)!!,
            )
            codec.configure(format, null, null, 0)
            codec.start()
            val info = MediaCodec.BufferInfo()
            val resampler = PcmResampler(dumpOut)
            var eos = false
            var outCount = 0
            // seek 到指定位置附近（fMP4 支持）；B 站 dash 音频为 fMP4
            extractor.seekTo(startMs * 1000L, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val startWall = SystemClock.elapsedRealtime()
            var firstPts = -1L

            while (running && !eos) {
                val inIdx = codec.dequeueInputBuffer(10_000)
                if (inIdx >= 0) {
                    val inBuf = codec.getInputBuffer(inIdx)!!
                    val sampleSize = extractor.readSampleData(inBuf, 0)
                    if (sampleSize < 0) {
                        codec.queueInputBuffer(
                            inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                        )
                        eos = true
                    } else {
                        codec.queueInputBuffer(inIdx, 0, sampleSize, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
                val outIdx = codec.dequeueOutputBuffer(info, 10_000)
                if (outIdx >= 0) {
                    val outBuf = codec.getOutputBuffer(outIdx)!!
                    if (info.size > 0 && info.presentationTimeUs >= startMs * 1000L) {
                        if (firstPts < 0) {
                            firstPts = info.presentationTimeUs
                            resampler.resetClock(startWall)
                        }
                        resampler.feed(outBuf, info, codec.outputFormat)
                        outCount++
                        if (outCount == 1 || outCount % 200 == 0) {
                            Log.i(
                                TAG,
                                "outBuf #$outCount pts=${info.presentationTimeUs} size=${info.size}",
                            )
                        }
                    }
                    codec.releaseOutputBuffer(outIdx, false)
                } else if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    // PCM 编码参数随后续 outputFormat 获取
                }
            }
            codec.stop()
            codec.release()
        } finally {
            try {
                dumpOut?.flush()
                dumpOut?.close()
            } catch (_: Exception) {
            }
            extractor.release()
        }
    }

    /** 解码 → 单声道 → 16k 重采样 → 分块（dumpFile 非空时全速写文件，否则节流推送） */
    private inner class PcmResampler(private val dumpFile: java.io.FileOutputStream?) {
        private var mono = FloatArray(16 * 1024)
        private var monoLen = 0
        private var nextBlockWall = 0L
        private var resetWall = 0L

        fun resetClock(wall: Long) {
            resetWall = wall
            nextBlockWall = wall
        }

        fun feed(buf: ByteBuffer, info: MediaCodec.BufferInfo, fmt: MediaFormat) {
            val enc = if (fmt.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                fmt.getInteger(MediaFormat.KEY_PCM_ENCODING)
            } else PCM_16BIT
            val ch = if (fmt.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            } else 2
            val rate = if (fmt.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            } else 48000

            buf.order(ByteOrder.LITTLE_ENDIAN)
            buf.position(info.offset)
            val size = info.size
            val bytesPerSample = if (enc == PCM_FLOAT) 4 else 2
            val totalSamples = size / bytesPerSample
            val frames = totalSamples / ch
            if (frames <= 0) return

            // 混音为单声道
            ensureMono(frames)
            if (enc == PCM_FLOAT) {
                for (f in 0 until frames) {
                    var s = 0f
                    for (c in 0 until ch) s += buf.float
                    mono[monoLen + f] = s / ch
                }
            } else {
                for (f in 0 until frames) {
                    var s = 0
                    for (c in 0 until ch) s += buf.short.toInt()
                    mono[monoLen + f] = s / ch / 32768f
                }
            }
            monoLen += frames

            // 重采样到 16k 并分块
            if (rate != TARGET_RATE) {
                resampleAndFlush(rate)
            } else {
                flushChunks()
            }
        }

        private fun ensureMono(extra: Int) {
            if (monoLen + extra > mono.size) {
                mono = mono.copyOf((monoLen + extra) * 2)
            }
        }

        private fun resampleAndFlush(rate: Int) {
            val ratio = rate.toDouble() / TARGET_RATE.toDouble()
            val outLen = (monoLen / ratio).toInt()
            val out = FloatArray(outLen)
            // 抗混叠：每个输出样本取输入窗（宽度≈ratio）的平均（box 低通）
            // 再抽取，抑制 48k/44.1k 高频混叠（纯线性插值会严重混叠导致识别胡话）
            val win = ratio.toInt() + 1
            val half = win / 2
            var oi = 0
            var srcPos = 0.0
            while (oi < outLen) {
                val center = srcPos.toInt()
                val start = (center - half).coerceAtLeast(0)
                val end = (center + half + 1).coerceAtMost(monoLen)
                if (start >= monoLen) break
                var sum = 0f
                for (k in start until end) sum += mono[k]
                out[oi] = sum / (end - start)
                oi++
                srcPos += ratio
            }
            mono = out
            monoLen = oi
            flushChunks()
        }

        private fun flushChunks() {
            var off = 0
            while (off + BLOCK_SAMPLES <= monoLen) {
                val block = FloatArray(BLOCK_SAMPLES)
                System.arraycopy(mono, off, block, 0, BLOCK_SAMPLES)
                sendBlock(block)
                off += BLOCK_SAMPLES
            }
            // 保留尾部不足一块的样本
            if (off > 0 && monoLen - off > 0) {
                System.arraycopy(mono, off, mono, 0, monoLen - off)
            }
            monoLen -= off
        }

        private fun sendBlock(block: FloatArray) {
            val bytes = ByteBuffer.allocate(block.size * 4).order(ByteOrder.LITTLE_ENDIAN)
            for (f in block) bytes.putFloat(f)
            // 全速模式：直接写文件（整段识别），不节流不推送
            if (dumpFile != null) {
                try {
                    dumpFile.write(bytes.array())
                } catch (_: Exception) {
                }
                return
            }
            val now = SystemClock.elapsedRealtime()
            val target = nextBlockWall
            val wait = target - now
            if (wait > 0) {
                try {
                    Thread.sleep(wait)
                } catch (_: InterruptedException) {
                }
            }
            // 解码落后太多时不累积偏差，改为从当前时间继续
            if (now - target > 500) nextBlockWall = now
            nextBlockWall += BLOCK_MS
            // 调试落盘（16k mono float32 LE）
            try {
                pcmOut?.write(bytes.array())
            } catch (_: Exception) {
            }
            MAIN.post { sink?.success(bytes.array()) }
        }
    }
}
