import 'dart:convert';
import 'dart:math';
import 'dart:async';

import 'package:get/get.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../data/models/contact.dart';
import '../../services/nfc_hce_service.dart';
import '../../services/nfc_utils.dart';
import '../../services/bluetooth_service.dart';

class TransferController extends GetxController with WidgetsBindingObserver {
  // Track if last cardFirst attempt failed, to force reader on next try
  bool _lastCardFirstFailed = false;
  // Guard to prevent overlapping share flows
  bool _shareInProgress = false;
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

  final TransferService transferService;
  TransferController({required this.transferService});

  final name = 'Adesh'.obs;
  final phone = '9307015431'.obs;
  final email = 'adesh@gmail.com'.obs;

  final log = ''.obs;
  final contacts = <Contact>[].obs;
  final nfcEnabled = true.obs;
  final hceActive = false.obs;
  // UI: NFC reading progress/state
  final isNfcReading = false.obs;
  final nfcReadStatus = ''.obs;
  // Manual override for NFC role selection: 'auto' | 'reader' | 'card'
  final nfcRoleOverride = 'auto'.obs;

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

  // HCE: emulate a card to allow phone-to-phone via NFC
  Future<void> startHceShare(BuildContext context) async {
    if (!_validate()) return;
    await checkNfcEnabled(context);
    if (!nfcEnabled.value) {
      _append('NFC is not enabled or not available.');
      return;
    }
    final jsonStr = contactJson;
    await NfcHceService.setPayload(jsonStr);
    hceActive.value = true;
    _append('HCE active. Bring the other phone close to read.');
  }

  Future<void> stopHceShare() async {
    await NfcHceService.clear();
    hceActive.value = false;
    // Also stop any UI indicators
    isNfcReading.value = false;
    nfcReadStatus.value = '';
    _append('HCE stopped.');
  }

  Future<void> readFromPhoneViaHce(BuildContext context) async {
    debugPrint('[NFC] readFromPhoneViaHce: called');
    await checkNfcEnabled(context);
    if (!nfcEnabled.value) {
      _append('NFC is not enabled or not available.');
      debugPrint('[NFC] readFromPhoneViaHce: NFC not enabled');
      return;
    }
    await _readFromPhoneViaHceInternal(context, cardFirstMode: false);
  }

  Future<void> _readFromPhoneViaHceInternal(
    BuildContext context, {
    bool cardFirstMode = false,
  }) async {
    final channel = const MethodChannel('nfc_utils');
    const attempts = 3;
    isNfcReading.value = true;
    nfcReadStatus.value = 'Align phones and hold still…';
    try {
      for (int i = 1; i <= attempts; i++) {
        try {
          debugPrint('[NFC] readFromPhoneViaHce: attempt $i');
          nfcReadStatus.value = 'Reading via NFC (attempt $i of $attempts)…';
          _append('HCE read attempt $i/$attempts ... Bring phones together.');
          final data = await channel.invokeMethod<String>('hceReadOnce', {
            'timeoutMs': 25000,
          });
          if (data == null || data.isEmpty) {
            _append('HCE read returned empty.');
            debugPrint('[NFC] readFromPhoneViaHce: attempt $i got empty');
            if (i == attempts) {
              nfcReadStatus.value = 'No NFC peer detected.';
              _toast(context, 'No NFC peer detected. Please retry.');
              if (cardFirstMode) {
                _lastCardFirstFailed = true;
                debugPrint(
                  '[NFC] readFromPhoneViaHce: cardFirstMode failed, will force reader next time',
                );
              }
            }
            continue;
          }
          _append('HCE read ${data.length} bytes.');
          nfcReadStatus.value = 'Received ${data.length} bytes';
          // Keep HCE armed so the peer can read our contact after we received theirs.
          // Native HCE will clear automatically after serving to the peer.
          debugPrint('[NFC] readFromPhoneViaHce: keeping HCE active for peer');
          debugPrint(
            '[NFC] readFromPhoneViaHce: attempt $i success, stopping reader',
          );
          await NfcHceService.disableReader();
          _handleIncoming(data);
          // Refresh HCE active banner based on serve-once native state
          try {
            final has = await NfcHceService.hasPayload();
            hceActive.value = has;
            if (!has) _append('NFC payload served; HCE now idle.');
          } catch (_) {}
          // Optional: if we were reader-first and override is auto, try a quick reciprocal read
          // so both sides exchange on a single action when close together.
          try {
            final overrideNow = nfcRoleOverride.value;
            if (overrideNow == 'auto') {
              await Future.delayed(const Duration(milliseconds: 250));
              debugPrint('[NFC] reciprocal read kick-off (auto)');
              await _readFromPhoneViaHceInternal(context, cardFirstMode: false);
            }
          } catch (_) {}
          return;
        } catch (e) {
          _append('HCE read error on attempt $i: $e');
          debugPrint('[NFC] readFromPhoneViaHce: attempt $i error: $e');
          if (i == attempts) {
            nfcReadStatus.value = 'NFC read failed.';
            _toast(context, 'NFC read failed: $e');
            debugPrint(
              '[NFC] readFromPhoneViaHce: all attempts failed, stopping reader',
            );
            await NfcHceService.disableReader();
            if (cardFirstMode) {
              _lastCardFirstFailed = true;
              debugPrint(
                '[NFC] readFromPhoneViaHce: cardFirstMode failed, will force reader next time',
              );
            }
          } else {
            nfcReadStatus.value = 'Retrying…';
            // Backoff based on error type to avoid thrash
            final msg = e.toString();
            int delayMs = 300;
            if (msg.contains('BUSY') || msg.contains('CANCELLED')) {
              delayMs = 350 + Random().nextInt(200); // 350–550ms
            } else if (msg.contains('READ') || msg.contains('Tag was lost')) {
              delayMs = 250 + Random().nextInt(200); // 250–450ms
            }
            await Future.delayed(Duration(milliseconds: delayMs));
          }
        }
      }
    } finally {
      isNfcReading.value = false;
      debugPrint(
        '[NFC] readFromPhoneViaHce: finally block, isNfcReading set to false',
      );
    }
  }

