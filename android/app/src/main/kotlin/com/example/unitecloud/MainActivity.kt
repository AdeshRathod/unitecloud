package com.example.unitecloud

import android.content.ComponentName
import android.content.Intent
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.cardemulation.CardEmulation
import android.nfc.tech.IsoDep
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.charset.Charset
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    private val CHANNEL = "nfc_utils"
    private var nfcAdapter: NfcAdapter? = null
    @Volatile private var readerActive = AtomicBoolean(false)
    private var pendingResult: MethodChannel.Result? = null
    private var completingResult = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        nfcAdapter = NfcAdapter.getDefaultAdapter(this@MainActivity)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Settings / capability
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
                    "getAndroidId" -> {
                        val id = Settings.Secure.getString(
                            contentResolver,
                            Settings.Secure.ANDROID_ID
                        )
                        result.success(id)
                    }

                    // HCE controls
                    "hceSetPayload" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        if (bytes == null) {
                            result.error("ARG", "bytes is required", null)
                            return@setMethodCallHandler
                        }
                        HceDataStore.setPayload(bytes)
                        try {
                            val adapter = nfcAdapter
                            if (adapter != null) {
                                val ce = CardEmulation.getInstance(adapter)
                                val cn = ComponentName(this, HceCardService::class.java)
                                ce.setPreferredService(this, cn)
                            }
                        } catch (_: Exception) { }
                        result.success(null)
                    }
                    "hceClear" -> {
                        HceDataStore.clear()
                        try {
                            val adapter = nfcAdapter
                            if (adapter != null) {
                                val ce = CardEmulation.getInstance(adapter)
                                ce.unsetPreferredService(this)
                            }
                        } catch (_: Exception) { }
                        result.success(null)
                    }
                    "hceDisableReader" -> {
                        disableReaderMode()
                        result.success(null)
                    }
                    "hceReadOnce" -> {
                        val timeoutMs = (call.argument<Int>("timeoutMs") ?: 20000)
                        startReaderOnce(timeoutMs, result)
                    }
                    "hceHasPayload" -> {
                        result.success(HceDataStore.get() != null)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onPause() {
        super.onPause()
        if (readerActive.get()) {
            // Cancel any in-flight read to avoid callbacks after pause
            disableReaderMode()
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
    }

    private fun startReaderOnce(timeoutMs: Int, result: MethodChannel.Result) {
        val adapter = nfcAdapter
        if (adapter == null) {
            result.error("NFC", "NFC adapter not available", null)
            return
        }
        if (pendingResult != null) {
            // Defensive: forcibly clear any stuck reader before reporting BUSY
            disableReaderMode()
            result.error("BUSY", "Another NFC read is in progress (resetting)", null)
            return
        }
        pendingResult = result
        readerActive.set(true)

        val flags = (
            NfcAdapter.FLAG_READER_NFC_A or
            NfcAdapter.FLAG_READER_NFC_B or
            NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK or
            NfcAdapter.FLAG_READER_NO_PLATFORM_SOUNDS
        )
        adapter.enableReaderMode(this, { tag: Tag ->
            if (!readerActive.get()) return@enableReaderMode
            try {
                val iso = IsoDep.get(tag)
                if (iso == null) {
                    finishWithError("TAG", "IsoDep not supported")
                    return@enableReaderMode
                }

                fun doExchange(dep: IsoDep): ByteArray {
                    dep.connect()
                    dep.timeout = 10000
                    val selectResp = dep.transceive(buildSelectAid())
                    if (!isSwOk(selectResp)) {
                        dep.close()
                        throw RuntimeException("SELECT failed: ${swString(selectResp)}")
                    }
                    val data = ArrayList<Byte>()
                    var chunkIndex = 0
                    while (true) {
                        var resp = dep.transceive(buildGetChunk(chunkIndex))
                        if (!isSwOk(resp)) {
                            // If 6A82 (not found), try re-select then retry once
                            if (isSw6A82(resp)) {
                                val sel = dep.transceive(buildSelectAid())
                                if (isSwOk(sel)) {
                                    resp = dep.transceive(buildGetChunk(chunkIndex))
                                }
                            }
                        }
                        if (!isSwOk(resp)) {
                            dep.close()
                            throw RuntimeException("GET-CHUNK failed: ${swString(resp)}")
                        }
                        val swLen = 2
                        if (resp.size <= swLen) break
                        val chunk = resp.copyOfRange(0, resp.size - swLen)
                        for (b in chunk) data.add(b)
                        if (chunk.size < 200) break // last chunk
                        chunkIndex++
                        try { Thread.sleep(15) } catch (_: Exception) { }
                    }
                    dep.close()
                    val out = ByteArray(data.size)
                    for (i in data.indices) out[i] = data[i]
                    return out
                }

                var bytes = ByteArray(0)
                try {
                    bytes = doExchange(iso)
                } catch (e: Exception) {
                    // Handle transient errors like Tag lost with a brief pause and one reconnect attempt.
                    try { Thread.sleep(120) } catch (_: Exception) {}
                    try {
                        val iso2 = IsoDep.get(tag)
                        if (iso2 != null) {
                            bytes = doExchange(iso2)
                        } else {
                            throw e
                        }
                    } catch (_: Exception) {
                        throw e
                    }
                }
                finishWithSuccess(String(bytes, Charset.forName("UTF-8")))
            } catch (e: Exception) {
                finishWithError("READ", e.message ?: "Reader exception")
            }
        }, flags, Bundle())

        // Timeout
        window.decorView.postDelayed({
            if (readerActive.get()) {
                // Let finishWithError handle cleanup to avoid double-cancel
                finishWithError("TIMEOUT", "No peer detected in ${timeoutMs}ms")
            }
        }, timeoutMs.toLong())
    }

    private fun finishWithSuccess(data: String) {
        runOnUiThread {
            completingResult = true
            try { pendingResult?.success(data) } catch (_: Exception) { }
            pendingResult = null
            readerActive.set(false)
            try { nfcAdapter?.disableReaderMode(this) } catch (_: Exception) {}
            completingResult = false
        }
    }

    private fun finishWithError(code: String, message: String) {
        runOnUiThread {
            completingResult = true
            try { pendingResult?.error(code, message, null) } catch (_: Exception) { }
            pendingResult = null
            readerActive.set(false)
            try { nfcAdapter?.disableReaderMode(this) } catch (_: Exception) {}
            completingResult = false
        }
    }

    private fun disableReaderMode() {
        readerActive.set(false)
        try {
            nfcAdapter?.disableReaderMode(this)
        } catch (_: Exception) {}
        // Only send CANCELLED if not already completing result
        if (!completingResult && pendingResult != null) {
            try { pendingResult?.error("CANCELLED", "Reader disabled/reset", null) } catch (_: Exception) {}
            pendingResult = null
        }
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