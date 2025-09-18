import 'dart:convert';
import 'dart:math';
import 'dart:async';

import 'package:get/get.dart';
import 'package:flutter/material.dart';
import '../../data/models/contact.dart';
import '../../services/nfc_service.dart';
import '../../services/nfc_utils.dart';
import '../../services/bluetooth_service.dart';

class TransferController extends GetxController with WidgetsBindingObserver {
  String get contactJson => jsonEncode(_buildContact().toJson());
  Future<void> shareByNearby(BuildContext context) async {
    // Kept for backward compatibility: open Nearby sheet from the view.
    // No-op here or could be used to trigger default flow.
    if (!_validate()) return;
    // Default behavior: start open auto nearby (advertise+discover).
    await startNearbyAuto();
  }

  final hasNfc = true.obs;
  final nameController = TextEditingController();
  final phoneController = TextEditingController();
  final emailController = TextEditingController();

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
    nameController.text = name.value;
    phoneController.text = phone.value;
    emailController.text = email.value;
    nameController.addListener(() {
      if (name.value != nameController.text) {
        name.value = nameController.text;
      }
    });
    phoneController.addListener(() {
      if (phone.value != phoneController.text) {
        phone.value = phoneController.text;
      }
    });
    emailController.addListener(() {
      if (email.value != emailController.text) {
        email.value = emailController.text;
      }
    });

    // Subscribe to service logs
    _nearbyLogSub = transferService.logs.listen((msg) {
      _append('Nearby: $msg');
    });
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    nameController.dispose();
    phoneController.dispose();
    emailController.dispose();
    nfcService.dispose();
    stopNearby();
    _nearbyLogSub?.cancel();
    transferService.dispose();
    super.onClose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final context = Get.context;
      if (context != null) {
        checkNfcEnabled(context);
      }
    }
  }

  final NfcService nfcService;
  final TransferService transferService;

  TransferController({required this.nfcService, required this.transferService});

  final name = 'Adesh'.obs;
  final phone = '9307015431'.obs;
  final email = 'adesh@gmail.com'.obs;

  final log = ''.obs;
  final contacts = <Contact>[].obs;
  final listening = false.obs;
  final nfcEnabled = true.obs;

  // Nearby state
  final nearbyActive = false.obs;
  final nearbyMode = ''.obs; // 'auto' | 'sender' | 'receiver'
  final advertisingToken = RxnString();
  StreamSubscription<String>? _nearbyLogSub;

  Future<void> checkNfcEnabledSilent() async {
    final enabled = await NfcUtils.isNfcEnabled();
    if (nfcEnabled.value != enabled) {
      nfcEnabled.value = enabled;
      _append(enabled ? 'NFC is now active.' : 'NFC is now disabled.');
    }
  }

  Future<void> checkNfcEnabled(BuildContext context) async {
    final enabled = await NfcUtils.ensureNfcEnabled(context);
    if (nfcEnabled.value != enabled) {
      nfcEnabled.value = enabled;
      _append(enabled ? 'NFC is now active.' : 'NFC is now disabled.');
    }
  }

  @override
  void onReady() {
    super.onReady();
    checkNfcHardwareAndNfcEnabled();
  }

  Future<void> checkNfcHardwareAndNfcEnabled() async {
    final has = await NfcUtils.hasNfcHardware();
    hasNfc.value = has;
    if (has) {
      await checkNfcEnabledSilent();
    } else {
      nfcEnabled.value = false;
      _append('NFC device not detected on your device. Use share option.');
    }
  }

  void _append(String msg) {
    final ts = DateTime.now().toIso8601String();
    log.value = '[${ts.split('T').last}] $msg\n${log.value}';
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

  Future<void> shareByTap(BuildContext context) async {
    if (!_validate()) return;
    await checkNfcEnabled(context);
    if (!nfcEnabled.value) {
      _append('NFC is not enabled or not available.');
      return;
    }
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
      await transferService.advertise(
        'unitecloud-sender',
        token,
        payloadToSend: jsonStr,
      );
      await nfcService.startWriting(token);
    }
  }

  Future<void> listenForTap(BuildContext context) async {
    if (listening.value) {
      _append('Already listening.');
      return;
    }
    await checkNfcEnabled(context);
    if (!nfcEnabled.value) {
      _append('NFC is not enabled or not available.');
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

  Contact? parseScannedPayload(String data) {
    final raw = data.trim();
    if (raw.isEmpty) {
      _append('QR scan returned empty data');
      return null;
    }
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return Contact.fromJson(map);
    } catch (_) {
      if (raw.startsWith('BEGIN:VCARD')) {
        String extract(String key) {
          final re = RegExp('^$key:([^\n\r]+)', multiLine: true);
          final m = re.firstMatch(raw);
          return m != null ? m.group(1)!.trim() : '';
        }

        final name = extract('FN');
        final phone = extract('TEL');
        final email = extract('EMAIL');
        if (name.isEmpty && phone.isEmpty && email.isEmpty) {
          _append('Parsed vCard but it was empty');
          return null;
        }
        return Contact(name: name, phone: phone, email: email);
      }
    }
    _append('Unsupported QR payload format');
    return null;
  }

  void saveContact(Contact contact) {
    contacts.insert(0, contact);
    _append('Contact saved: ${contact.name}');
  }

  // Nearby: Auto mode (bidirectional)
  Future<void> startNearbyAuto() async {
    if (!_validate()) return;
    if (nearbyActive.value) {
      _append('Nearby already running.');
      return;
    }
    final jsonStr = contactJson;
    nearbyMode.value = 'auto';
    nearbyActive.value = true;
    // Start both advertiseOpen and discoverOpen; service stops itself when connected.
    _append('Starting Auto Nearby (advertise + discover) ...');
    await transferService.advertiseOpen(
      'unitecloud-auto',
      payloadToSend: jsonStr,
      onPayload: (full) => _handleIncoming(full),
    );
    await transferService.discoverOpen(
      payloadToSend: jsonStr,
      onPayload: (full) => _handleIncoming(full),
    );
  }

  Future<String?> startNearbyCodeSender() async {
    if (!_validate()) return null;
    if (nearbyActive.value) {
      _append('Nearby already running.');
      return advertisingToken.value;
    }
    final token = _generateToken();
    final jsonStr = contactJson;
    nearbyMode.value = 'sender';
    nearbyActive.value = true;
    advertisingToken.value = token;
    _append('Starting Nearby as sender with code $token');
    await transferService.advertise(
      'unitecloud-sender',
      token,
      payloadToSend: jsonStr,
      onPayload: (full) => _handleIncoming(full),
    );
    return token;
  }

  Future<void> startNearbyCodeReceiver(
    String token, {
    bool sendBack = true,
  }) async {
    if (token.trim().isEmpty) {
      _append('Enter a valid code.');
      return;
    }
    if (nearbyActive.value) {
      _append('Nearby already running.');
      return;
    }
    final jsonStr = sendBack && _validate() ? contactJson : null;
    nearbyMode.value = 'receiver';
    nearbyActive.value = true;
    advertisingToken.value = token;
    _append(
      'Starting Nearby as receiver for code $token ${sendBack ? '(will send my contact back)' : ''}',
    );
    await transferService.discover(
      token,
      payloadToSend: jsonStr,
      onPayload: (full) => _handleIncoming(full),
    );
  }

  Future<void> stopNearby() async {
    if (!nearbyActive.value) return;
    await transferService.stopAll();
    nearbyActive.value = false;
    advertisingToken.value = null;
    nearbyMode.value = '';
    _append('Nearby stopped.');
  }
}
