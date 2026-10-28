package com.nym.bar

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

class NetworkWatch(private val context: Context, private val channel: MethodChannel) {
    private val main = Handler(Looper.getMainLooper())
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var current: Network? = null

    fun start() {
        if (callback != null) return
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        current = manager.activeNetwork
        val watch = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                main.post {
                    if (network != current) {
                        current = network
                        report("networkChanged")
                    }
                }
            }

            override fun onLost(network: Network) {
                main.post {
                    if (network == current) {
                        current = null
                        report("networkLost")
                    }
                }
            }
        }
        try {
            manager.registerDefaultNetworkCallback(watch)
            callback = watch
        } catch (t: Throwable) {
            callback = null
        }
    }

    fun stop() {
        val watch = callback ?: return
        callback = null
        main.removeCallbacksAndMessages(null)
        try {
            val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            manager?.unregisterNetworkCallback(watch)
        } catch (t: Throwable) {
        }
    }

    private fun report(method: String) {
        if (callback == null) return
        try {
            channel.invokeMethod(method, null)
        } catch (t: Throwable) {
        }
    }
}
