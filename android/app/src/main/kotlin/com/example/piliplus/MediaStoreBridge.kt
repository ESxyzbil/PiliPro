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
        onProgress: ((Long) -> Unit)?,
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
                android.util.Log.i(TAG, "copyToDownloads start: src=$sourcePath size=$total name=$name")
                var uri: Uri? = null
                var method = "mediastore"
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    try {
                        uri = createViaMediaStore(src, name, subDir, onProgress)
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
        onProgress: ((Long) -> Unit)?,
    ): Uri {
        val relative = if (subDir.isEmpty()) {
            Environment.DIRECTORY_DOWNLOADS
        } else {
            Environment.DIRECTORY_DOWNLOADS + File.separator + subDir
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "application/zip")
            put(MediaStore.MediaColumns.RELATIVE_PATH, relative)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val resolver = context.contentResolver
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("MediaStore 插入失败（可能是共享目录不可写）")
        try {
            resolver.openOutputStream(uri)?.use { out ->
                src.inputStream().use { input ->
                    val buf = ByteArray(1 shl 20)
                    var copied = 0L
                    while (true) {
                        val read = input.read(buf)
                        if (read <= 0) break
                        out.write(buf, 0, read)
                        copied += read
                        onProgress?.invoke(copied)
                    }
                    out.flush()
                }
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
        onProgress: ((Long) -> Unit)?,
    ): Uri {
        val base = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        val dir = if (subDir.isEmpty()) base else File(base, subDir)
        if (!dir.exists() && !dir.mkdirs()) {
            throw IllegalStateException("无法创建目录: " + dir.absolutePath)
        }
        val dst = File(dir, name)
        android.util.Log.i(TAG, "direct write -> " + dst.absolutePath)
        src.inputStream().use { input ->
            dst.outputStream().use { out ->
                val buf = ByteArray(1 shl 20)
                var copied = 0L
                while (true) {
                    val read = input.read(buf)
                    if (read <= 0) break
                    out.write(buf, 0, read)
                    copied += read
                    onProgress?.invoke(copied)
                }
                out.flush()
            }
        }
        return Uri.fromFile(dst)
    }

    private fun postResult(result: MethodChannel.Result, payload: Map<String, Any?>) {
        android.os.Handler(context.mainLooper).post { result.success(payload) }
    }
}
