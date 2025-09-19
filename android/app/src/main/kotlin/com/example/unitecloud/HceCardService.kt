package com.example.unitecloud

import android.nfc.cardemulation.HostApduService
import android.os.Bundle

class HceDataStore {
    companion object {
        @Volatile
        private var data: ByteArray? = null
        const val MAX_CHUNK = 200 // slightly smaller to improve timing/compatibility

        fun setPayload(bytes: ByteArray) {
            data = bytes
        }

        fun clear() {
            data = null
        }

        fun get(): ByteArray? = data
    }
}

class HceCardService : HostApduService() {
    private val AID = byteArrayOf(
        0xF0.toByte(), 0x01, 0x02, 0x03, 0x04, 0x05, 0x06
    )

    private val SW_OK = byteArrayOf(0x90.toByte(), 0x00)
    private val SW_NOT_FOUND = byteArrayOf(0x6A.toByte(), 0x82.toByte())
    private val SW_INS_NOT_SUPPORTED = byteArrayOf(0x6D.toByte(), 0x00)

    override fun processCommandApdu(commandApdu: ByteArray?, extras: Bundle?): ByteArray {
        if (commandApdu == null || commandApdu.isEmpty()) return SW_INS_NOT_SUPPORTED

        // SELECT by AID: 00 A4 04 00 Lc AID
        if (isSelectAID(commandApdu)) {
            val ok = matchesAID(commandApdu)
            return if (ok) SW_OK else SW_NOT_FOUND
        }

        // Custom GET-CHUNK: CLA=0x80, INS=0x10, P1=chunkIndex, P2=0x00
        if (commandApdu.size >= 4 && commandApdu[0] == 0x80.toByte() && commandApdu[1] == 0x10.toByte()) {
            val chunkIndex = (commandApdu[2].toInt() and 0xFF)
            val payload = HceDataStore.get() ?: return SW_NOT_FOUND
            val offset = chunkIndex * HceDataStore.MAX_CHUNK
            if (offset >= payload.size) {
                return SW_OK
            }
            val end = minOf(payload.size, offset + HceDataStore.MAX_CHUNK)
            val slice = payload.copyOfRange(offset, end)
            return slice + SW_OK
        }

        return SW_INS_NOT_SUPPORTED
    }

    override fun onDeactivated(reason: Int) { }

    private fun isSelectAID(apdu: ByteArray): Boolean {
        if (apdu.size < 5) return false
        return apdu[0] == 0x00.toByte() && apdu[1] == 0xA4.toByte() && apdu[2] == 0x04.toByte() && apdu[3] == 0x00.toByte()
    }

    private fun matchesAID(apdu: ByteArray): Boolean {
        val lc = apdu[4].toInt() and 0xFF
        if (apdu.size < 5 + lc) return false
        val aid = apdu.copyOfRange(5, 5 + lc)
        if (aid.size != AID.size) return false
        for (i in aid.indices) if (aid[i] != AID[i]) return false
        return true
    }
}
