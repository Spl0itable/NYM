package com.nym.bar

import android.nfc.cardemulation.HostApduService
import android.os.Bundle

class NymNdefHceService : HostApduService() {
    override fun processCommandApdu(commandApdu: ByteArray?, extras: Bundle?): ByteArray =
        NfcShare.respond(commandApdu ?: ByteArray(0))

    override fun onDeactivated(reason: Int) {
        NfcShare.deactivated()
    }
}
