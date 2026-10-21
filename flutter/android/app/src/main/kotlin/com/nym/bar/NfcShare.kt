package com.nym.bar

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.nfc.NdefMessage
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.cardemulation.CardEmulation
import android.nfc.tech.Ndef
import android.nfc.tech.NdefFormatable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.Closeable
import java.lang.ref.WeakReference

object NfcShare {
    const val CHANNEL = "app.nymchat/nfc"
    private const val MAX_TTL_MS = 60_000L
    private const val SESSION_MS = 30_000L
    private const val MAX_FILE = 0x0800
    private const val MAX_RECORDS = 16
    private const val READER_FLAGS = NfcAdapter.FLAG_READER_NFC_A or
        NfcAdapter.FLAG_READER_NFC_B or
        NfcAdapter.FLAG_READER_NFC_F or
        NfcAdapter.FLAG_READER_NFC_V

    private enum class Mode { READ, WRITE, LOCK }

    private val main = Handler(Looper.getMainLooper())
    private val lock = Any()
    private val idle = NdefType4(ByteArray(0), ByteArray(0), false)
    private var emulator: NdefType4? = null
    private var expiresAt = 0L
    private var activityRef: WeakReference<FlutterFragmentActivity>? = null
    private var pending: MethodChannel.Result? = null
    private var mode = Mode.READ
    private var bytes = ByteArray(0)
    private var session = 0

    private val disarmTask = Runnable { activityRef?.get()?.let { disarm(it) } }
    private val sessionTimeout = Runnable { finishSession(null) }

    fun respond(apdu: ByteArray): ByteArray = synchronized(lock) {
        val e = emulator
        if (e == null || SystemClock.elapsedRealtime() > expiresAt) idle.process(apdu) else e.process(apdu)
    }

    fun deactivated() {
        synchronized(lock) { emulator?.reset() }
    }

