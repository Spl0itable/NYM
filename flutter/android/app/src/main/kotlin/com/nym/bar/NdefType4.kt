package com.nym.bar

class NdefType4(
    private val cc: ByteArray,
    private val ndef: ByteArray,
    private val armed: Boolean,
) {
    private var appSelected = false
    private var selected: ByteArray? = null

    fun reset() {
        appSelected = false
        selected = null
    }

    fun process(apdu: ByteArray): ByteArray {
        if (apdu.size < 4) return SW_WRONG_LENGTH
        if (apdu[0].toInt() != 0x00) return SW_CLA
        val ins = apdu[1].toInt() and 0xFF
        val p1 = apdu[2].toInt() and 0xFF
        val p2 = apdu[3].toInt() and 0xFF
        return when (ins) {
            0xA4 -> select(apdu, p1, p2)
            0xB0 -> read(apdu, p1, p2)
            0xD6 -> SW_SECURITY
            else -> SW_INS
        }
    }

    private fun select(apdu: ByteArray, p1: Int, p2: Int): ByteArray {
        if (apdu.size < 5) return SW_WRONG_LENGTH
        val lc = apdu[4].toInt() and 0xFF
        if (apdu.size < 5 + lc) return SW_WRONG_LENGTH
        val data = apdu.copyOfRange(5, 5 + lc)
        return when (p1) {
            0x04 -> {
                if (armed && data.contentEquals(AID)) {
                    appSelected = true
                    selected = null
                    SW_OK
                } else {
                    SW_NOT_FOUND
                }
            }
            0x00 -> {
                if (p2 != 0x0C && p2 != 0x00) return SW_P1P2
                if (!armed || !appSelected || lc != 2) return SW_NOT_FOUND
                when {
                    data.contentEquals(CC_FILE) -> {
                        selected = cc
                        SW_OK
                    }
                    data.contentEquals(NDEF_FILE) -> {
                        selected = ndef
                        SW_OK
                    }
                    else -> SW_NOT_FOUND
                }
            }
            else -> SW_NOT_FOUND
        }
    }

    private fun read(apdu: ByteArray, p1: Int, p2: Int): ByteArray {
        val file = selected ?: return SW_NOT_FOUND
        if (!armed) return SW_NOT_FOUND
        if (p1 and 0x80 != 0) return SW_P1P2
        val offset = (p1 shl 8) or p2
        if (offset >= file.size) return SW_WRONG_OFFSET
        val le = if (apdu.size >= 5) {
            val v = apdu[4].toInt() and 0xFF
            if (v == 0) 256 else v
        } else {
            256
        }
        val n = minOf(le, file.size - offset)
        return file.copyOfRange(offset, offset + n) + SW_OK
    }

    companion object {
        val AID = byteArrayOf(0xD2.toByte(), 0x76, 0x00, 0x00, 0x85.toByte(), 0x01, 0x01)
        val CC_FILE = byteArrayOf(0xE1.toByte(), 0x03)
        val NDEF_FILE = byteArrayOf(0xE1.toByte(), 0x04)
        val SW_OK = byteArrayOf(0x90.toByte(), 0x00)
        val SW_NOT_FOUND = byteArrayOf(0x6A, 0x82.toByte())
        val SW_WRONG_OFFSET = byteArrayOf(0x6B, 0x00)
        val SW_SECURITY = byteArrayOf(0x69, 0x82.toByte())
        val SW_INS = byteArrayOf(0x6D, 0x00)
        val SW_CLA = byteArrayOf(0x6E, 0x00)
        val SW_P1P2 = byteArrayOf(0x6A, 0x86.toByte())
        val SW_WRONG_LENGTH = byteArrayOf(0x67, 0x00)
    }
}
