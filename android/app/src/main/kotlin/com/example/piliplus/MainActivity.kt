package com.example.piliplus

import android.app.PendingIntent
import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.view.WindowManager.LayoutParams
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    private val shortcutChannel = "com.example.piliplus/shortcuts"
    private val asrAudioChannel = "com.example.piliplus/asr_audio"
    private val asrAudioEventsChannel = "com.example.piliplus/asr_audio_events"
    private var asrAudioBridge: AsrAudioBridge? = null
    private val ocrFramesChannel = "com.example.piliplus/ocr_frames"
    private val ocrFramesEventsChannel = "com.example.piliplus/ocr_frames_events"
    private var ocrFrameExtractor: OcrFrameExtractor? = null
    private val downloadProgressChannel = "com.example.piliplus/download_progress"
    private var downloadProgressManager: DownloadProgressManager? = null
    private var mediaTranscoder: MediaTranscoder? = null
    private val mediaStoreChannel = "com.example.piliplus/media_store"
    private var mediaStoreBridge: MediaStoreBridge? = null
    private val appControlChannel = "com.example.piliplus/app_control"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 应用控制（导入数据后需要重启才能重新打开 Hive）
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            appControlChannel
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "restartApp" -> {
                    result.success(true)
                    try {
                        val intent = Intent(this, MainActivity::class.java).apply {
                            addFlags(
                                Intent.FLAG_ACTIVITY_NEW_TASK or
                                    Intent.FLAG_ACTIVITY_CLEAR_TASK
                            )
                        }
                        startActivity(intent)
                    } catch (t: Throwable) {
                        android.util.Log.e("AppControl", "restart failed", t)
                    }
                    android.os.Handler(mainLooper).postDelayed({
                        android.os.Process.killProcess(android.os.Process.myPid())
                    }, 300)
                }
                else -> result.notImplemented()
            }
        }

        // 迁移包等大文件导出到系统共享的下载目录（MediaStore）
        mediaStoreBridge = MediaStoreBridge(this)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            mediaStoreChannel
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "copyToDownloads" -> {
                    val args = call.arguments as Map<*, *>
                    mediaStoreBridge?.copyToDownloads(
                        sourcePath = args["sourcePath"] as? String ?: "",
                        displayName = args["displayName"] as? String,
                        subDir = args["subDir"] as? String ?: "",
                        onProgress = null,
                        result = result,
                    )
                }
                else -> result.notImplemented()
            }
        }

        // 缓存下载进度通知
        downloadProgressManager = DownloadProgressManager(this)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            downloadProgressChannel
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    val args = call.arguments as Map<*, *>
                    downloadProgressManager?.update(
                        queueLength = (args["queueLength"] as? Number)?.toInt() ?: 0,
                        title = args["title"] as? String ?: "",
                        subText = args["subText"] as? String ?: "",
                        progressBytes = (args["progressBytes"] as? Number)?.toLong() ?: 0L,
                        totalBytes = (args["totalBytes"] as? Number)?.toLong() ?: 0L,
                        hasProgress = args["hasProgress"] as? Boolean ?: false,
                    )
                    result.success(true)
                }
                "stop" -> {
                    downloadProgressManager?.stop()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // ASR 日志桥：Dart print 在 release 不输出到 logcat，经此通道转发
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.example.piliplus/asr_log"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "log" -> {
                    android.util.Log.i("AsrLog", call.arguments as? String ?: "")
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // ASR 音频 PCM 桥（MediaCodec 解码音轨 → 16k mono float）
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            asrAudioEventsChannel
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                asrAudioBridge = AsrAudioBridge(events, this@MainActivity)
            }

            override fun onCancel(arguments: Any?) {
                asrAudioBridge?.stop()
                asrAudioBridge = null
            }
        })
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            asrAudioChannel
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val args = call.arguments as Map<*, *>
                    asrAudioBridge?.start(
                        url = args["url"] as? String ?: "",
                        startMs = (args["startMs"] as? Number)?.toLong() ?: 0L,
                        note = args["note"] as? String ?: "",
                    )
                    result.success(true)
                }
                "stop" -> {
                    asrAudioBridge?.stop()
                    result.success(true)
                }
                "decodeAll" -> {
                    val args = call.arguments as Map<*, *>
                    asrAudioBridge?.decodeAll(
                        url = args["url"] as? String ?: "",
                        outPath = args["outPath"] as? String ?: "",
                    )
                    result.success(true)
                }
                // Dart 日志经此通道转发（release 下 Dart 日志不可见）
                "log" -> {
                    android.util.Log.i("AsrAudioBridge", "[DART] ${call.arguments as? String ?: ""}")
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // 快捷方式管理
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            shortcutChannel
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "addCollectionShortcut" -> {
                    val args = call.arguments as Map<*, *>
                    val id = (args["id"] as? Number)?.toLong() ?: 0L
                    val name = args["name"] as? String ?: ""
                    result.success(addCollectionShortcut(id, name))
                }
                "pinCollectionShortcut" -> {
                    val args = call.arguments as Map<*, *>
                    val id = (args["id"] as? Number)?.toLong() ?: 0L
                    val name = args["name"] as? String ?: ""
                    result.success(pinCollectionShortcut(id, name))
                }
                "removeShortcut" -> {
                    val shortcutId = call.arguments as? String ?: ""
                    removeShortcut(shortcutId)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // OCR 整段取帧（视频解码逐帧 JPEG）
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ocrFramesEventsChannel
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                ocrFrameExtractor = OcrFrameExtractor(events, this@MainActivity)
            }

            override fun onCancel(arguments: Any?) {
                ocrFrameExtractor?.stop()
                ocrFrameExtractor = null
            }
        })
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ocrFramesChannel
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val args = call.arguments as Map<*, *>
                    ocrFrameExtractor?.start(
                        url = args["url"] as? String ?: "",
                        outDir = args["outDir"] as? String ?: "",
                        sampleEveryMs = (args["sampleEveryMs"] as? Number)?.toLong() ?: 1000L,
                    )
                    result.success(true)
                }
                "stop" -> {
                    ocrFrameExtractor?.stop()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // 保存到本地：合并后的 MP4 转码为 H.264 + AAC
        val mediaTranscoderChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MediaTranscoder.CHANNEL_NAME
        )
        val transcoder = MediaTranscoder(mediaTranscoderChannel)
        mediaTranscoder = transcoder
        mediaTranscoderChannel.setMethodCallHandler { call, result ->
            transcoder.onMethodCall(call, result)
        }
    }

    private fun favShortcut(id: Long, name: String) =
        ShortcutInfoCompat.Builder(this, "collection_$id")
            .setShortLabel(name)
            .setLongLabel(name)
            .setIcon(IconCompat.createWithResource(this, R.drawable.ic_shortcut_fav))
            .setIntent(
                Intent(this, MainActivity::class.java).apply {
                    action = Intent.ACTION_VIEW
                    data = android.net.Uri.parse("bilibili://fav/detail/$id")
                }
            )
            .build()

    // 加入桌面长按菜单。pushDynamicShortcut 不抛异常不代表桌面会显示，
    // 这里回读动态快捷方式列表，把真实结果给 Dart 侧提示。
    private fun addCollectionShortcut(id: Long, name: String): Boolean {
        val shortcutId = "collection_$id"
        ShortcutManagerCompat.pushDynamicShortcut(this, favShortcut(id, name))
        val listed = ShortcutManagerCompat.getDynamicShortcuts(this)
            .orEmpty()
            .any { it.id == shortcutId }
        android.util.Log.i(
            "ShortcutBridge",
            "push $shortcutId listed=$listed total=" +
                    ShortcutManagerCompat.getDynamicShortcuts(this).size
        )
        return listed
    }

    // 请求固定到主屏幕：系统确认弹窗后生成真实桌面图标。
    // 部分厂商桌面不展示长按菜单里的动态快捷方式，用这条兜底。
    private fun pinCollectionShortcut(id: Long, name: String): Boolean = try {
        val callback = PendingIntent.getActivity(
            this,
            (1_000_000 + id).toInt(),
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        ShortcutManagerCompat.requestPinShortcut(
            this,
            favShortcut(id, name),
            callback.intentSender,
        )
    } catch (e: Exception) {
        android.util.Log.w("ShortcutBridge", "requestPinShortcut failed", e)
        false
    }

    private fun removeShortcut(shortcutId: String) {
        ShortcutManagerCompat.removeDynamicShortcuts(this, listOf(shortcutId))
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (AndroidHelper.isFoldable) {
            AndroidHelper.ToDart.onConfigurationChanged?.run()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        AndroidHelper.ToDart.onUserLeaveHint?.run()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration?) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        AndroidHelper.isPipMode = isInPictureInPictureMode
    }
}
