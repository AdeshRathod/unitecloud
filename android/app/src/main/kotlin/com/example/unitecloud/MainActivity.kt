package com.example.unitecloud

import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "nfc_utils"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openNfcSettings" -> {
                    openNfcSettings()
                    result.success(null)
                }
                "isNfcEnabled" -> {
                    val nfcAdapter = android.nfc.NfcAdapter.getDefaultAdapter(this@MainActivity)
                    result.success(nfcAdapter != null && nfcAdapter.isEnabled)
                }
                "hasNfcHardware" -> {
                    val nfcAdapter = android.nfc.NfcAdapter.getDefaultAdapter(this@MainActivity)
                    result.success(nfcAdapter != null)
                }
                else -> result.notImplemented()
            }
        }
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