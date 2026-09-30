package com.nym.bar

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/** Foreground service that keeps the process (relay sockets, BLE mesh) alive while backgrounded; does no work itself. */
class NymBackgroundService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // startForeground() must happen within seconds of the start request or the system kills the app.
        val usesMesh = intent?.getBooleanExtra(EXTRA_MESH, false) ?: false
        startForegroundCompat(usesMesh)
        acquireWakeLock()

        // Not sticky: a system restart would bring back the notification without the Flutter engine.
        return START_NOT_STICKY
    }

    /** The user swiped the app away; tear the service down with it. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSelfSafely()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }

    private fun stopSelfSafely() {
        releaseWakeLock()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun startForegroundCompat(usesMesh: Boolean) {
        createChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 14+ requires a manifest-granted type: `connectedDevice` for BLE, `dataSync` for relay sockets.
            var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            if (usesMesh && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            }
            startForeground(NOTIFICATION_ID, notification, type)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Background connection",
            // MIN keeps the required notification as quiet as possible.
            NotificationManager.IMPORTANCE_MIN,
        ).apply {
            description = "Shown while Nymchat keeps its relay and mesh " +
                "connections open in the background."
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val contentIntent = launch?.let {
            PendingIntent.getActivity(this, 0, it, pendingFlags)
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("Nymchat is staying connected")
            .setContentText("Relays and the Bluetooth mesh keep running in the background.")
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .setShowWhen(false)
            .setVisibility(Notification.VISIBILITY_SECRET)
            .apply { if (contentIntent != null) setContentIntent(contentIntent) }
            .build()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        try {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "nymchat:background-connectivity",
            ).apply {
                setReferenceCounted(false)
                // Bounded so a leaked service can't drain the battery; re-acquired on the next background transition.
                acquire(WAKE_LOCK_TIMEOUT_MS)
            }
        } catch (t: Throwable) {
            // A denied wake lock isn't fatal; the foreground service still keeps the sockets alive.
            wakeLock = null
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.takeIf { it.isHeld }?.release()
        } catch (t: Throwable) {
            // Already released.
        }
        wakeLock = null
    }

    companion object {
        const val EXTRA_MESH = "mesh"
        private const val CHANNEL_ID = "nym_background_connectivity"
        private const val NOTIFICATION_ID = 4711
        private const val WAKE_LOCK_TIMEOUT_MS = 6L * 60L * 60L * 1000L
    }
}
