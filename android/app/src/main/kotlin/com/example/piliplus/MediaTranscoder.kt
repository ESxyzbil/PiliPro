package com.example.piliplus

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Handler
import android.os.Looper
import android.view.Surface
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer

/**
 * 把合并后的 MP4 转成 H.264 + AAC（Android / MediaCodec + MediaMuxer）。
 *
 * 策略与桌面端一致：已是 H.264 的视频轨、已是 AAC 的音频轨直接复制样本（不重编码、
 * 无损、快），其余编码（HEVC/AV1/FLAC/AC-3…）解码后重编码；某条轨道转码不可用时
 * 退化为复制该轨，保证仍能产出可播放的文件。
 */
class MediaTranscoder(private val channel: MethodChannel) {
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var busy = false

    fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "transcode" -> {
                val input = call.argument<String>("input")
                val output = call.argument<String>("output")
                if (input.isNullOrEmpty() || output.isNullOrEmpty()) {
                    result.error("bad_args", "缺少输入或输出路径", null)
                    return
                }
                if (busy) {
                    result.error("busy", "已有转码任务在进行", null)
                    return
                }
                busy = true
                Thread {
                    val outcome = try {
                        TranscodeJob(input, output, ::postProgress).run()
                    } catch (t: Throwable) {
                        Outcome(false, t.message ?: t.toString())
                    }
                    busy = false
                    mainHandler.post {
                        if (outcome.ok) {
                            result.success(
                                mapOf(
                                    "ok" to true,
                                    "videoAction" to outcome.videoAction,
                                    "audioAction" to outcome.audioAction,
                                ),
                            )
                        } else {
                            result.error("transcode_failed", outcome.error, null)
                        }
                    }
                }.start()
            }
            else -> result.notImplemented()
        }
    }

    private fun postProgress(value: Double) {
        mainHandler.post { channel.invokeMethod("progress", value) }
    }

    companion object {
        const val CHANNEL_NAME = "com.example.piliplus/media_transcoder"
    }
}

private data class Outcome(
    val ok: Boolean,
    val error: String = "",
    val videoAction: String = "none",
    val audioAction: String = "none",
)

private const val TIMEOUT_US = 10_000L
private const val AAC_BITRATE = 192_000
private const val MAX_AAC_SAMPLE_RATE = 48_000
private const val MAX_SAMPLE_SIZE = 4 * 1024 * 1024

/** 单条轨道重编码循环的迭代上限，避免编解码器不吐 EOS 时死循环。 */
private const val MAX_PUMP_ITERATIONS = 20_000_000

private fun MediaFormat.intOr(key: String, fallback: Int): Int =
    if (containsKey(key)) getInteger(key) else fallback

private fun MediaFormat.longOr(key: String, fallback: Long): Long =
    if (containsKey(key)) getLong(key) else fallback

/** 一条输出轨道的处理管线。 */
private abstract class Pipeline(protected val muxer: MediaMuxer) {
    abstract val muxerTrack: Int
    abstract val durationUs: Long

    /** muxer.start() 之后把预滚阶段缓存的样本补写出去。 */
    open fun releasePreRoll() = Unit

    abstract fun pump(progressBase: Double, progressSpan: Double)

    open fun release() = Unit
}

