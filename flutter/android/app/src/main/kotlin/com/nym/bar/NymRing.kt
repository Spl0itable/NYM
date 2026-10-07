package com.nym.bar

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat

interface RingTokenSource {
    fun fetchToken(context: Context, done: (String?) -> Unit)
    fun deleteToken(context: Context)
}

object NymRing {
    const val ACTION_ANSWER = "app.nymchat.call.ANSWER"
    const val ACTION_DECLINE = "app.nymchat.call.DECLINE"
    const val ACTION_OPEN = "app.nymchat.call.OPEN"
    const val EXTRA_CALL_ID = "callId"
    private const val CHANNEL_ID = "nym_incoming_call"
    private const val NOTIFICATION_ID = 4713
    private const val PREFS = "FlutterSharedPreferences"
    private const val WAKE_KEY = "flutter.nym_ring_wake"
    private const val STRINGS = "nym_ring_strings"
    private const val RING_TIMEOUT_MS = 45_000L

    @Volatile
    var foreground = false

    @Volatile
    var onToken: ((String) -> Unit)? = null

    @Volatile
    var onAction: ((String, String) -> Unit)? = null

    fun source(): RingTokenSource? = try {
        Class.forName("com.nym.bar.fcm.FcmRing").getDeclaredConstructor().newInstance() as RingTokenSource
    } catch (t: Throwable) {
        null
    }

    fun supported(): Boolean = source() != null

    fun enabled(context: Context): Boolean = try {
        !context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(WAKE_KEY, null).isNullOrEmpty()
    } catch (t: Throwable) {
        false
    }

    fun saveStrings(context: Context, strings: Map<String, String>) {
        val edit = context.getSharedPreferences(STRINGS, Context.MODE_PRIVATE).edit()
        for ((k, v) in strings) edit.putString(k, v)
        edit.apply()
    }

    private fun text(context: Context, key: String, fallback: String): String =
        context.getSharedPreferences(STRINGS, Context.MODE_PRIVATE).getString(key, null) ?: fallback

    fun onNewToken(token: String) {
        onToken?.invoke(token)
    }

    fun onRingPush(context: Context) {
        if (foreground || !enabled(context)) return
        show(
            context,
            "",
            text(context, "incoming", "Incoming call"),
            text(context, "openToSee", "Open Nymchat to answer"),
            false,
        )
    }

    private fun createChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            text(context, "channel", "Incoming calls"),
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            setShowBadge(false)
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        }
        manager.createNotificationChannel(channel)
    }

    private fun activityIntent(context: Context, action: String, callId: String, code: Int): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            this.action = action
            putExtra(EXTRA_CALL_ID, callId)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        return PendingIntent.getActivity(
            context, code, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun declineIntent(context: Context, callId: String): PendingIntent {
        val intent = Intent(context, NymCallActionReceiver::class.java).apply {
            action = ACTION_DECLINE
            putExtra(EXTRA_CALL_ID, callId)
        }
        return PendingIntent.getBroadcast(
            context, 3, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    fun show(context: Context, callId: String, title: String, body: String, video: Boolean) {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return
        createChannel(context)
        val open = activityIntent(context, ACTION_OPEN, callId, 1)
        val answer = activityIntent(context, if (callId.isEmpty()) ACTION_OPEN else ACTION_ANSWER, callId, 2)
        val decline = declineIntent(context, callId)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context).setPriority(Notification.PRIORITY_MAX)
        }
        builder
            .setSmallIcon(android.R.drawable.sym_call_incoming)
            .setContentTitle(title)
            .setContentText(body)
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setOngoing(true)
            .setAutoCancel(false)
            .setContentIntent(open)
            .setFullScreenIntent(open, true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) builder.setTimeoutAfter(RING_TIMEOUT_MS)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val person = Person.Builder().setName(title).setImportant(true).build()
            builder.setStyle(Notification.CallStyle.forIncomingCall(person, decline, answer).setIsVideo(video))
        } else {
            builder.addAction(Notification.Action.Builder(null, text(context, "decline", "Decline"), decline).build())
            builder.addAction(Notification.Action.Builder(null, text(context, "answer", "Answer"), answer).build())
        }
        try {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(NOTIFICATION_ID, builder.build())
        } catch (t: Throwable) {
        }
    }

    fun cancel(context: Context) {
        try {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.cancel(NOTIFICATION_ID)
        } catch (t: Throwable) {
        }
    }
}

class NymCallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != NymRing.ACTION_DECLINE) return
        NymRing.cancel(context)
        val callId = intent.getStringExtra(NymRing.EXTRA_CALL_ID) ?: ""
        if (callId.isNotEmpty()) NymRing.onAction?.invoke("decline", callId)
    }
}
