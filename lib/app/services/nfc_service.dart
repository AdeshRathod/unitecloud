import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:nfc_manager/nfc_manager.dart';

/// A wrapper around `nfc_manager` & `ndef` packages to simplify
/// starting NFC write & read sessions. Supports only NDEF text records
/// for simplicity.
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
    _log('Starting write session ...');

    await NfcManager.instance.startSession(
      onDiscovered: (NfcTag tag) async {
        try {
          final ndefTag = Ndef.from(tag);
          if (ndefTag == null) {
            _log('Tag is not NDEF formatted.');
            await stopSession(errorMessage: 'Non NDEF tag');
            return;
          }
          if (!ndefTag.isWritable) {
            _log('Tag not writable.');
            await stopSession(errorMessage: 'Read-only tag');
            return;
          }

          final message = _buildTextMessage(payload);
          final estimatedSize = _estimateMessageSize(message);
          if (estimatedSize > 2000) {
            _log(
              'Payload too large for typical NFC tag ($estimatedSize bytes)',
            );
            await stopSession(errorMessage: 'Payload too large');
            return;
          }
          await ndefTag.write(message);
          _log('Write success (~$estimatedSize bytes).');
          await stopSession();
        } catch (e) {
          _log('Write failed: $e');
          await stopSession(errorMessage: e.toString());
        }
      },
      invalidateAfterFirstRead: true,
    );
  }

  /// Start a reading session. Cancels after first tag is read.
  Future<void> startReading({void Function(String data)? onPayload}) async {
    if (_sessionActive) {
      _log('Session already active.');
      return;
    }
    _sessionActive = true;
    _log('Starting read session ...');

    await NfcManager.instance.startSession(
      onDiscovered: (NfcTag tag) async {
        try {
          final ndefTag = Ndef.from(tag);
          if (ndefTag == null) {
            _log('Not an NDEF tag.');
            await stopSession(errorMessage: 'Non NDEF');
            return;
          }
          final message = await ndefTag.read();
          final records = message.records;
          if (records.isEmpty) {
            _log('No records found.');
            await stopSession(errorMessage: 'Empty tag');
            return;
          }
          final first = records.first;
          final text = _tryDecodeText(first);
          if (text != null) {
            _log('Read text record (${utf8.encode(text).length} bytes).');
            onPayload?.call(text);
          } else {
            _log(
              'Unsupported record (tnf=${first.typeNameFormat}, type=${utf8.decode(first.type)})',
            );
          }
          await stopSession();
        } catch (e) {
          _log('Read failed: $e');
          await stopSession(errorMessage: e.toString());
        }
      },
      invalidateAfterFirstRead: true,
    );
  }

  Future<void> stopSession({String? errorMessage}) async {
    if (!_sessionActive) return;
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
    }
  }

  void dispose() {
    _logController.close();
  }
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
  if (record.type.isEmpty || record.type.first != 0x54) return null; // not 'T'
  final payload = record.payload;
  if (payload.isEmpty) return '';
  final status = payload.first;
  final langLength = status & 0x1F;
  if (payload.length < 1 + langLength) return null;
  final textBytes = payload.sublist(1 + langLength);
  return utf8.decode(textBytes);
}