private class TranscodeJob(
    private val input: String,
    private val output: String,
    private val onProgress: (Double) -> Unit,
) {
    private val muxer: MediaMuxer
    private val pipelines = ArrayList<Pipeline>()
    private val codecs = ArrayList<MediaCodec>()
    private val extractors = ArrayList<MediaExtractor>()
    private var started = false
    private var videoAction = "none"
    private var audioAction = "none"

    init {
        muxer = MediaMuxer(output, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    }

    fun report(value: Double) {
        onProgress(value.coerceIn(0.0, 1.0))
    }

    fun registerCodec(codec: MediaCodec) {
        codecs.add(codec)
    }

    fun run(): Outcome {
        try {
            prepareVideo()
            prepareAudio()
            if (pipelines.isEmpty()) {
                return Outcome(false, "文件中没有可用的音视频轨")
            }
            muxer.start()
            started = true
            for (p in pipelines) {
                p.releasePreRoll()
            }

            val span = if (pipelines.size > 1) 0.5 else 1.0
            var base = 0.0
            for (p in pipelines) {
                p.pump(base, span)
                base += span
            }
            onProgress(1.0)
            return Outcome(true, "", videoAction, audioAction)
        } finally {
            for (p in pipelines) {
                runCatching { p.release() }
            }
            for (c in codecs) {
                runCatching { c.stop() }
                runCatching { c.release() }
            }
            for (e in extractors) {
                runCatching { e.release() }
            }
            if (started) {
                runCatching { muxer.stop() }
            }
            runCatching { muxer.release() }
        }
    }

    private fun prepareVideo() {
        val extractor = MediaExtractor()
        extractors.add(extractor)
        extractor.setDataSource(input)
        val track = findTrack(extractor, "video/") ?: return
        extractor.selectTrack(track)
        val format = extractor.getTrackFormat(track)
        val mime = format.getString(MediaFormat.KEY_MIME) ?: return

        // 已是 H.264：直接复制样本，不重编码
        if (mime == MediaFormat.MIMETYPE_VIDEO_AVC) {
            videoAction = "copy"
            pipelines.add(CopyPipeline(muxer, extractor, muxer.addTrack(format)))
            return
        }

        try {
            pipelines.add(VideoTranscodePipeline(extractor, format, muxer, this))
            videoAction = "encode"
        } catch (_: Throwable) {
            videoAction = "copy"
            pipelines.add(CopyPipeline(muxer, extractor, muxer.addTrack(format)))
        }
    }

    private fun prepareAudio() {
        val extractor = MediaExtractor()
        extractors.add(extractor)
        extractor.setDataSource(input)
        val track = findTrack(extractor, "audio/") ?: return
        extractor.selectTrack(track)
        val format = extractor.getTrackFormat(track)
        val mime = format.getString(MediaFormat.KEY_MIME) ?: return

        if (mime == MediaFormat.MIMETYPE_AUDIO_AAC) {
            audioAction = "copy"
            pipelines.add(CopyPipeline(muxer, extractor, muxer.addTrack(format)))
            return
        }

        val sampleRate = format.intOr(MediaFormat.KEY_SAMPLE_RATE, 0)
        val channels = format.intOr(MediaFormat.KEY_CHANNEL_COUNT, 0)
        if (sampleRate in 8_000..MAX_AAC_SAMPLE_RATE && channels in 1..2) {
            try {
                pipelines.add(
                    AudioTranscodePipeline(
                        extractor,
                        format,
                        muxer,
                        this,
                        sampleRate,
                        channels,
                    ),
                )
                audioAction = "encode"
                return
            } catch (_: Throwable) {
                // 退化到复制该音频轨
            }
        }
        audioAction = "copy"
        pipelines.add(CopyPipeline(muxer, extractor, muxer.addTrack(format)))
    }

    private fun findTrack(extractor: MediaExtractor, prefix: String): Int? {
        for (i in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME)
            if (mime != null && mime.startsWith(prefix)) {
                return i
            }
        }
        return null
    }
}

/** 直接复制样本的轨道（视频或音频）。 */
private class CopyPipeline(
    muxer: MediaMuxer,
    private val extractor: MediaExtractor,
    override val muxerTrack: Int,
) : Pipeline(muxer) {
    private val buffer = ByteBuffer.allocateDirect(MAX_SAMPLE_SIZE)

    override val durationUs: Long = 0

    override fun pump(progressBase: Double, progressSpan: Double) {
        while (true) {
            buffer.clear()
            val size = extractor.readSampleData(buffer, 0)
            if (size < 0) {
                return
            }
            buffer.position(0)
            buffer.limit(size)
            val data = ByteArray(size)
            buffer.get(data)
            val flags =
                if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) {
                    MediaCodec.BUFFER_FLAG_KEY_FRAME
                } else {
                    0
                }
            writeSample(muxerTrack, data, extractor.sampleTime, flags)
            extractor.advance()
        }
    }

    private fun writeSample(track: Int, data: ByteArray, ptsUs: Long, flags: Int) {
        val info = MediaCodec.BufferInfo()
        info.set(0, data.size, ptsUs, flags)
        muxer.writeSampleData(track, ByteBuffer.wrap(data), info)
    }
}

