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
  bool _lastCardFirstFailed = false;
  bool _shareInProgress = false;
  String get contactJson => jsonEncode(_buildContact().toJson());
  Future<void> shareByNearby() async {
    if (!_validate()) return;
    await startNearbyAuto();
  }

  final hasNfc = true.obs;
  final nameController = TextEditingController();
  final phoneController = TextEditingController();
  final emailController = TextEditingController();
  final nameError = RxnString();
  final phoneError = RxnString();
  final emailError = RxnString();

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
        nameError.value = _validateName(name.value);
      }
    });
    phoneController.addListener(() {
      if (phone.value != phoneController.text) {
        phone.value = phoneController.text;
        phoneError.value = _validatePhone(phone.value);
      }
    });
    emailController.addListener(() {
      if (email.value != emailController.text) {
        email.value = emailController.text;
        emailError.value = _validateEmail(email.value);
      }
    });

    _nearbyLogSub = transferService.logs.listen(_appendNearbyFriendly);
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
      checkNfcEnabled();
    }
  }

  final TransferService transferService;
  TransferController({required this.transferService});

  final name = ''.obs;
  final phone = ''.obs;
  final email = ''.obs;

  final log = ''.obs;
  final contacts = <Contact>[].obs;
  final nfcEnabled = true.obs;
  final hceActive = false.obs;
  final isNfcReading = false.obs;
  final nfcReadStatus = ''.obs;
  final nfcRoleOverride = 'auto'.obs;

  final nearbyActive = false.obs;
  final nearbyMode = ''.obs;
  final advertisingToken = RxnString();
  StreamSubscription<String>? _nearbyLogSub;

  Future<void> checkNfcEnabledSilent() async {
    final enabled = await NfcUtils.isNfcEnabled();
    if (nfcEnabled.value != enabled) {
      nfcEnabled.value = enabled;
      _append(enabled ? 'NFC is now active.' : 'NFC is now disabled.');
    }
  }

  Future<void> checkNfcEnabled() async {
    final enabled = await NfcUtils.ensureNfcEnabled();
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
      _append('This device doesn’t support NFC. Use Nearby or QR.');
    }
  }

  void _append(String msg) {
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    final ss = now.second.toString().padLeft(2, '0');
    log.value = '[$hh:$mm:$ss] $msg\n${log.value}';
  }

  void _appendNearbyFriendly(String raw) {
    final lc = raw.toLowerCase();
    // Success events
    if (lc.contains('payload received')) {
      _append('Contact received.');
      return;
    }
    if (lc.contains('auto-send complete') || lc.startsWith('sent payload')) {
      _append('Contact sent.');
      return;
    }
    if (lc.contains('connection result') && lc.contains('connected')) {
      _append('Nearby connected.');
      return;
    }
    // Stop/cleanup
    if (lc.startsWith('stopped advertising') ||
        lc.startsWith('stopped discovering')) {
      _append('Nearby stopped.');
      return;
    }
    // Errors
    if (lc.contains('failed') ||
        lc.contains('cannot') ||
        lc.contains('missing permission')) {
      _append('Nearby failed.');
      return;
    }
    // Ignore verbose/internal messages (advertising/discovery started, endpoints, retries, etc.)
  }

  bool _validate() {
    nameError.value = _validateName(name.value);
    phoneError.value = _validatePhone(phone.value);
    emailError.value = _validateEmail(email.value);
    final ok =
        nameError.value == null &&
        phoneError.value == null &&
        emailError.value == null;
    if (!ok) {
      _append('Fix the highlighted fields and try again.');
    }
    return ok;
  }

  String? _validateName(String v) {
    final t = v.trim();
    if (t.isEmpty) return 'Name is required';
    if (t.length < 2) return 'Enter at least 2 characters';
    return null;
  }

  String? _validatePhone(String v) {
    final t = v.trim();
    if (t.isEmpty) return 'Phone is required';
    final digits = t.replaceAll(RegExp(r'[^0-9+]'), '');
    if (digits.length < 7) return 'Enter a valid phone number';
    return null;
  }

  String? _validateEmail(String v) {
    final t = v.trim();
    if (t.isEmpty) return 'Email is required';
    final re = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
    if (!re.hasMatch(t)) return 'Enter a valid email address';
    return null;
  }

  Contact _buildContact() => Contact(
    name: name.value.trim(),
    phone: phone.value.trim(),
    email: email.value.trim(),
  );

  Future<void> startHceShare() async {
    if (!_validate()) return;
    await checkNfcEnabled();
    if (!nfcEnabled.value) {
      _append('NFC is not enabled or not available.');
      return;
    }
    final jsonStr = contactJson;
    await NfcHceService.setPayload(jsonStr);
    hceActive.value = true;
    _append('NFC ready—hold phones together.');
  }

  Future<void> stopHceShare() async {
    try {
      await NfcHceService.disableReader();
    } catch (_) {}
    await NfcHceService.clear();
    hceActive.value = false;
    isNfcReading.value = false;
    nfcReadStatus.value = '';
    _append('NFC stopped.');
  }

  Future<void> cancelNfcRead() async {
    try {
      await NfcHceService.disableReader();
    } catch (_) {}
    isNfcReading.value = false;
    nfcReadStatus.value = 'Canceled by you';
    _append('NFC read canceled.');
  }

  Future<void> readFromPhoneViaHce() async {
    debugPrint('[NFC] readFromPhoneViaHce: called');
    await checkNfcEnabled();
    if (!nfcEnabled.value) {
      _append('NFC is not enabled or not available.');
      debugPrint('[NFC] readFromPhoneViaHce: NFC not enabled');
      return;
    }
    await _readFromPhoneViaHceInternal(
      cardFirstMode: false,
      timeoutMs: 12000,
      attempts: 2,
    );
  }

  Future<void> _readFromPhoneViaHceInternal({
    bool cardFirstMode = false,
    int? timeoutMs,
    int? attempts,
  }) async {
    final channel = const MethodChannel('nfc_utils');
    final int tries = attempts ?? 3;
    final int toMs = timeoutMs ?? 25000;
    isNfcReading.value = true;
    nfcReadStatus.value = 'Align phones and hold still…';
    _append('Trying to read via NFC… Hold phones together.');
    try {
      for (int i = 1; i <= tries; i++) {
        try {
          debugPrint('[NFC] readFromPhoneViaHce: attempt $i');
          nfcReadStatus.value = 'Reading via NFC…';
          final data = await channel.invokeMethod<String>('hceReadOnce', {
            'timeoutMs': toMs,
          });
          if (data == null || data.isEmpty) {
            debugPrint('[NFC] readFromPhoneViaHce: attempt $i got empty');
            if (i == tries) {
              nfcReadStatus.value = 'No device detected.';
              _append('No device detected. Try again.');
              _toast('No NFC device detected. Please try again.');
              if (cardFirstMode) {
                _lastCardFirstFailed = true;
                debugPrint(
                  '[NFC] readFromPhoneViaHce: cardFirstMode failed, will force reader next time',
                );
              }
            }
            continue;
          }
          _append('Contact received.');
          nfcReadStatus.value = 'Contact received';
          debugPrint('[NFC] readFromPhoneViaHce: keeping HCE active for peer');
          debugPrint(
            '[NFC] readFromPhoneViaHce: attempt $i success, stopping reader',
          );
          await NfcHceService.disableReader();
          _handleIncoming(data);
          try {
            final has = await NfcHceService.hasPayload();
            hceActive.value = has;
          } catch (_) {}
          return;
        } catch (e) {
          debugPrint('[NFC] readFromPhoneViaHce: attempt $i error: $e');
          if (i == tries) {
            nfcReadStatus.value = 'NFC read failed.';
            _append('NFC read failed. Try again.');
            _toast('NFC read failed. Please try again.');
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
            final msg = e.toString();
            int delayMs = 300;
            if (msg.contains('BUSY') || msg.contains('CANCELLED')) {
              delayMs = 350 + Random().nextInt(200);
            } else if (msg.contains('READ') || msg.contains('Tag was lost')) {
              delayMs = 250 + Random().nextInt(200);
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

  Future<void> retryNfcRead() async {
    debugPrint('[NFC] retryNfcRead: called');
    if (isNfcReading.value) return;
    await checkNfcEnabled();
    if (!nfcEnabled.value) {
      _append('NFC is not enabled or not available.');
      debugPrint('[NFC] retryNfcRead: NFC not enabled');
      return;
    }
    if (!hceActive.value && _validate()) {
      await NfcHceService.setPayload(contactJson);
      hceActive.value = true;
      _append('Re-armed NFC HCE for retry.');
      debugPrint('[NFC] retryNfcRead: re-armed HCE');
    }
    final jitterMs = 200 + Random().nextInt(600);
    await Future.delayed(Duration(milliseconds: jitterMs));
    debugPrint('[NFC] retryNfcRead: starting read after jitter');
    await readFromPhoneViaHce();
  }

  Future<void> shareByNfcPhoneToPhone() async {
    debugPrint('[NFC] shareByNfcPhoneToPhone: called');
    if (_shareInProgress) {
      debugPrint('[NFC] shareByNfcPhoneToPhone: ignored (in-progress)');
      return;
    }
    _shareInProgress = true;
    await NfcHceService.disableReader();
    await Future.delayed(const Duration(milliseconds: 120));
    if (!_validate()) {
      _shareInProgress = false;
      return;
    }
    await checkNfcEnabled();
    if (!nfcEnabled.value) {
      _append('NFC is not enabled or not available.');
      debugPrint('[NFC] shareByNfcPhoneToPhone: NFC not enabled');
      _shareInProgress = false;
      return;
    }
    try {
      await NfcHceService.setPayload(contactJson);
      hceActive.value = true;
      _append('NFC HCE ready. Bring the other phone close to exchange.');
      debugPrint(
        '[NFC] shareByNfcPhoneToPhone: HCE payload set, hceActive true',
      );
      final channel = const MethodChannel('nfc_utils');
      String deviceId = '';
      try {
        deviceId = await channel.invokeMethod<String>('getAndroidId') ?? '';
      } catch (_) {}
      final hash = deviceId.hashCode;
      bool forceReader = false;
      if (_lastCardFirstFailed) {
        if ((hash & 1) == 1) {
          forceReader = true;
        }
        _lastCardFirstFailed = false;
      }

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
        final readerDelayMs =
            (override == 'reader')
                ? 1000 + Random().nextInt(500)
                : 200 + Random().nextInt(400);
        await Future.delayed(Duration(milliseconds: readerDelayMs));
        debugPrint('[NFC] shareByNfcPhoneToPhone: readerFirst, starting read');
        final int toMs = (override == 'reader') ? 20000 : 8000;
        final int tries = (override == 'reader') ? 3 : 2;
        await _readFromPhoneViaHceInternal(
          cardFirstMode: false,
          timeoutMs: toMs,
          attempts: tries,
        );
      } else {
        final delayMs =
            (override == 'card')
                ? 4000 + Random().nextInt(1500)
                : 1000 + Random().nextInt(500);
        await Future.delayed(Duration(milliseconds: delayMs));
        debugPrint(
          '[NFC] shareByNfcPhoneToPhone: cardFirst, starting read after delay',
        );
        final int toMs = (override == 'card') ? 20000 : 8000;
        final int tries = (override == 'card') ? 3 : 2;
        await _readFromPhoneViaHceInternal(
          cardFirstMode: true,
          timeoutMs: toMs,
          attempts: tries,
        );
      }
    } catch (e) {
      _append('Failed to start NFC HCE: $e');
      _toast('Failed to start NFC: $e');
      debugPrint('[NFC] shareByNfcPhoneToPhone: error $e');
    } finally {
      _shareInProgress = false;
    }
  }

  void _toast(String msg) {
    Get.snackbar('Info', msg, snackPosition: SnackPosition.BOTTOM);
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
                      ).colorScheme.primary.withValues(alpha: 0.15),
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

  Future<void> startNearbyAuto() async {
    if (!_validate()) return;
    if (nearbyActive.value) {
      _append('Nearby already running.');
      return;
    }
    final jsonStr = contactJson;
    nearbyMode.value = 'auto';
    nearbyActive.value = true;
    _append('Nearby started (Auto).');
    try {
      await transferService.advertiseOpen(
        'unitecloud-auto',
        payloadToSend: jsonStr,
        onPayload: (full) => _handleIncoming(full),
      );
      await transferService.discoverOpen(
        payloadToSend: jsonStr,
        onPayload: (full) => _handleIncoming(full),
      );
    } on PlatformException catch (e) {
      _append('Nearby couldn’t start.');
      _toast('Nearby failed: ${e.message ?? e.code}');
      nearbyActive.value = false;
    } catch (e) {
      _append('Nearby couldn’t start.');
      _toast('Nearby failed: $e');
      nearbyActive.value = false;
    }
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
    _append('Your code: $token');
    try {
      await transferService.advertise(
        'unitecloud-sender',
        token,
        payloadToSend: jsonStr,
        onPayload: (full) => _handleIncoming(full),
      );
    } on PlatformException catch (e) {
      _append('Nearby sender failed.');
      _toast('Nearby sender failed: ${e.message ?? e.code}');
      nearbyActive.value = false;
      advertisingToken.value = null;
      return null;
    } catch (e) {
      _append('Nearby sender failed.');
      _toast('Nearby sender failed: $e');
      nearbyActive.value = false;
      advertisingToken.value = null;
      return null;
    }
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
      'Connecting with code $token ${sendBack ? '(and will send my contact back)' : ''}',
    );
    try {
      await transferService.discover(
        token,
        payloadToSend: jsonStr,
        onPayload: (full) => _handleIncoming(full),
      );
    } on PlatformException catch (e) {
      _append('Nearby receiver failed.');
      _toast('Nearby receiver failed: ${e.message ?? e.code}');
      nearbyActive.value = false;
      advertisingToken.value = null;
    } catch (e) {
      _append('Nearby receiver failed.');
      _toast('Nearby receiver failed: $e');
      nearbyActive.value = false;
      advertisingToken.value = null;
    }
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
