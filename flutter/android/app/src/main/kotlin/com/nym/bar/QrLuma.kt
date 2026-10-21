package com.nym.bar

import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.LuminanceSource
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader

object QrLuma {
    const val MAX_TEXT = 8192

    private val hints: Map<DecodeHintType, Any> = mapOf(
        DecodeHintType.TRY_HARDER to true,
        DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
        DecodeHintType.CHARACTER_SET to "UTF-8",
    )

    fun decodeY(y: ByteArray, width: Int, height: Int, rowStride: Int): String? {
        if (width <= 0 || height <= 0 || rowStride < width) return null
        if (y.size < rowStride * (height - 1) + width) return null
        val data = if (y.size >= rowStride * height) y else y.copyOf(rowStride * height)
        return decode(PlanarYUVLuminanceSource(data, rowStride, height, 0, 0, width, height, false))
    }

    fun decodeArgb(pixels: IntArray, width: Int, height: Int): String? {
        if (width <= 0 || height <= 0 || pixels.size < width * height) return null
        return decode(RGBLuminanceSource(width, height, pixels))
    }

    fun decode(source: LuminanceSource): String? {
        val text = attempt(source) ?: attempt(source.invert()) ?: return null
        return if (text.length > MAX_TEXT) null else text
    }

    private fun attempt(source: LuminanceSource): String? {
        val reader = QRCodeReader()
        return try {
            reader.decode(BinaryBitmap(HybridBinarizer(source)), hints).text
        } catch (e: Exception) {
            null
        } finally {
            reader.reset()
        }
    }
}