/** 解码 → 编码为 H.264（解码输出直接送给编码器的输入 Surface）。 */
private class VideoTranscodePipeline(
    private val extractor: MediaExtractor,
    format: MediaFormat,
    muxer: MediaMuxer,
    private val job: TranscodeJob,
) : Pipeline(muxer) {
    private val decoder: MediaCodec
    private val encoder: MediaCodec
    private val surface: Surface
    private val decoderInfo = MediaCodec.BufferInfo()
    private val encoderInfo = MediaCodec.BufferInfo()
    private var inputDone = false
    private var outputDone = false
    private var encodedFormatKnown = false
    private var lastSampleUs = 0L
    private val stashed = ArrayList<ByteArray>()
    private val stashedPts = ArrayList<Long>()
    private val stashedFlags = ArrayList<Int>()

    override val muxerTrack: Int
    override val durationUs: Long

    init {
        val mime = format.getString(MediaFormat.KEY_MIME) ?: error("视频轨缺少 mime")
        val width = format.getInteger(MediaFormat.KEY_WIDTH)
        val height = format.getInteger(MediaFormat.KEY_HEIGHT)
        val fps = format.intOr(MediaFormat.KEY_FRAME_RATE, 30).let { if (it <= 0) 30 else it }
        val bitrate = (width.toLong() * height * fps * 0.15).toInt()
            .coerceIn(2_000_000, 20_000_000)

        val outFormat = MediaFormat.createVideoFormat(
            MediaFormat.MIMETYPE_VIDEO_AVC,
            width,
            height,
        )
        outFormat.setInteger(
            MediaFormat.KEY_COLOR_FORMAT,
            MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
        )
        outFormat.setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
        outFormat.setInteger(MediaFormat.KEY_FRAME_RATE, fps)
        outFormat.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)

        encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        encoder.configure(outFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        surface = encoder.createInputSurface()
        encoder.start()
        job.registerCodec(encoder)

        decoder = MediaCodec.createDecoderByType(mime)
        decoder.configure(format, surface, null, 0)
        decoder.start()
        job.registerCodec(decoder)

        durationUs = format.longOr("duration", 0L)

        preRoll()
        muxerTrack = muxer.addTrack(encoder.outputFormat)
    }

    /** 预滚：喂少量输入，直到编码器给出输出格式（此时才可能加入 muxer）。 */
    private fun preRoll() {
        var guard = 0
        while (guard < 900 && !(encodedFormatKnown && stashed.isNotEmpty())) {
            guard++
            feedDecoder()
            drainDecoder()
            drainEncoder(storeStashed = true)
        }
    }

    private fun feedDecoder() {
        if (inputDone) {
            return
        }
        val index = decoder.dequeueInputBuffer(TIMEOUT_US)
        if (index < 0) {
            return
        }
        val buffer = decoder.getInputBuffer(index) ?: return
        val size = extractor.readSampleData(buffer, 0)
        if (size < 0) {
            decoder.queueInputBuffer(
                index,
                0,
                0,
                0,
                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
            )
            inputDone = true
        } else {
            decoder.queueInputBuffer(index, 0, size, extractor.sampleTime, 0)
            lastSampleUs = extractor.sampleTime
            extractor.advance()
        }
    }

    private fun drainDecoder() {
        while (true) {
            val index = decoder.dequeueOutputBuffer(decoderInfo, 0)
            if (index == MediaCodec.INFO_TRY_AGAIN_LATER) {
                return
            }
            if (index < 0) {
                continue
            }
            val eos = decoderInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
            decoder.releaseOutputBuffer(index, true)
            if (eos) {
                return
            }
        }
    }

    private fun drainEncoder(storeStashed: Boolean): Boolean {
        while (true) {
            val index = encoder.dequeueOutputBuffer(encoderInfo, 0)
            if (index == MediaCodec.INFO_TRY_AGAIN_LATER) {
                return false
            }
            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                encodedFormatKnown = true
                continue
            }
            if (index < 0) {
                continue
            }
            val eos = encoderInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
            if (encoderInfo.size > 0) {
                val buffer = encoder.getOutputBuffer(index)
                if (buffer != null) {
                    buffer.position(encoderInfo.offset)
                    buffer.limit(encoderInfo.offset + encoderInfo.size)
                    val data = ByteArray(encoderInfo.size)
                    buffer.get(data)
                    if (storeStashed) {
                        stashed.add(data)
                        stashedPts.add(encoderInfo.presentationTimeUs)
                        stashedFlags.add(encoderInfo.flags)
                    } else {
                        writeEncoded(data, encoderInfo.presentationTimeUs, encoderInfo.flags)
                    }
                }
            }
            encoder.releaseOutputBuffer(index, false)
            if (eos) {
                outputDone = true
                return true
            }
        }
    }

    private fun writeEncoded(data: ByteArray, ptsUs: Long, flags: Int) {
        val info = MediaCodec.BufferInfo()
        info.set(0, data.size, ptsUs, flags)
        muxer.writeSampleData(muxerTrack, ByteBuffer.wrap(data), info)
    }

    override fun releasePreRoll() {
        for (i in stashed.indices) {
            writeEncoded(stashed[i], stashedPts[i], stashedFlags[i])
        }
        stashed.clear()
        stashedPts.clear()
        stashedFlags.clear()
    }

    override fun pump(progressBase: Double, progressSpan: Double) {
        var guard = 0
        while (!outputDone && guard++ < MAX_PUMP_ITERATIONS) {
            feedDecoder()
            drainDecoder()
            drainEncoder(storeStashed = false)
            if (durationUs > 0) {
                val ratio = (lastSampleUs.toDouble() / durationUs).coerceIn(0.0, 1.0)
                job.report(progressBase + progressSpan * ratio)
            }
        }
        job.report(progressBase + progressSpan)
    }

    override fun release() {
        runCatching { surface.release() }
    }
}