    fun register(activity: FlutterFragmentActivity, messenger: BinaryMessenger) {
        activityRef = WeakReference(activity)
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result -> handle(activity, call, result) }
    }

    fun onCreate(activity: FlutterFragmentActivity) {
        activityRef = WeakReference(activity)
        try {
            val pm = activity.packageManager
            val c = component(activity)
            if (pm.getComponentEnabledSetting(c) == PackageManager.COMPONENT_ENABLED_STATE_ENABLED) {
                setComponent(activity, false)
            }
        } catch (_: Exception) {
        }
    }

    fun onResume(activity: FlutterFragmentActivity) {
        activityRef = WeakReference(activity)
    }

    fun onPause(activity: FlutterFragmentActivity) {
        disarm(activity)
        finishSession(null)
    }

    private fun adapter(context: Context): NfcAdapter? = try {
        NfcAdapter.getDefaultAdapter(context)
    } catch (_: Exception) {
        null
    }

    private fun component(context: Context) = ComponentName(context, NymNdefHceService::class.java)

    private fun setComponent(context: Context, enabled: Boolean) {
        val state = if (enabled) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        } else {
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        }
        context.packageManager.setComponentEnabledSetting(component(context), state, PackageManager.DONT_KILL_APP)
    }

    private fun handle(activity: FlutterFragmentActivity, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "caps" -> {
                val a = adapter(activity)
                val hce = activity.packageManager.hasSystemFeature(PackageManager.FEATURE_NFC_HOST_CARD_EMULATION)
                result.success(
                    mapOf(
                        "nfc" to (a != null),
                        "enabled" to (a?.isEnabled == true),
                        "hce" to (a != null && hce),
                        "read" to (a != null),
                        "write" to (a != null),
                        "systemUi" to false,
                    ),
                )
            }
            "arm" -> {
                val cc = call.argument<ByteArray>("cc")
                val file = call.argument<ByteArray>("file")
                val ttl = (call.argument<Int>("ttlMs") ?: 0).toLong().coerceIn(0L, MAX_TTL_MS)
                result.success(arm(activity, cc, file, ttl))
            }
            "disarm" -> {
                disarm(activity)
                result.success(null)
            }
            "openSettings" -> {
                openSettings(activity)
                result.success(null)
            }
            "read" -> startSession(activity, Mode.READ, ByteArray(0), result)
            "write" -> {
                val message = call.argument<ByteArray>("message")
                if (message == null || message.isEmpty() || message.size > MAX_FILE) {
                    result.success(mapOf("status" to "failed"))
                } else {
                    startSession(activity, Mode.WRITE, message, result)
                }
            }
            "lock" -> {
                val message = call.argument<ByteArray>("message")
                if (message == null || message.isEmpty()) {
                    result.success(mapOf("status" to "failed"))
                } else {
                    startSession(activity, Mode.LOCK, message, result)
                }
            }
            "cancel" -> {
                finishSession(null)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun arm(activity: Activity, cc: ByteArray?, file: ByteArray?, ttl: Long): Boolean {
        if (cc == null || cc.size != 15 || file == null || file.size < 2 || file.size > MAX_FILE || ttl <= 0L) return false
        val a = adapter(activity) ?: return false
        if (!a.isEnabled) return false
        if (!activity.packageManager.hasSystemFeature(PackageManager.FEATURE_NFC_HOST_CARD_EMULATION)) return false
        synchronized(lock) {
            emulator = NdefType4(cc.copyOf(), file.copyOf(), true)
            expiresAt = SystemClock.elapsedRealtime() + ttl
        }
        main.removeCallbacks(disarmTask)
        main.postDelayed(disarmTask, ttl)
        return try {
            setComponent(activity, true)
            CardEmulation.getInstance(a).setPreferredService(activity, component(activity))
            true
        } catch (_: Exception) {
            disarm(activity)
            false
        }
    }

    private fun disarm(activity: Activity) {
        main.removeCallbacks(disarmTask)
        val was = synchronized(lock) {
            val armed = emulator != null
            emulator = null
            expiresAt = 0L
            armed
        }
        if (!was) return
        try {
            adapter(activity)?.let { CardEmulation.getInstance(it).unsetPreferredService(activity) }
        } catch (_: Exception) {
        }
        try {
            setComponent(activity, false)
        } catch (_: Exception) {
        }
    }

    private fun openSettings(activity: Activity) {
        try {
            activity.startActivity(Intent(Settings.ACTION_NFC_SETTINGS))
        } catch (_: Exception) {
            try {
                activity.startActivity(Intent(Settings.ACTION_WIRELESS_SETTINGS))
            } catch (_: Exception) {
            }
        }
    }

    private fun startSession(activity: Activity, m: Mode, data: ByteArray, result: MethodChannel.Result) {
        finishSession(null)
        val a = adapter(activity)
        if (a == null || !a.isEnabled) {
            result.success(null)
            return
        }
        val id = ++session
        pending = result
        synchronized(lock) {
            mode = m
            bytes = data
        }
        val extras = Bundle().apply { putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, 250) }
        try {
            a.enableReaderMode(activity, { tag -> onTag(id, tag) }, READER_FLAGS, extras)
        } catch (_: Exception) {
            finishSession(null)
            return
        }
        main.postDelayed(sessionTimeout, SESSION_MS)
    }

    private fun onTag(id: Int, tag: Tag) {
        val m: Mode
        val data: ByteArray
        synchronized(lock) {
            m = mode
            data = bytes
        }
        val value: Any = when (m) {
            Mode.READ -> readTag(tag)
            Mode.WRITE -> writeTag(tag, data)
            Mode.LOCK -> lockTag(tag, data)
        }
        main.post { if (id == session) finishSession(value) }
    }

    private fun finishSession(value: Any?) {
        main.removeCallbacks(sessionTimeout)
        val r = pending ?: return
        pending = null
        session++
        activityRef?.get()?.let { act ->
            try {
                adapter(act)?.disableReaderMode(act)
            } catch (_: Exception) {
            }
        }
        r.success(value)
    }

    private fun quietly(c: Closeable) {
        try {
            c.close()
        } catch (_: Exception) {
        }
    }

    private fun status(s: String): Map<String, Any> = mapOf("status" to s)

    private fun readTag(tag: Tag): List<List<Any>> {
        val ndef = Ndef.get(tag) ?: return emptyList()
        return try {
            ndef.connect()
            val msg = try {
                ndef.ndefMessage
            } catch (_: Exception) {
                null
            } ?: ndef.cachedNdefMessage
            msg?.records?.take(MAX_RECORDS)?.map {
                listOf(it.tnf.toInt(), it.type ?: ByteArray(0), it.id ?: ByteArray(0), it.payload ?: ByteArray(0))
            } ?: emptyList()
        } catch (_: Exception) {
            emptyList()
        } finally {
            quietly(ndef)
        }
    }

    private fun writeTag(tag: Tag, data: ByteArray): Map<String, Any> {
        val message = try {
            NdefMessage(data)
        } catch (_: Exception) {
            return status("failed")
        }
        val ndef = Ndef.get(tag)
        if (ndef != null) {
            return try {
                ndef.connect()
                when {
                    !ndef.isWritable -> status("readOnly")
                    ndef.maxSize < data.size -> mapOf("status" to "tooSmall", "need" to data.size, "have" to ndef.maxSize)
                    else -> {
                        ndef.writeNdefMessage(message)
                        status("ok")
                    }
                }
            } catch (_: Exception) {
                status("failed")
            } finally {
                quietly(ndef)
            }
        }
        val blank = NdefFormatable.get(tag) ?: return status("notNdef")
        return try {
            blank.connect()
            blank.format(message)
            status("ok")
        } catch (_: Exception) {
            status("failed")
        } finally {
            quietly(blank)
        }
    }

    private fun lockTag(tag: Tag, expected: ByteArray): Map<String, Any> {
        val ndef = Ndef.get(tag) ?: return status("notNdef")
        return try {
            ndef.connect()
            val current = try {
                ndef.ndefMessage?.toByteArray()
            } catch (_: Exception) {
                null
            }
            when {
                current == null || !current.contentEquals(expected) -> status("mismatch")
                !ndef.isWritable -> status("readOnly")
                !ndef.canMakeReadOnly() -> status("failed")
                ndef.makeReadOnly() -> status("ok")
                else -> status("failed")
            }
        } catch (_: Exception) {
            status("failed")
        } finally {
            quietly(ndef)
        }
    }
}
