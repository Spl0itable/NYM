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

/**
 * Foreground service behind the "Stay Connected in Background" setting.
 *
 * Android freezes an app that has no visible component, which drops every Nostr
 * relay socket and every Bluetooth mesh link the moment the user leaves the
 * app. A foreground service is the only supported way to keep them: it holds
 * the process at a priority the system will not silently freeze, and exempts it
 * from the Doze network restrictions that would otherwise cut the sockets a few
 * minutes in.
 *
 * The service does no work of its own — the Flutter engine still owns the
 * relays and the mesh. It exists to keep that engine alive and unthrottled, and
 * it stops the moment the app comes back to the foreground or the setting is
 * turned off, so the notification is only ever up while it is doing something.
 */
class NymBackgroundService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // startForeground() must happen within seconds of the start request or
        // the system kills the app, so it is the first thing this does — every
        // start path leads here. Stopping goes through stopService() from the
        // activity, never through a start intent.
        val usesMesh = intent?.getBooleanExtra(EXTRA_MESH, false) ?: false
        startForegroundCompat(usesMesh)
        acquireWakeLock()

        // Deliberately NOT sticky: a restart by the system would bring the
        // service (and its notification) back WITHOUT the Flutter engine that
        // gives it a purpose, leaving a notification for work nobody is doing.
        return START_NOT_STICKY
    }

    /** The user swiped the app away — tear the service down with it. */
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
            // Android 14+ enforces that the type declared here is one the
            // manifest granted. `connectedDevice` covers the BLE mesh radio;
            // `dataSync` covers the relay sockets, and is what a mesh-off user
            // is left with.
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
            // MIN keeps the required notification as quiet as the OS allows:
            // no sound, no heads-up, collapsed at the bottom of the shade.
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
                // Bounded so a service that somehow outlives its stop request
                // cannot drain the battery indefinitely; the app re-acquires it
                // on the next background transition.
                acquire(WAKE_LOCK_TIMEOUT_MS)
            }
        } catch (t: Throwable) {
            // A denied/unavailable wake lock is not fatal: the foreground
            // service alone still keeps the process and its sockets alive.
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
