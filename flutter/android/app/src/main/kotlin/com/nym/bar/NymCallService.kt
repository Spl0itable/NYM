package com.nym.bar

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.content.ContextCompat

class NymCallService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_HANGUP) {
            onHangup?.invoke()
            return START_NOT_STICKY
        }
        val video = intent?.getBooleanExtra(EXTRA_VIDEO, false) ?: false
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Call in progress"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
        val hangup = intent?.getStringExtra(EXTRA_HANGUP) ?: "Hang up"
        if (!startForegroundSafely(video, title, text, hangup)) {
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    private fun granted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED

    private fun startForegroundSafely(video: Boolean, title: String, text: String, hangup: String): Boolean {
        val notification = buildNotification(title, text, hangup)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return try {
                startForeground(NOTIFICATION_ID, notification)
                true
            } catch (t: Throwable) {
                false
            }
        }
        var type = 0
        if (granted(Manifest.permission.RECORD_AUDIO)) {
            type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        }
        if (video && granted(Manifest.permission.CAMERA)) {
            type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        }
        if (type == 0) {
            type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        }
        return try {
            startForeground(NOTIFICATION_ID, notification, type)
            true
        } catch (t: Throwable) {
            if (type and ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA != 0) {
                try {
                    startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
                    true
                } catch (t2: Throwable) {
                    false
                }
            } else {
                false
            }
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Ongoing calls",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            setShowBadge(false)
            setSound(null, null)
            enableVibration(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(title: String, text: String, hangup: String): Notification {
        createChannel()
        val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val contentIntent = launch?.let { PendingIntent.getActivity(this, 0, it, pendingFlags) }
        val hangupIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, NymCallService::class.java).setAction(ACTION_HANGUP),
            pendingFlags,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setContentTitle(title)
            .setSmallIcon(android.R.drawable.stat_sys_phone_call)
            .setOngoing(true)
            .setUsesChronometer(true)
            .setWhen(System.currentTimeMillis())
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .addAction(Notification.Action.Builder(null, hangup, hangupIntent).build())
        if (text.isNotEmpty()) builder.setContentText(text)
        if (contentIntent != null) builder.setContentIntent(contentIntent)
        return builder.build()
    }

    companion object {
        const val EXTRA_VIDEO = "video"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_HANGUP = "hangup"
        const val ACTION_HANGUP = "app.nymchat.call.HANGUP"
        private const val CHANNEL_ID = "nym_ongoing_call"
        private const val NOTIFICATION_ID = 4712

        @Volatile
        var onHangup: (() -> Unit)? = null
    }
}