  // Retry only the reader while keeping HCE active
  Future<void> retryNfcRead(BuildContext context) async {
    debugPrint('[NFC] retryNfcRead: called');
    if (isNfcReading.value) return; // already in progress
    await checkNfcEnabled(context);
    if (!nfcEnabled.value) {
      _append('NFC is not enabled or not available.');
      debugPrint('[NFC] retryNfcRead: NFC not enabled');
      return;
    }
    // Ensure HCE is still armed if user stopped it inadvertently
    if (!hceActive.value && _validate()) {
      await NfcHceService.setPayload(contactJson);
      hceActive.value = true;
      _append('Re-armed NFC HCE for retry.');
      debugPrint('[NFC] retryNfcRead: re-armed HCE');
    }
    // Small jitter to reduce collisions if both tap Try again simultaneously
    final jitterMs = 200 + Random().nextInt(600);
    await Future.delayed(Duration(milliseconds: jitterMs));
    debugPrint('[NFC] retryNfcRead: starting read after jitter');
    await readFromPhoneViaHce(context);
  }

  // Unified phone-to-phone NFC share (both devices do this):
  // 1) Validate and set HCE payload (emulate card with my contact)
  // 2) Start reader once to pull peer's payload
  Future<void> shareByNfcPhoneToPhone(BuildContext context) async {
    debugPrint('[NFC] shareByNfcPhoneToPhone: called');
    if (_shareInProgress) {
      debugPrint('[NFC] shareByNfcPhoneToPhone: ignored (in-progress)');
      return;
    }
    _shareInProgress = true;
    // Always stop any previous reader before starting a new share
    await NfcHceService.disableReader();
    // Allow native to settle
    await Future.delayed(const Duration(milliseconds: 120));
    if (!_validate()) return;
    await checkNfcEnabled(context);
    if (!nfcEnabled.value) {
      _append('NFC is not enabled or not available.');
      debugPrint('[NFC] shareByNfcPhoneToPhone: NFC not enabled');
      return;
    }
    try {
      await NfcHceService.setPayload(contactJson);
      hceActive.value = true;
      _append('NFC HCE ready. Bring the other phone close to exchange.');
      debugPrint(
        '[NFC] shareByNfcPhoneToPhone: HCE payload set, hceActive true',
      );
      // No fixed auto-clear: the native HCE clears the payload after serving the
      // final chunk (serve-once). User can stop manually if desired.
      // Deterministic role selection to avoid both reading at once:
      // Derive parity from ANDROID_ID hash: even -> reader-first, odd -> card-first.
      final channel = const MethodChannel('nfc_utils');
      String deviceId = '';
      try {
        deviceId = await channel.invokeMethod<String>('getAndroidId') ?? '';
      } catch (_) {}
      final hash = deviceId.hashCode;
      // Fallback: if last attempt in card-first mode failed, force reader this time
      // but only if our deterministic hash says we'd otherwise be card (odd).
      bool forceReader = false;
      if (_lastCardFirstFailed) {
        if ((hash & 1) == 1) {
          forceReader = true; // flip to reader only for odd hash
        }
        _lastCardFirstFailed = false;
      }

      // Apply manual override if set by the user
      final override = nfcRoleOverride.value;
      bool? overrideReaderFirst;
      if (override == 'reader') overrideReaderFirst = true;
      if (override == 'card') overrideReaderFirst = false;

      final readerFirst =
          overrideReaderFirst ?? (forceReader || ((hash & 1) == 0));
      debugPrint(
        '[NFC] role: deviceId=$deviceId hash=$hash override=$override forceReader=$forceReader readerFirst=$readerFirst',
      );
      if (readerFirst) {
        // Small jitter then try reading immediately. If user explicitly chose 'reader',
        // wait a little longer to allow the other phone to arm HCE first.
        final readerDelayMs =
            (override == 'reader')
                ? 1000 +
                    Random().nextInt(500) // 1000–1500ms
                : 200 + Random().nextInt(400); // 200–600ms
        await Future.delayed(Duration(milliseconds: readerDelayMs));
        debugPrint('[NFC] shareByNfcPhoneToPhone: readerFirst, starting read');
        await _readFromPhoneViaHceInternal(context, cardFirstMode: false);
      } else {
        // Prefer to serve first: give peer ample time to read, then try reading
        // Increased delay to reduce collisions if both default to card-first.
        // But if explicitly overridden to 'card', use a short delay since the peer should be 'reader'.
        final delayMs =
            (override == 'card')
                ? 4000 +
                    Random().nextInt(1500) // 4000–5500ms
                : 2000 + Random().nextInt(500); // 2000–2500ms
        await Future.delayed(Duration(milliseconds: delayMs));
        debugPrint(
          '[NFC] shareByNfcPhoneToPhone: cardFirst, starting read after delay',
        );
        await _readFromPhoneViaHceInternal(context, cardFirstMode: true);
      }
    } catch (e) {
      _append('Failed to start NFC HCE: $e');
      _toast(context, 'Failed to start NFC: $e');
      debugPrint('[NFC] shareByNfcPhoneToPhone: error $e');
    } finally {
      _shareInProgress = false;
    }
  }

