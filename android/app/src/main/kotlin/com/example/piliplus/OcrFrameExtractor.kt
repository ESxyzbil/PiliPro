package com.example.piliplus

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import java.io.File
import java.io.FileOutputStream

/**
 * OCR 整段识别取帧器：MediaCodec 解码视频轨 → 每隔 sampleEveryMs 取一帧存 JPEG
 * 事件：完成 → String "ocrdone:<outDir>:<frameCount>"; 失败 → "ocrfailed:<msg>"
 */
class OcrFrameExtractor(
    private val sink: EventChannel.EventSink?,
    private val context: Context,
) {
    companion object {
        private const val TAG = "OcrFrameExtractor"
        private val MAIN = Handler(Looper.getMainLooper())
        private const val UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
    }

    private var thread: Thread? = null
    @Volatile private var running = false

    fun start(url: String, outDir: String, sampleEveryMs: Long = 1000L) {
        Log.i(TAG, "start urlLen=${url.length} outDir=$outDir every=${sampleEveryMs}ms")
        stop()
        running = true
        thread = Thread({
            try {
                val count = extractFrames(url, File(outDir), sampleEveryMs)
                Log.i(TAG, "done: $count frames")
                MAIN.post { sink?.success("ocrdone:$outDir:$count") }
            } catch (e: Exception) {
                Log.e(TAG, "failed: ${e.message}")
                MAIN.post { sink?.success("ocrfailed:${e.message}") }
            } finally {
                synchronized(this) { running = false }
            }
        }, "ocr-frame-extract").apply {
            isDaemon = true
            start()
        }
    }

    fun stop() {
        synchronized(this) { running = false }
        thread?.interrupt()
        thread = null
    }

    private fun extractFrames(url: String, outDir: File, sampleEveryMs: Long): Int {
        if (!outDir.exists()) outDir.mkdirs()
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(
                url,
                mapOf("User-Agent" to UA, "Referer" to "https://www.bilibili.com"),
            )
            val trackIndex = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it)
                    .getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true
            } ?: throw Exception("no video track")
            extractor.selectTrack(trackIndex)
            val format = extractor.getTrackFormat(trackIndex)
            codec = MediaCodec.createDecoderByType(
                format.getString(MediaFormat.KEY_MIME)!!,
            )
            codec.configure(format, null, null, 0)
            codec.start()
            val info = MediaCodec.BufferInfo()
            var eos = false
            var frameCount = 0
            var lastSavedMs = -sampleEveryMs
            while (running && !eos) {
                val inIdx = codec.dequeueInputBuffer(10_000)
                if (inIdx >= 0) {
                    val inBuf = codec.getInputBuffer(inIdx)!!
                    val size = extractor.readSampleData(inBuf, 0)
                    if (size < 0) {
                        codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        eos = true
                    } else {
                        codec.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
                val outIdx = codec.dequeueOutputBuffer(info, 10_000)
                if (outIdx >= 0) {
                    val ptsMs = info.presentationTimeUs / 1000
                    val image = codec.getOutputImage(outIdx) ?: run {
                        codec.releaseOutputBuffer(outIdx, false)
                        continue
                    }
                    // 按时间间隔取帧
                    if (ptsMs - lastSavedMs >= sampleEveryMs) {
                        lastSavedMs = ptsMs
                        val bmp = imageToBitmap(image)
                        val f = File(outDir, "f${frameCount.toString().padStart(5, '0')}.jpg")
                        FileOutputStream(f).use { out ->
                            bmp.compress(Bitmap.CompressFormat.JPEG, 80, out)
                        }
                        bmp.recycle()
                        frameCount++
                        if (frameCount % 20 == 0) {
                            Log.i(TAG, "saved $frameCount frames (pts=${ptsMs}ms)")
                        }
                    }
                    codec.releaseOutputBuffer(outIdx, false)
                } else if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    // format changed
                }
            }
            codec.stop()
            return frameCount
        } finally {
            try {
                codec?.release()
            } catch (_: Exception) {
            }
            extractor.release()
        }
    }

    /** MediaCodec 输出 Image (YUV) → RGB Bitmap（缩小到最大 720 宽） */
    private fun imageToBitmap(image: android.media.Image): Bitmap {
        val planes = image.planes
        val width = image.width
        val height = image.height
        val scale = if (width > 720) 720f / width else 1f
        val tw = (width * scale).toInt()
        val th = (height * scale).toInt()
        val nv21 = yuvToNv21(image, width, height)
        val yuvImage = android.graphics.YuvImage(
            nv21,
            android.graphics.ImageFormat.NV21,
            width, height, null,
        )
        val tmp = java.io.ByteArrayOutputStream()
        yuvImage.compressToJpeg(
            android.graphics.Rect(0, 0, width, height), 85, tmp,
        )
        val bmp = android.graphics.BitmapFactory.decodeByteArray(tmp.toByteArray(), 0, tmp.size())
        tmp.close()
        if (scale < 1f) {
            return Bitmap.createScaledBitmap(bmp, tw, th, true).also { bmp.recycle() }
        }
        return bmp
    }

    private fun yuvToNv21(image: android.media.Image, width: Int, height: Int): ByteArray {
        val yPlane = image.planes[0]
        val uPlane = image.planes[1]
        val vPlane = image.planes[2]
        val ySize = yPlane.rowStride * height
        val uvSize = (width * height) / 2
        val nv21 = ByteArray(ySize + uvSize)
        var pos = 0
        val yBuffer = yPlane.buffer
        val yRowStride = yPlane.rowStride
        val yPixelStride = yPlane.pixelStride
        for (row in 0 until height) {
            yBuffer.position(row * yRowStride)
            for (col in 0 until width) {
                nv21[pos++] = yBuffer.get()
                if (yPixelStride > 1) yBuffer.position(row * yRowStride + col * yPixelStride)
            }
        }
        // UV 交织 (VU)
        val uBuffer = uPlane.buffer
        val vBuffer = vPlane.buffer
        val uRowStride = uPlane.rowStride
        val uvPixelStride = uPlane.pixelStride
        val uvHeight = height / 2
        val uvWidth = width / 2
        for (row in 0 until uvHeight) {
            uBuffer.position(row * uRowStride)
            vBuffer.position(row * uRowStride)
            for (col in 0 until uvWidth) {
                nv21[pos++] = vBuffer.get()
                nv21[pos++] = uBuffer.get()
                if (uvPixelStride > 1) {
                    uBuffer.position(row * uRowStride + col * uvPixelStride)
                    vBuffer.position(row * uRowStride + col * uvPixelStride)
                }
            }
        }
        return nv21
    }
}
