package com.example.piliplus

import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    private val shortcutChannel = "com.example.piliplus/shortcuts"
    private lateinit var liveUpdateManager: LiveUpdateManager
    private val liveUpdateChannel = "com.example.piliplus/live_update"
    private val asrAudioChannel = "com.example.piliplus/asr_audio"
    private val asrAudioEventsChannel = "com.example.piliplus/asr_audio_events"
    private var asrAudioBridge: AsrAudioBridge? = null
    private val ocrFramesChannel = "com.example.piliplus/ocr_frames"
    private val ocrFramesEventsChannel = "com.example.piliplus/ocr_frames_events"
    private var ocrFrameExtractor: OcrFrameExtractor? = null
    private val downloadProgressChannel = "com.example.piliplus/download_progress"
    private var downloadProgressManager: DownloadProgressManager? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        liveUpdateManager = LiveUpdateManager(this)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            liveUpdateChannel
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "updateMusic" -> {
                    val args = call.arguments as Map<*, *>
                    liveUpdateManager.updateMusic(
                        songTitle = args["songTitle"] as? String ?: "",
                        currentLyric = args["currentLyric"] as? String ?: "",
                        nextLyric = args["nextLyric"] as? String ?: "",
                        progress = args["progress"] as? Int ?: 0,
                        maxProgress = args["maxProgress"] as? Int ?: 100,
                        isPlaying = args["isPlaying"] as? Boolean ?: false
                    )
                    result.success(true)
                }
                "endMusic" -> {
                    liveUpdateManager.endMusic()
                    result.success(true)
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
                    addCollectionShortcut(id, name)
                    result.success(true)
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
    }

    private fun addCollectionShortcut(id: Long, name: String) {
        val shortcutId = "collection_$id"
        val intent = Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            data = android.net.Uri.parse("bilibili://fav/detail/$id")
        }
        val shortcut = ShortcutInfoCompat.Builder(this, shortcutId)
            .setShortLabel(name)
            .setLongLabel(name)
            .setIcon(IconCompat.createWithResource(this, R.drawable.ic_shortcut_fav))
            .setIntent(intent)
            .build()
        ShortcutManagerCompat.pushDynamicShortcut(this, shortcut)
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
                android.view.WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    override fun onDestroy() {
        stopService(Intent(this, com.ryanheise.audioservice.AudioService::class.java))
        super.onDestroy()
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
