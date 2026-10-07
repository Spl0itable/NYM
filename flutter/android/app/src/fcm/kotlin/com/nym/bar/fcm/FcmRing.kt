package com.nym.bar.fcm

import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.nym.bar.NymRing
import com.nym.bar.R
import com.nym.bar.RingTokenSource

class FcmRing : RingTokenSource {
    override fun fetchToken(context: Context, done: (String?) -> Unit) {
        if (!ensureApp(context)) {
            done(null)
            return
        }
        try {
            FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                done(if (task.isSuccessful) task.result else null)
            }
        } catch (t: Throwable) {
            done(null)
        }
    }

    override fun deleteToken(context: Context) {
        if (!ensureApp(context)) return
        try {
            FirebaseMessaging.getInstance().deleteToken()
        } catch (t: Throwable) {
        }
    }

    companion object {
        fun ensureApp(context: Context): Boolean = try {
            if (FirebaseApp.getApps(context).isEmpty()) {
                val options = FirebaseOptions.Builder()
                    .setApplicationId(context.getString(R.string.fcm_app_id))
                    .setApiKey(context.getString(R.string.fcm_api_key))
                    .setProjectId(context.getString(R.string.fcm_project_id))
                    .setGcmSenderId(context.getString(R.string.fcm_sender_id))
                    .build()
                FirebaseApp.initializeApp(context, options)
            }
            true
        } catch (t: Throwable) {
            false
        }
    }
}

class NymRingMessagingService : FirebaseMessagingService() {
    override fun onCreate() {
        FcmRing.ensureApp(applicationContext)
        super.onCreate()
    }

    override fun onMessageReceived(message: RemoteMessage) {
        if (message.data["t"] == "r") NymRing.onRingPush(applicationContext)
    }

    override fun onNewToken(token: String) {
        NymRing.onNewToken(token)
    }
}
