package com.nym.bar

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// local_auth's Android BiometricPrompt requires the host Activity to be a
// FragmentActivity. With the default FlutterActivity, `authenticate()` throws
// PlatformException("no_fragment_activity", …), which surfaced in-app as
// "Biometric authentication failed." Extending FlutterFragmentActivity is the
// plugin's documented requirement and makes fingerprint/face unlock work.
class MainActivity : FlutterFragmentActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // "Stay Connected in Background": Dart asks for the foreground service
        // when the app goes off-screen and releases it on resume. See
        // NymBackgroundService and lib/services/platform/background_connectivity.dart.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BACKGROUND_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val mesh = call.argument<Boolean>("mesh") ?: false
                    result.success(startBackgroundService(mesh))
                }
                "stop" -> {
                    stopBackgroundService()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Returns whether the service was actually started. A start can be refused
     * by the OS (background-start restrictions on Android 12+ when the app is
     * already too far into the background), and Dart treats that as "not
     * running" rather than pretending the connection is being held.
     */
    private fun startBackgroundService(mesh: Boolean): Boolean {
        val intent = Intent(this, NymBackgroundService::class.java).apply {
            putExtra(NymBackgroundService.EXTRA_MESH, mesh)
        }
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            true
        } catch (t: Throwable) {
            false
        }
    }

    private fun stopBackgroundService() {
        try {
            stopService(Intent(this, NymBackgroundService::class.java))
        } catch (t: Throwable) {
            // Never started / already gone.
        }
    }

    companion object {
        private const val BACKGROUND_CHANNEL = "app.nymchat/background_connectivity"
    }
}
