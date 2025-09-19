import 'dart:convert';
import 'dart:typed_data';
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
}
