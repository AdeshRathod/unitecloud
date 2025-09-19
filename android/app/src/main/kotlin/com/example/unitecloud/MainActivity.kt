package com.example.unitecloud

import android.content.Intent
import android.content.ComponentName
import android.os.Build
import android.provider.Settings
import android.os.Bundle
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.IsoDep
import android.nfc.cardemulation.CardEmulation
import java.nio.charset.Charset
import java.util.concurrent.atomic.AtomicBoolean
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "nfc_utils"
    private var nfcAdapter: NfcAdapter? = null
    @Volatile private var readerActive = AtomicBoolean(false)
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        nfcAdapter = NfcAdapter.getDefaultAdapter(this@MainActivity)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openNfcSettings" -> {
                    openNfcSettings()
                    result.success(null)
                }
                "isNfcEnabled" -> {
                    val adapter = NfcAdapter.getDefaultAdapter(this@MainActivity)
                    result.success(adapter != null && adapter.isEnabled)
                }
                "hasNfcHardware" -> {
                    val adapter = NfcAdapter.getDefaultAdapter(this@MainActivity)
                    result.success(adapter != null)
                }
                // HCE controls
                "hceSetPayload" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null) {
                        result.error("ARG", "bytes is required", null)
                    } else {
                        HceDataStore.setPayload(bytes)
                        result.success(null)
                    }
                }
                "hceClear" -> {
                    HceDataStore.clear()
                    result.success(null)
                }
                "hceReadOnce" -> {
                    val timeoutMs = (call.argument<Int>("timeoutMs") ?: 15000)
                    startReaderOnce(timeoutMs, result)
                }
                "getAndroidId" -> {
                    try {
                        val id = android.provider.Settings.Secure.getString(contentResolver, android.provider.Settings.Secure.ANDROID_ID)
                        result.success(id ?: "")
                    } catch (e: Exception) {
                        result.error("ID", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onResume() {
        super.onResume()
        try {
            val adapter = nfcAdapter ?: return
            val ce = CardEmulation.getInstance(adapter)
            val cn = ComponentName(this, HceCardService::class.java)
            ce.setPreferredService(this, cn)
        } catch (_: Exception) { }
    }

    override fun onPause() {
        super.onPause()
        if (readerActive.get()) {
            // Cancel any in-flight read to avoid callbacks after pause
            disableReaderMode()
            try {
                pendingResult?.error("CANCELLED", "Activity paused", null)
            } catch (_: Exception) { }
            pendingResult = null
        }
        try {
            val adapter = nfcAdapter ?: return
            val ce = CardEmulation.getInstance(adapter)
            ce.unsetPreferredService(this)
        } catch (_: Exception) { }
    }

    override fun onDestroy() {
        super.onDestroy()
        if (readerActive.get()) {
            disableReaderMode()
        }
        pendingResult = null
    }

    private fun startReaderOnce(timeoutMs: Int, result: MethodChannel.Result) {
        val adapter = nfcAdapter
        if (adapter == null) {
            result.error("NFC", "NFC adapter not available", null)
            return
        }
        if (pendingResult != null) {
            result.error("BUSY", "Another NFC read is in progress", null)
            return
        }
        pendingResult = result
        readerActive.set(true)

    val flags = NfcAdapter.FLAG_READER_NFC_A or NfcAdapter.FLAG_READER_NFC_B or NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK or NfcAdapter.FLAG_READER_NO_PLATFORM_SOUNDS
        adapter.enableReaderMode(this, { tag: Tag ->
            if (!readerActive.get()) return@enableReaderMode
            try {
                val iso = IsoDep.get(tag)
                if (iso == null) {
                    finishWithError("TAG", "IsoDep not supported")
                    return@enableReaderMode
                }
                iso.connect()
                iso.timeout = 10000
                val selectResp = iso.transceive(buildSelectAid())
                if (!isSwOk(selectResp)) {
                    iso.close()
                    finishWithError("APDU", "SELECT failed: ${swString(selectResp)}")
                    return@enableReaderMode
                }
                val data = ArrayList<Byte>()
                var chunkIndex = 0
                while (true) {
                    var resp = iso.transceive(buildGetChunk(chunkIndex))
                    if (!isSwOk(resp)) {
                        // If 6A82 (not found), try re-select then retry once
                        if (isSw6A82(resp)) {
                            val sel = iso.transceive(buildSelectAid())
                            if (isSwOk(sel)) {
                                resp = iso.transceive(buildGetChunk(chunkIndex))
                            }
                        }
                    }
                    if (!isSwOk(resp)) {
                        iso.close()
                        finishWithError("APDU", "GET-CHUNK failed: ${swString(resp)}")
                        return@enableReaderMode
                    }
                    val swLen = 2
                    if (resp.size <= swLen) {
                        break
                    }
                    val chunk = resp.copyOfRange(0, resp.size - swLen)
                    for (b in chunk) data.add(b)
                    // If chunk smaller than max, assume last
                    if (chunk.size < 200) break
                    chunkIndex++
                    try { Thread.sleep(15) } catch (_: Exception) { }
                }
                iso.close()
                val out = ByteArray(data.size)
                for (i in data.indices) out[i] = data[i]
                finishWithSuccess(String(out, Charset.forName("UTF-8")))
            } catch (e: Exception) {
                finishWithError("READ", e.message ?: "Reader exception")
            }
        }, flags, Bundle())

        // Timeout
        window.decorView.postDelayed({
            if (readerActive.get()) {
                disableReaderMode()
                finishWithError("TIMEOUT", "No peer detected in ${timeoutMs}ms")
            }
        }, timeoutMs.toLong())
    }

    private fun finishWithSuccess(data: String) {
        runOnUiThread {
            try { pendingResult?.success(data) } catch (_: Exception) { }
            pendingResult = null
            disableReaderMode()
        }
    }

    private fun finishWithError(code: String, message: String) {
        runOnUiThread {
            try { pendingResult?.error(code, message, null) } catch (_: Exception) { }
            pendingResult = null
            disableReaderMode()
        }
    }

    private fun disableReaderMode() {
        readerActive.set(false)
        try {
            nfcAdapter?.disableReaderMode(this)
        } catch (_: Exception) {}
    }

    private fun buildSelectAid(): ByteArray {
        val aid = byteArrayOf(0xF0.toByte(), 0x01, 0x02, 0x03, 0x04, 0x05, 0x06)
        val lc = aid.size.toByte()
        return byteArrayOf(0x00, 0xA4.toByte(), 0x04, 0x00, lc) + aid
    }

    private fun buildGetChunk(index: Int): ByteArray {
        val p1 = (index and 0xFF).toByte()
        return byteArrayOf(0x80.toByte(), 0x10, p1, 0x00)
    }

    private fun isSwOk(resp: ByteArray): Boolean {
        if (resp.size < 2) return false
        val sw1 = resp[resp.size - 2]
        val sw2 = resp[resp.size - 1]
        return (sw1.toInt() and 0xFF) == 0x90 && (sw2.toInt() and 0xFF) == 0x00
    }

    private fun isSw6A82(resp: ByteArray): Boolean {
        if (resp.size < 2) return false
        val sw1 = resp[resp.size - 2]
        val sw2 = resp[resp.size - 1]
        return (sw1.toInt() and 0xFF) == 0x6A && (sw2.toInt() and 0xFF) == 0x82
    }

    private fun swString(resp: ByteArray): String {
        if (resp.size < 2) return "(no sw)"
        val sw1 = resp[resp.size - 2]
        val sw2 = resp[resp.size - 1]
        return String.format("%02X%02X", sw1, sw2)
    }

    private fun openNfcSettings() {
        try {
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN) {
                Intent(Settings.ACTION_NFC_SETTINGS)
            } else {
                Intent(Settings.ACTION_WIRELESS_SETTINGS)
            }
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        } catch (e: Exception) {
            // fallback: open wireless settings
            val fallbackIntent = Intent(Settings.ACTION_WIRELESS_SETTINGS)
            fallbackIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(fallbackIntent)
        }
    }
}