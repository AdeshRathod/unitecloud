import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

class NfcUtils {
  /// Returns true if device has NFC hardware, false otherwise.
  static Future<bool> hasNfcHardware() async {
    const platform = MethodChannel('nfc_utils');
    try {
      final hasNfc = await platform.invokeMethod<bool>('hasNfcHardware');
      if (hasNfc == null) return true;
      return hasNfc;
    } catch (_) {}
    return true;
  }

  static Future<bool> isNfcEnabled() async {
    const platform = MethodChannel('nfc_utils');
    try {
      final enabled = await platform.invokeMethod<bool>('isNfcEnabled');
      if (enabled == null) {
        return true;
      }
      return enabled;
    } catch (_) {}
    return true;
  }

  static Future<void> openNfcSettings() async {
    if (Platform.isAndroid) {
      const platform = MethodChannel('nfc_utils');
      try {
        await platform.invokeMethod('openNfcSettings');
      } catch (e) {
        await openAppSettings();
      }
    } else {
      await openAppSettings();
    }
  }

  static Future<bool> ensureNfcEnabled(BuildContext context) async {
    if (Platform.isAndroid) {
      final bluetoothStatus = await Permission.bluetooth.status;
      if (bluetoothStatus.isDenied || bluetoothStatus.isPermanentlyDenied) {
        final result = await Permission.bluetooth.request();
        if (!result.isGranted) {
          await _showEnableDialog(context);
          return false;
        }
      }
    }
    const platform = MethodChannel('nfc_utils');
    try {
      final enabled = await platform.invokeMethod<bool>('isNfcEnabled');
      if (enabled == null) {
        // Could not determine NFC state, assume enabled or device not supported
        return true;
      }
      if (enabled == false) {
        await _showEnableDialog(context);
        return false;
      }
    } catch (_) {}
    return true;
  }

  static Future<void> _showEnableDialog(BuildContext context) async {
    await showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Enable NFC'),
            content: const Text(
              'NFC is not enabled. Please enable it in system settings.',
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  await openNfcSettings();
                  Navigator.of(ctx).pop();
                },
                child: const Text('Open NFC Settings'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
            ],
          ),
    );
  }
}
