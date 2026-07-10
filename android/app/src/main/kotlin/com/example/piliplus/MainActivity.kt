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
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    private lateinit var liveUpdateManager: LiveUpdateManager
    private val liveUpdateChannel = "com.example.piliplus/live_update"
    private val shortcutChannel = "com.example.piliplus/shortcuts"

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
