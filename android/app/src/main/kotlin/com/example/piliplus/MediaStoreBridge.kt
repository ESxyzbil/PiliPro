package com.example.piliplus

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 把应用私有目录中的文件复制到「系统共享的下载目录」。
 *
 * 背景：Android 11 起 /storage/emulated/0/Android/data/<pkg>/ 既不能被 PC 侧 adb 读取，
 * 普通文件管理器也读不到，导出的数据包会「拿不出来」。这里通过 MediaStore 把文件写入
 * 公共下载目录（Download/PiliPlus/），使其可被文件管理器、快传、MTP 与 adb 正常访问。
 *
 * 复制全程 1MB 缓冲流式进行，不把文件读进内存——保存大视频（几十~几百 MB）时不会 OOM。
 *
 * API 29+ 走 MediaStore（分区存储，无需存储权限）；API 28 及以下退化为直接写公共目录。
 */
class MediaStoreBridge(private val context: Context) {

    private companion object {
        const val TAG = "MediaStoreBridge"
    }

    fun copyToDownloads(
        sourcePath: String,
        displayName: String?,
        subDir: String,
        mimeType: String,
        onProgress: ((Long, Long) -> Unit)?,
        result: MethodChannel.Result,
    ) {
        Thread {
            try {
                val src = File(sourcePath)
                if (!src.exists()) {
                    postResult(result, mapOf("ok" to false, "error" to "源文件不存在: $sourcePath"))
                    return@Thread
                }
                val name = if (displayName.isNullOrEmpty()) src.name else displayName
                val total = src.length()
                android.util.Log.i(TAG, "copyToDownloads start: src=$sourcePath size=$total name=$name mime=$mimeType")
                var uri: Uri? = null
                var method = "mediastore"
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    try {
                        uri = createViaMediaStore(src, name, subDir, mimeType, onProgress)
                    } catch (t: Throwable) {
                        // MediaStore 不可用（部分厂商 ROM / 权限策略）时直接写共享目录
                        android.util.Log.w(TAG, "MediaStore 写入失败，回退直写共享目录", t)
                        method = "direct"
                        uri = createViaFile(src, name, subDir, onProgress)
                    }
                } else {
                    method = "direct"
                    uri = createViaFile(src, name, subDir, onProgress)
                }
                android.util.Log.i(TAG, "copyToDownloads done: method=$method uri=$uri")
                postResult(
                    result,
                    mapOf(
                        "ok" to true,
                        "uri" to uri.toString(),
                        "name" to name,
                        "size" to total,
                        "method" to method,
                    )
                )
            } catch (t: Throwable) {
                android.util.Log.e(TAG, "copyToDownloads failed", t)
                postResult(result, mapOf("ok" to false, "error" to (t.message ?: t.toString())))
            }
        }.start()
    }

    private fun createViaMediaStore(
        src: File,
        name: String,
        subDir: String,
        mimeType: String,
        onProgress: ((Long, Long) -> Unit)?,
    ): Uri {
        val relative = if (subDir.isEmpty()) {
            Environment.DIRECTORY_DOWNLOADS
        } else {
            Environment.DIRECTORY_DOWNLOADS + File.separator + subDir
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relative)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val resolver = context.contentResolver
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("MediaStore 插入失败（可能是共享目录不可写）")
        try {
            resolver.openOutputStream(uri)?.use { out ->
                copyWithProgress(src, out, onProgress)
            } ?: throw IllegalStateException("无法打开 MediaStore 输出流")
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return uri
        } catch (t: Throwable) {
            try {
                resolver.delete(uri, null, null)
            } catch (_: Throwable) {
            }
            throw t
        }
    }

    private fun createViaFile(
        src: File,
        name: String,
        subDir: String,
        onProgress: ((Long, Long) -> Unit)?,
    ): Uri {
        val base = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        val dir = if (subDir.isEmpty()) base else File(base, subDir)
        if (!dir.exists() && !dir.mkdirs()) {
            throw IllegalStateException("无法创建目录: " + dir.absolutePath)
        }
        // 同名文件不覆盖：追加 (1)/(2)…
        val dst = resolveTarget(dir, name)
        android.util.Log.i(TAG, "direct write -> " + dst.absolutePath)
        dst.outputStream().use { out ->
            copyWithProgress(src, out, onProgress)
        }
        return Uri.fromFile(dst)
    }

    /** 复制 [src] 到 [out]，边写边回调 (已复制, 总大小)。 */
    private fun copyWithProgress(
        src: File,
        out: java.io.OutputStream,
        onProgress: ((Long, Long) -> Unit)?,
    ) {
        val total = src.length()
        var lastReported = -1L
        src.inputStream().use { input ->
            val buf = ByteArray(1 shl 20)
            var copied = 0L
            while (true) {
                val read = input.read(buf)
                if (read <= 0) break
                out.write(buf, 0, read)
                copied += read
                // 每 256KB 或每 1% 汇报一次，避免通道刷屏
                if (onProgress != null && (copied - lastReported >= (256L shl 10) || copied >= total)) {
                    lastReported = copied
                    onProgress(copied, total)
                }
            }
            out.flush()
        }
    }

    private fun resolveTarget(dir: File, name: String): File {
        var dst = File(dir, name)
        if (!dst.exists()) return dst
        val dot = name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var i = 1
        while (dst.exists() && i < 1000) {
            dst = File(dir, "$stem ($i)$ext")
            i++
        }
        return dst
    }

    private fun postResult(result: MethodChannel.Result, payload: Map<String, Any?>) {
        android.os.Handler(context.mainLooper).post { result.success(payload) }
    }
}
