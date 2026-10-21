package com.nym.bar

import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

object QrDecoder {
    const val CHANNEL = "app.nymchat/qr"
    private const val MAX_SIDE = 1600
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result -> handle(call, result) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "decodeFrame" -> {
                val y = call.argument<ByteArray>("y")
                val width = call.argument<Int>("width") ?: 0
                val height = call.argument<Int>("height") ?: 0
                val rowStride = call.argument<Int>("rowStride") ?: width
                if (y == null) {
                    result.success(null)
                    return
                }
                runOff(result) { QrLuma.decodeY(y, width, height, rowStride) }
            }
            "decodeFile" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.success(null)
                    return
                }
                runOff(result) { decodeFile(path) }
            }
            else -> result.notImplemented()
        }
    }

    private fun runOff(result: MethodChannel.Result, work: () -> String?) {
        executor.execute {
            val text = try {
                work()
            } catch (e: Exception) {
                null
            }
            main.post { result.success(text) }
        }
    }

    private fun decodeFile(path: String): String? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (bounds.outWidth / sample > MAX_SIDE || bounds.outHeight / sample > MAX_SIDE) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        val bitmap = BitmapFactory.decodeFile(path, options) ?: return null
        return try {
            val w = bitmap.width
            val h = bitmap.height
            val pixels = IntArray(w * h)
            bitmap.getPixels(pixels, 0, w, 0, 0, w, h)
            QrLuma.decodeArgb(pixels, w, h)
        } finally {
            bitmap.recycle()
        }
    }
}
