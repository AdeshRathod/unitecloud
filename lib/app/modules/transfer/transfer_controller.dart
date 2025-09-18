import 'dart:convert';
import 'dart:math';

import 'package:get/get.dart';
import '../../data/models/contact.dart';
import '../../services/nfc_service.dart';
import '../../services/transfer_service.dart';

/// Controller orchestrating NFC tap-to-share and optional Nearby transfer.
class TransferController extends GetxController {
  final NfcService nfcService;
  final TransferService transferService;

  TransferController({required this.nfcService, required this.transferService});

  final name = ''.obs;
  final phone = ''.obs;
  final email = ''.obs;

  final log = ''.obs; // aggregated log
  final contacts = <Contact>[].obs;
  final listening = false.obs;

  void _append(String msg) {
    final ts = DateTime.now().toIso8601String();
    log.value = '[${ts.split('T').last}] $msg\n' + log.value;
  }

  bool _validate() {
    if (name.value.trim().isEmpty) {
      _append('Name required.');
      return false;
    }
    if (phone.value.trim().isEmpty) {
      _append('Phone required.');
      return false;
    }
    if (email.value.trim().isEmpty) {
      _append('Email required.');
      return false;
    }
    return true;
  }

  Contact _buildContact() => Contact(
    name: name.value.trim(),
    phone: phone.value.trim(),
    email: email.value.trim(),
  );

  /// Share either via direct NFC (if payload small) or NFC token handshake + Nearby.
  Future<void> shareByTap() async {
    if (!_validate()) return;
    final contact = _buildContact();
    final jsonStr = jsonEncode(contact.toJson());
    final bytes = utf8.encode(jsonStr);
    _append('Prepared contact (${bytes.length} bytes).');
    if (bytes.length <= 1800) {
      _append('Using direct NFC write.');
      await nfcService.startWriting(jsonStr);
    } else {
      final token = _generateToken();
      _append('Payload large; using token handshake token=$token');
      // Start advertising with token & after NFC handshake we expect remote to connect.
      await transferService.advertise(
        'unitecloud-sender',
        token,
        payloadToSend: jsonStr,
      );
      await nfcService.startWriting(token);
      // We'll rely on remote side reading token & starting discovery.
    }
  }

  Future<void> listenForTap() async {
    if (listening.value) {
      _append('Already listening.');
      return;
    }
    listening.value = true;
    _append('Listening for NFC tap ...');
    await nfcService.startReading(
      onPayload: (data) async {
        _append(
          'NFC payload received: ${data.substring(0, data.length.clamp(0, 120))}${data.length > 120 ? '...' : ''}',
        );
        if (_looksLikeToken(data)) {
          _append('Detected token; starting discovery.');
          await transferService.discover(
            data,
            onPayload: (full) {
              _handleIncoming(full);
            },
          );
        } else {
          _handleIncoming(data);
        }
      },
    );
    listening.value = false;
  }

  void _handleIncoming(String jsonStr) {
    try {
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      final contact = Contact.fromJson(map);
      contacts.insert(0, contact);
      _append('Contact saved: ${contact.name}');
    } catch (e) {
      _append('Failed to parse incoming payload: $e');
    }
  }

  String _generateToken() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rnd = Random.secure();
    return List.generate(6, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  bool _looksLikeToken(String input) {
    return RegExp(r'^[A-Z0-9]{6}$').hasMatch(input.trim());
  }

  @override
  void onClose() {
    nfcService.dispose();
    transferService.dispose();
    super.onClose();
  }
}