/** 解码 → 编码为 AAC 的音频轨道。 */
private class AudioTranscodePipeline(
    private val extractor: MediaExtractor,
    format: MediaFormat,
    muxer: MediaMuxer,
    private val job: TranscodeJob,
    private val sampleRate: Int,
    private val channels: Int,
) : Pipeline(muxer) {
    private val decoder: MediaCodec
    private val encoder: MediaCodec
    private val decoderInfo = MediaCodec.BufferInfo()
    private val encoderInfo = MediaCodec.BufferInfo()
    private var inputDone = false
    private var outputDone = false
    private var encodedFormatKnown = false
    private var encoderEosSent = false
    private var ptsUs = 0L
    private val pendingPcm = ArrayList<ByteArray>()
    private val stashed = ArrayList<ByteArray>()
    private val stashedPts = ArrayList<Long>()
    private val stashedFlags = ArrayList<Int>()

    override val muxerTrack: Int
    override val durationUs: Long

    init {
        val mime = format.getString(MediaFormat.KEY_MIME) ?: error("音频轨缺少 mime")
        decoder = MediaCodec.createDecoderByType(mime)
        decoder.configure(format, null, null, 0)
        decoder.start()
        job.registerCodec(decoder)

        durationUs = format.longOr("duration", 0L)

        val aacFormat = MediaFormat.createAudioFormat(
            MediaFormat.MIMETYPE_AUDIO_AAC,
            sampleRate,
            channels,
        )
        aacFormat.setInteger(
            MediaFormat.KEY_AAC_PROFILE,
            MediaCodecInfo.CodecProfileLevel.AACObjectLC,
        )
        aacFormat.setInteger(MediaFormat.KEY_BIT_RATE, AAC_BITRATE)
        aacFormat.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16 * 1024)
        encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        encoder.configure(aacFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        encoder.start()
        job.registerCodec(encoder)

        preRoll()
        muxerTrack = muxer.addTrack(encoder.outputFormat)
    }

    private fun preRoll() {
        var guard = 0
        while (guard < 2000 && !(encodedFormatKnown && stashed.isNotEmpty())) {
            guard++
            feedDecoder()
            drainDecoder()
            drainEncoder(storeStashed = true)
        }
    }

    private fun feedDecoder() {
        if (inputDone) {
            return
        }
        val index = decoder.dequeueInputBuffer(TIMEOUT_US)
        if (index < 0) {
            return
        }
        val buffer = decoder.getInputBuffer(index) ?: return
        val size = extractor.readSampleData(buffer, 0)
        if (size < 0) {
            decoder.queueInputBuffer(
                index,
                0,
                0,
                0,
                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
            )
            inputDone = true
        } else {
            decoder.queueInputBuffer(index, 0, size, extractor.sampleTime, 0)
            extractor.advance()
        }
    }

    private fun drainDecoder() {
        while (true) {
            val index = decoder.dequeueOutputBuffer(decoderInfo, 0)
            if (index == MediaCodec.INFO_TRY_AGAIN_LATER) {
                return
            }
            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                // 解码输出必须是 16bit PCM，否则重编码无法对齐（抛错退回复制该轨）
                val pcm = decoder.outputFormat
                if (
                    pcm.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                    pcm.getInteger(MediaFormat.KEY_PCM_ENCODING) !=
                    AudioFormat.ENCODING_PCM_16BIT
                ) {
                    error("解码输出不是 16bit PCM，无法重编码为 AAC")
                }
                continue
            }
            if (index < 0) {
                continue
            }
            val eos = decoderInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
            if (decoderInfo.size > 0) {
                val buffer = decoder.getOutputBuffer(index)
                if (buffer != null) {
                    buffer.position(decoderInfo.offset)
                    buffer.limit(decoderInfo.offset + decoderInfo.size)
                    val data = ByteArray(decoderInfo.size)
                    buffer.get(data)
                    pendingPcm.add(data)
                }
            }
            decoder.releaseOutputBuffer(index, false)
            queuePcm()
            if (eos) {
                return
            }
        }
    }

    /** 把解码出的 PCM 喂给编码器（编码器输入缓冲可能暂时不可用，剩余部分留待下轮）。 */
    private fun queuePcm() {
        while (pendingPcm.isNotEmpty()) {
            val index = encoder.dequeueInputBuffer(TIMEOUT_US)
            if (index < 0) {
                return
            }
            val buffer = encoder.getInputBuffer(index) ?: return
            buffer.clear()
            val data = pendingPcm[0]
            val capacity = if (data.size > buffer.capacity()) buffer.capacity() else data.size
            buffer.put(data, 0, capacity)
            if (capacity < data.size) {
                pendingPcm[0] = data.copyOfRange(capacity, data.size)
            } else {
                pendingPcm.removeAt(0)
            }
            encoder.queueInputBuffer(index, 0, capacity, ptsUs, 0)
            ptsUs += capacity * 1_000_000L / (sampleRate.toLong() * channels * 2)
        }
    }

    private fun feedEncoderEos() {
        if (encoderEosSent || pendingPcm.isNotEmpty()) {
            return
        }
        val index = encoder.dequeueInputBuffer(TIMEOUT_US)
        if (index < 0) {
            return
        }
        encoder.queueInputBuffer(
            index,
            0,
            0,
            ptsUs,
            MediaCodec.BUFFER_FLAG_END_OF_STREAM,
        )
        encoderEosSent = true
    }

    private fun drainEncoder(storeStashed: Boolean): Boolean {
        while (true) {
            val index = encoder.dequeueOutputBuffer(encoderInfo, 0)
            if (index == MediaCodec.INFO_TRY_AGAIN_LATER) {
                return false
            }
            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                encodedFormatKnown = true
                continue
            }
            if (index < 0) {
                continue
            }
            val eos = encoderInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
            if (encoderInfo.size > 0) {
                val buffer = encoder.getOutputBuffer(index)
                if (buffer != null) {
                    buffer.position(encoderInfo.offset)
                    buffer.limit(encoderInfo.offset + encoderInfo.size)
                    val data = ByteArray(encoderInfo.size)
                    buffer.get(data)
                    if (storeStashed) {
                        stashed.add(data)
                        stashedPts.add(encoderInfo.presentationTimeUs)
                        stashedFlags.add(encoderInfo.flags)
                    } else {
                        writeEncoded(data, encoderInfo.presentationTimeUs, encoderInfo.flags)
                    }
                }
            }
            encoder.releaseOutputBuffer(index, false)
            if (eos) {
                outputDone = true
                return true
            }
        }
    }

    private fun writeEncoded(data: ByteArray, ptsUs: Long, flags: Int) {
        val info = MediaCodec.BufferInfo()
        info.set(0, data.size, ptsUs, flags)
        muxer.writeSampleData(muxerTrack, ByteBuffer.wrap(data), info)
    }

    override fun releasePreRoll() {
        for (i in stashed.indices) {
            writeEncoded(stashed[i], stashedPts[i], stashedFlags[i])
        }
        stashed.clear()
        stashedPts.clear()
        stashedFlags.clear()
    }

    override fun pump(progressBase: Double, progressSpan: Double) {
        var guard = 0
        while (!outputDone && guard++ < MAX_PUMP_ITERATIONS) {
            feedDecoder()
            drainDecoder()
            if (inputDone) {
                feedEncoderEos()
            }
            drainEncoder(storeStashed = false)
            if (durationUs > 0) {
                val ratio = (ptsUs.toDouble() / durationUs).coerceIn(0.0, 1.0)
                job.report(progressBase + progressSpan * ratio)
            }
        }
        job.report(progressBase + progressSpan)
    }
}