  void _toast(BuildContext context, String msg) {
    try {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (_) {
      // ignore UI errors
    }
  }

  void _handleIncoming(String jsonStr) async {
    try {
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      final contact = Contact.fromJson(map);
      await presentContactPreview(contact);
    } catch (e) {
      _append('Failed to parse incoming payload: $e');
    }
  }

  Future<void> presentContactPreview(Contact contact) async {
    final context = Get.context;
    if (context == null) {
      // Fallback: direct save if no context
      contacts.insert(0, contact);
      _append('Contact saved: ${contact.name}');
      return;
    }
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) {
        final name = contact.name.trim();
        final initials =
            name.isNotEmpty
                ? name
                    .split(RegExp(r'\s+'))
                    .where((p) => p.isNotEmpty)
                    .map((p) => p[0])
                    .take(2)
                    .join()
                    .toUpperCase()
                : 'UC';
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 16,
              top: 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 28,
                      backgroundColor: Theme.of(
                        sheetCtx,
                      ).colorScheme.primary.withOpacity(0.15),
                      child: Text(
                        initials,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Theme.of(sheetCtx).colorScheme.primary,
                          fontSize: 20,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            contact.name,
                            style: Theme.of(sheetCtx).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'New contact',
                            style: Theme.of(sheetCtx).textTheme.bodySmall
                                ?.copyWith(color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Card(
                  elevation: 0,
                  color: Theme.of(
                    sheetCtx,
                  ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.phone, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                contact.phone,
                                style: Theme.of(sheetCtx).textTheme.bodyMedium,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Icon(Icons.email_outlined, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                contact.email,
                                style: Theme.of(sheetCtx).textTheme.bodyMedium,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(sheetCtx).pop(),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.save_rounded),
                        onPressed: () {
                          contacts.insert(0, contact);
                          _append('Contact saved: ${contact.name}');
                          Navigator.of(sheetCtx).pop();
                        },
                        label: const Text('Save contact'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _generateToken() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rnd = Random.secure();
    return List.generate(6, (_) => chars[rnd.nextInt(chars.length)]).join();
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
