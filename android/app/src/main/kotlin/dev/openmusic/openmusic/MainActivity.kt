package dev.openmusic.openmusic

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// audio_service's activity shares its Flutter engine with the playback service,
// so music keeps playing (with its notification) after the app is closed.
class MainActivity : AudioServiceActivity() {
    private var pending: MethodChannel.Result? = null

    private val musicPermission =
        if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_AUDIO else Manifest.permission.READ_EXTERNAL_STORAGE

    // "Add folder" reads the songs where they are, which takes the permission to read music
    // (picked files are copies the system may clear).
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "openmusic/music_permission").setMethodCallHandler { call, result ->
            if (call.method != "request") return@setMethodCallHandler result.notImplemented()
            if (checkSelfPermission(musicPermission) == PackageManager.PERMISSION_GRANTED) return@setMethodCallHandler result.success(true)
            pending?.success(false)
            pending = result
            requestPermissions(arrayOf(musicPermission), REQUEST)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST) return
        pending?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
        pending = null
    }

    private companion object {
        const val REQUEST = 7301
    }
}
