package com.nym.bar

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

object BluetoothName {
    const val CHANNEL = "app.nymchat/bluetooth_name"
    private const val PREFS = "nym_bluetooth_name"
    private const val KEY_ORIGINAL = "original"
    private val MESH_NAME = Regex("^[0-9a-f]{16}$")

    fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "read" -> result.success(read(context))
            "save" -> result.success(save(context, call.argument<String>("name")))
            "restore" -> result.success(restore(context, call.argument<String>("name")))
            else -> result.notImplemented()
        }
    }

    private fun adapter(context: Context): BluetoothAdapter? =
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private fun granted(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) ==
            PackageManager.PERMISSION_GRANTED

    private fun currentName(context: Context): String? {
        if (!granted(context)) return null
        return try {
            adapter(context)?.name
        } catch (e: SecurityException) {
            null
        }
    }

    private fun read(context: Context): Map<String, String?> {
        val deviceName = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N_MR1) {
            try {
                Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
            } catch (e: Exception) {
                null
            }
        } else {
            null
        }
        return mapOf(
            "name" to currentName(context),
            "saved" to context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_ORIGINAL, null),
            "deviceName" to deviceName,
            "model" to Build.MODEL,
        )
    }

    private fun save(context: Context, name: String?): Boolean {
        if (name.isNullOrBlank() || MESH_NAME.matches(name)) return false
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getString(KEY_ORIGINAL, null) != null) return false
        if (currentName(context) != name) return false
        prefs.edit().putString(KEY_ORIGINAL, name).apply()
        return true
    }

    private fun restore(context: Context, name: String?): Boolean {
        if (name.isNullOrBlank() || MESH_NAME.matches(name) || !granted(context)) return false
        val adapter = adapter(context) ?: return false
        return try {
            val current = adapter.name
            if (current != null && MESH_NAME.matches(current)) adapter.setName(name) else false
        } catch (e: SecurityException) {
            false
        }
    }
}
