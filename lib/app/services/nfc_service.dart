import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:nfc_manager/nfc_manager.dart';

class NfcService {
  final _logController = StreamController<String>.broadcast();
  Stream<String> get logs => _logController.stream;

  void _log(String msg) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('[NFC] $msg');
    }
    _logController.add(msg);
  }

  bool _sessionActive = false;
  int _sessionCounter = 0; // increments to correlate logs per session
  Timer? _watchdog;

  Future<bool> isAvailable() async {
    final available = await NfcManager.instance.isAvailable();
    _log('NFC available: $available');
    return available;
  }

  /// Start a writing session. The user must tap a tag.
  Future<void> startWriting(String payload) async {
    if (_sessionActive) {
      _log('Session already active.');
      return;
    }
    _sessionActive = true;
    final sid = ++_sessionCounter;
    final payloadLen = utf8.encode(payload).length;
    _log('[$sid] Starting write session ... (payloadLen=$payloadLen bytes)');
    _log('[$sid] Waiting for tag ... Tap and hold an NFC tag near the phone');
    _startWatchdog(sid);

    await NfcManager.instance.startSession(
      onDiscovered: (NfcTag tag) async {
        try {
          _disarmWatchdog();
          _safeLogTagInfo(tag, sid: sid);
          final ndefTag = Ndef.from(tag);
          if (ndefTag == null) {
            _log('[$sid] Tag is not NDEF formatted.');
            await stopSession(errorMessage: 'Non NDEF tag');
            return;
          }
          _log(_describeNdef(ndefTag, sid: sid));
          if (!ndefTag.isWritable) {
            _log('[$sid] Tag not writable.');
            await stopSession(errorMessage: 'Read-only tag');
            return;
          }

          final message = _buildTextMessage(payload);
          final estimatedSize = _estimateMessageSize(message);
          if (estimatedSize > 2000) {
            _log(
              '[$sid] Payload too large for typical NFC tag (~$estimatedSize bytes)',
            );
            await stopSession(errorMessage: 'Payload too large');
            return;
          }
          _log('[$sid] Writing NDEF message (~$estimatedSize bytes) ...');
          await ndefTag.write(message);
          _log('[$sid] Write success (~$estimatedSize bytes).');
          await stopSession();
        } catch (e, st) {
          _log('[$sid] Write failed: $e');
          if (kDebugMode) {
            // ignore: avoid_print
            print('[NFC][$sid] stack: $st');
          }
          await stopSession(errorMessage: e.toString());
        }
      },
      invalidateAfterFirstRead: true,
    );
  }

  Future<void> startReading({void Function(String data)? onPayload}) async {
    if (_sessionActive) {
      _log('Session already active.');
      return;
    }
    _sessionActive = true;
    final sid = ++_sessionCounter;
    _log('[$sid] Starting read session ...');
    _log('[$sid] Waiting for tag ... Tap and hold an NFC tag near the phone');
    _startWatchdog(sid);

    await NfcManager.instance.startSession(
      onDiscovered: (NfcTag tag) async {
        try {
          _disarmWatchdog();
          _safeLogTagInfo(tag, sid: sid);
          final ndefTag = Ndef.from(tag);
          if (ndefTag == null) {
            _log('[$sid] Not an NDEF tag.');
            await stopSession(errorMessage: 'Non NDEF');
            return;
          }
          _log(_describeNdef(ndefTag, sid: sid));
          final message = await ndefTag.read();
          final records = message.records;
          _log('[$sid] Read NDEF message with ${records.length} record(s).');
          for (var i = 0; i < records.length; i++) {
            final r = records[i];
            final typeStr = _safeAscii(r.type);
            _log(
              '[$sid]  • rec#$i tnf=${r.typeNameFormat} type=${typeStr} payloadLen=${r.payload.length}',
            );
          }
          if (records.isEmpty) {
            _log('[$sid] No records found.');
            await stopSession(errorMessage: 'Empty tag');
            return;
          }
          final first = records.first;
          final text = _tryDecodeText(first);
          if (text != null) {
            _log(
              '[$sid] Read text record (${utf8.encode(text).length} bytes).',
            );
            if (kDebugMode) {
              final preview =
                  text.length > 120 ? '${text.substring(0, 120)}...' : text;
              _log('[$sid] Text preview: ${preview.replaceAll('\n', ' ')}');
            }
            onPayload?.call(text);
          } else {
            final typeStr = _safeAscii(first.type);
            _log(
              '[$sid] Unsupported record (tnf=${first.typeNameFormat}, type=$typeStr)',
            );
          }
          await stopSession();
        } catch (e, st) {
          _log('[$sid] Read failed: $e');
          if (kDebugMode) {
            // ignore: avoid_print
            print('[NFC][$sid] stack: $st');
          }
          await stopSession(errorMessage: e.toString());
        }
      },
      invalidateAfterFirstRead: true,
    );
  }

  Future<void> stopSession({String? errorMessage}) async {
    if (!_sessionActive) {
      _log('stopSession called but no active session.');
      return;
    }
    try {
      if (errorMessage != null) {
        _log('Stopping session with error: $errorMessage');
        await NfcManager.instance.stopSession(errorMessage: errorMessage);
      } else {
        _log('Stopping session normally.');
        await NfcManager.instance.stopSession();
      }
    } catch (e) {
      _log('stopSession error: $e');
    } finally {
      _sessionActive = false;
      _disarmWatchdog();
    }
  }

  void dispose() {
    _logController.close();
  }

  // Helpers
  void _safeLogTagInfo(NfcTag tag, {required int sid}) {
    try {
      final data = tag.data; // NfcTag.data is a Map<String, dynamic>
      _log('[$sid] Tag techs: ${data.keys.toList()}');
      final id = _extractTagId(data);
      if (id != null) {
        _log('[$sid] Tag id: ${_hex(id)}');
      }
    } catch (e) {
      _log('[$sid] Failed to inspect tag: $e');
    }
  }

  String _describeNdef(Ndef ndef, {required int sid}) {
    // Some fields may not be available on all platforms; guard with try/catch
    try {
      return '[$sid] NDEF: isWritable=${ndef.isWritable}, maxSize=${ndef.maxSize}';
    } catch (_) {
      return '[$sid] NDEF detected (descriptor unavailable)';
    }
  }

  Uint8List? _extractTagId(Map data) {
    // Common tech keys: 'nfca', 'mifareclassic', 'mifareultralight', 'ndef', etc.
    // Try a few typical places for the tag id.
    final candidates = ['nfca', 'iso7816', 'iso15693', 'felica'];
    for (final k in candidates) {
      final v = data[k];
      if (v is Map && v['identifier'] is Uint8List) {
        return v['identifier'] as Uint8List;
      }
      if (v is Map && v['id'] is Uint8List) {
        return v['id'] as Uint8List;
      }
    }
    // Some drivers place id at the top level
    if (data['id'] is Uint8List) return data['id'] as Uint8List;
    if (data['identifier'] is Uint8List) return data['identifier'] as Uint8List;
    return null;
  }

  String _hex(Uint8List bytes, {int max = 16}) {
    final b = bytes.length > max ? bytes.sublist(0, max) : bytes;
    final s = b.map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ');
    return bytes.length > max ? '$s …(${bytes.length} bytes)' : s;
  }

  String _safeAscii(Uint8List bytes) {
    try {
      final s = utf8.decode(bytes, allowMalformed: true);
      // Keep printable ASCII subset; otherwise fall back to hex
      final t = s.trim();
      final printable =
          t.isNotEmpty && t.runes.every((r) => r >= 0x20 && r <= 0x7E);
      if (printable) return t;
    } catch (_) {
      // ignore
    }
    return '0x' + bytes.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Build a simple text NDEF message using well-known Text RTD (type 'T').
  NdefMessage _buildTextMessage(String text) {
    final lang = 'en';
    final langBytes = utf8.encode(lang);
    final textBytes = utf8.encode(text);
    final status = langBytes.length & 0x1F; // UTF-8 encoding, no UTF-16 flag.
    final payload = Uint8List(status + 1 + langBytes.length + textBytes.length);
    int i = 0;
    payload[i++] = status;
    for (final b in langBytes) {
      payload[i++] = b;
    }
    for (final b in textBytes) {
      payload[i++] = b;
    }

    final record = NdefRecord(
      typeNameFormat: NdefTypeNameFormat.nfcWellknown,
      type: Uint8List.fromList([0x54]), // 'T'
      identifier: Uint8List(0),
      payload: payload,
    );
    return NdefMessage([record]);
  }

  /// Estimate message size (rough heuristic based on record payloads + header bytes per record).
  int _estimateMessageSize(NdefMessage message) {
    int size = 0;
    for (final r in message.records) {
      size +=
          r.payload.length +
          r.type.length +
          r.identifier.length +
          7; // header approx
    }
    return size;
  }

  /// Attempt to decode a well-known text record.
  String? _tryDecodeText(NdefRecord record) {
    if (record.typeNameFormat != NdefTypeNameFormat.nfcWellknown) return null;
    if (record.type.isEmpty || record.type.first != 0x54)
      return null; // not 'T'
    final payload = record.payload;
    if (payload.isEmpty) return '';
    final status = payload.first;
    final langLength = status & 0x1F;
    if (payload.length < 1 + langLength) return null;
    final textBytes = payload.sublist(1 + langLength);
    return utf8.decode(textBytes);
  }

  void _startWatchdog(
    int sid, {
    Duration timeout = const Duration(seconds: 20),
  }) {
    try {
      _watchdog?.cancel();
      _watchdog = Timer(timeout, () async {
        _log(
          '[$sid] No NFC tag detected in ${timeout.inSeconds}s. Timing out. Note: phone-to-phone NFC is not supported on modern Android; use Nearby for device-to-device.',
        );
        await stopSession(errorMessage: 'Timeout waiting for NFC tag');
      });
    } catch (e) {
      _log('[$sid] Failed to start watchdog: $e');
    }
  }

  void _disarmWatchdog() {
    try {
      _watchdog?.cancel();
      _watchdog = null;
    } catch (_) {}
  }
}
