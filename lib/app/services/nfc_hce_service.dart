import 'dart:convert';
import 'package:flutter/services.dart';

class NfcHceService {
  static const _ch = MethodChannel('nfc_utils');

  static Future<void> setPayload(String text) async {
    final bytes = utf8.encode(text);
    await _ch.invokeMethod('hceSetPayload', {
      'bytes': Uint8List.fromList(bytes),
    });
  }

  static Future<void> clear() async {
    await _ch.invokeMethod('hceClear');
  }

  static Future<void> disableReader() async {
    await _ch.invokeMethod('hceDisableReader');
  }

  static Future<bool> hasPayload() async {
    final v = await _ch.invokeMethod<bool>('hceHasPayload');
    return v ?? false;
  }
}
