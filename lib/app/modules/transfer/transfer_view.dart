import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:flutter/services.dart';
import 'transfer_controller.dart';
import '../../services/qr_share_service.dart';
// Business logic for parsing/saving is handled in the controller

class TransferView extends StatelessWidget {
  const TransferView({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<TransferController>();

    return Scaffold(
      appBar: AppBar(title: const Text('Quick Share')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // HCE Active banner
              Obx(() {
                if (controller.hceActive.value) {
                  return Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.green.shade300),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.nfc, color: Colors.green),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'NFC active: Hold phones together to exchange contacts',
                            style: TextStyle(
                              color: Colors.green,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () async {
                            await controller.stopHceShare();
                          },
                          child: const Text('Stop'),
                        ),
                      ],
                    ),
                  );
                }
                return const SizedBox.shrink();
              }),
              // NFC reading progress
              Obx(() {
                if (controller.isNfcReading.value ||
                    (controller.nfcReadStatus.value.isNotEmpty)) {
                  return Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.blue.shade200),
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 18,
                          height: 18,
                          child:
                              controller.isNfcReading.value
                                  ? const CircularProgressIndicator(
                                    strokeWidth: 2,
                                  )
                                  : const Icon(
                                    Icons.info_outline,
                                    size: 18,
                                    color: Colors.blue,
                                  ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            controller.nfcReadStatus.value.isEmpty
                                ? 'Reading via NFC…'
                                : controller.nfcReadStatus.value,
                            style: const TextStyle(color: Colors.blue),
                          ),
                        ),
                        if (controller.isNfcReading.value)
                          TextButton(
                            onPressed: () async {
                              await controller.stopHceShare();
                            },
                            child: const Text('Cancel'),
                          ),
                        if (!controller.isNfcReading.value &&
                            controller.hceActive.value)
                          TextButton(
                            onPressed: () async {
                              await controller.retryNfcRead();
                            },
                            child: const Text('Try again'),
                          ),
                      ],
                    ),
                  );
                }
                return const SizedBox.shrink();
              }),
              Obx(() {
                if (!controller.hasNfc.value) {
                  return Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade100,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.orange.shade300),
                    ),
                    child: const Text(
                      'NFC device not detected on your device. Use the Nearby Share option below.',
                      style: TextStyle(
                        color: Colors.orange,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  );
                } else if (!controller.nfcEnabled.value) {
                  return Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.shade100,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.red.shade300),
                    ),
                    child: const Text(
                      'NFC is disabled. Please enable NFC in system settings to use this feature.',
                      style: TextStyle(
                        color: Colors.red,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  );
                }
                return const SizedBox.shrink();
              }),
              TextField(
                controller: controller.nameController,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              TextField(
                controller: controller.phoneController,
                decoration: const InputDecoration(labelText: 'Phone'),
                keyboardType: TextInputType.phone,
              ),
              TextField(
                controller: controller.emailController,
                decoration: const InputDecoration(labelText: 'Email'),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 12),

              // Obx(() {
              //   final sel = controller.nfcRoleOverride.value;
              //   return Row(
              //     children: [
              //       const Text('NFC role:'),
              //       const SizedBox(width: 8),
              //       ChoiceChip(
              //         label: const Text('Auto'),
              //         selected: sel == 'auto',
              //         onSelected: (v) {
              //           if (v) controller.nfcRoleOverride.value = 'auto';
              //         },
              //       ),
              //       const SizedBox(width: 6),
              //       ChoiceChip(
              //         label: const Text('Reader'),
              //         selected: sel == 'reader',
              //         onSelected: (v) {
              //           if (v) controller.nfcRoleOverride.value = 'reader';
              //         },
              //       ),
              //       const SizedBox(width: 6),
              //       ChoiceChip(
              //         label: const Text('Card'),
              //         selected: sel == 'card',
              //         onSelected: (v) {
              //           if (v) controller.nfcRoleOverride.value = 'card';
              //         },
              //       ),
              //     ],
              //   );
              // }),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  // NFC Share (phone-to-phone unified)
                  Obx(
                    () =>
                        controller.hasNfc.value
                            ? ElevatedButton.icon(
                              onPressed: () async {
                                await controller.shareByNfcPhoneToPhone();
                              },
                              icon: const Icon(Icons.nfc),
                              label: const Text('Share by NFC'),
                            )
                            : const SizedBox.shrink(),
                  ),
                  // TransferService (Nearby/Bluetooth)
                  ElevatedButton.icon(
                    onPressed: () async {
                      // Clean UI bottom sheet for Nearby flows
                      showModalBottomSheet(
                        context: context,
                        isScrollControlled: true,
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.vertical(
                            top: Radius.circular(16),
                          ),
                        ),
                        builder: (sheetCtx) {
                          final theme = Theme.of(sheetCtx);
                          final textTheme = theme.textTheme;
                          final color = theme.colorScheme;
                          Widget section(
                            String title,
                            String subtitle,
                            IconData icon,
                            Widget trailing,
                          ) {
                            return Card(
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              color: color.surfaceContainerHighest.withValues(
                                alpha: 0.5,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 40,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        color: color.primary.withValues(
                                          alpha: 0.1,
                                        ),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Icon(icon, color: color.primary),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            title,
                                            style: textTheme.titleMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w700,
                                                ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            subtitle,
                                            style: textTheme.bodySmall
                                                ?.copyWith(
                                                  color: Colors.grey[700],
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    trailing,
                                  ],
                                ),
                              ),
                            );
                          }

                          final codeController = TextEditingController();
                          bool sendBack = true;

                          return SafeArea(
                            child: Padding(
                              padding: EdgeInsets.only(
                                left: 16,
                                right: 16,
                                bottom:
                                    MediaQuery.of(sheetCtx).viewInsets.bottom +
                                    16,
                                top: 16,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.wifi_tethering,
                                        color: color.primary,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Nearby Share',
                                        style: textTheme.titleLarge?.copyWith(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const Spacer(),
                                      IconButton(
                                        icon: const Icon(Icons.close_rounded),
                                        onPressed:
                                            () => Navigator.of(sheetCtx).pop(),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Obx(
                                    () =>
                                        controller.nearbyActive.value
                                            ? Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 10,
                                                    vertical: 8,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: Colors.green.withValues(
                                                  alpha: 0.1,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                              ),
                                              child: Row(
                                                children: [
                                                  const Icon(
                                                    Icons.check_circle,
                                                    color: Colors.green,
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                    child: Text(
                                                      'Nearby is active (${controller.nearbyMode.value.isEmpty ? 'running' : controller.nearbyMode.value})',
                                                    ),
                                                  ),
                                                  TextButton(
                                                    onPressed: () async {
                                                      await controller
                                                          .stopNearby();
                                                    },
                                                    child: const Text('Stop'),
                                                  ),
                                                ],
                                              ),
                                            )
                                            : const SizedBox.shrink(),
                                  ),
                                  const SizedBox(height: 8),
                                  // Show code inline when in code sender mode
                                  Obx(() {
                                    final showCode =
                                        controller.nearbyActive.value &&
                                        controller.nearbyMode.value ==
                                            'sender' &&
                                        (controller.advertisingToken.value ??
                                                '')
                                            .isNotEmpty;
                                    if (!showCode) {
                                      return const SizedBox.shrink();
                                    }
                                    final code =
                                        controller.advertisingToken.value!;
                                    return Card(
                                      elevation: 0,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      color: Theme.of(sheetCtx)
                                          .colorScheme
                                          .surfaceContainerHighest
                                          .withValues(alpha: 0.5),
                                      child: Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            Text(
                                              'Your code',
                                              style: textTheme.titleMedium
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                            ),
                                            const SizedBox(height: 8),
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: SelectableText(
                                                    code,
                                                    textAlign: TextAlign.center,
                                                    style: textTheme
                                                        .headlineSmall
                                                        ?.copyWith(
                                                          fontWeight:
                                                              FontWeight.w800,
                                                          letterSpacing: 2,
                                                        ),
                                                  ),
                                                ),
                                                IconButton(
                                                  tooltip: 'Copy',
                                                  onPressed: () async {
                                                    await Clipboard.setData(
                                                      ClipboardData(text: code),
                                                    );
                                                  },
                                                  icon: const Icon(
                                                    Icons.copy_rounded,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 8),
                                            Text(
                                              'Ask the other device to enter this code to connect.',
                                              style: textTheme.bodySmall
                                                  ?.copyWith(
                                                    color: Colors.grey[700],
                                                  ),
                                            ),
                                            const SizedBox(height: 8),
                                            Align(
                                              alignment: Alignment.centerRight,
                                              child: TextButton(
                                                onPressed: () async {
                                                  await controller.stopNearby();
                                                },
                                                child: const Text('Stop'),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  }),
                                  const SizedBox(height: 8),
                                  section(
                                    'Auto discover & share',
                                    'Both devices tap Start. We’ll find each other and exchange contact cards.',
                                    Icons.autorenew_rounded,
                                    ElevatedButton(
                                      onPressed: () async {
                                        Navigator.of(sheetCtx).pop();
                                        await controller.startNearbyAuto();
                                      },
                                      child: const Text('Start'),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  section(
                                    'Enter code (manual)',
                                    'One generates a 6‑char code. The other enters it to connect.',
                                    Icons.dialpad,
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        OutlinedButton(
                                          onPressed: () async {
                                            await controller
                                                .startNearbyCodeSender();
                                            // Code is shown inline above in this bottom sheet.
                                          },
                                          child: const Text('Get code'),
                                        ),
                                        const SizedBox(width: 8),
                                        ElevatedButton(
                                          onPressed: () async {
                                            // Open mini form inline in dialog
                                            await showDialog(
                                              context: sheetCtx,
                                              builder: (dCtx) {
                                                return AlertDialog(
                                                  title: const Text(
                                                    'Enter code',
                                                  ),
                                                  content: Column(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      TextField(
                                                        controller:
                                                            codeController,
                                                        decoration:
                                                            const InputDecoration(
                                                              labelText:
                                                                  '6‑char code',
                                                              hintText:
                                                                  'ABC123',
                                                            ),
                                                        textCapitalization:
                                                            TextCapitalization
                                                                .characters,
                                                      ),
                                                      const SizedBox(height: 8),
                                                      StatefulBuilder(
                                                        builder:
                                                            (
                                                              c,
                                                              setState,
                                                            ) => CheckboxListTile(
                                                              dense: true,
                                                              title: const Text(
                                                                'Send my contact back',
                                                              ),
                                                              value: sendBack,
                                                              onChanged:
                                                                  (
                                                                    v,
                                                                  ) => setState(
                                                                    () =>
                                                                        sendBack =
                                                                            v ??
                                                                            true,
                                                                  ),
                                                            ),
                                                      ),
                                                    ],
                                                  ),
                                                  actions: [
                                                    TextButton(
                                                      onPressed:
                                                          () =>
                                                              Navigator.of(
                                                                dCtx,
                                                              ).pop(),
                                                      child: const Text(
                                                        'Cancel',
                                                      ),
                                                    ),
                                                    ElevatedButton(
                                                      onPressed: () async {
                                                        Navigator.of(
                                                          dCtx,
                                                        ).pop();
                                                        Navigator.of(
                                                          sheetCtx,
                                                        ).pop();
                                                        await controller
                                                            .startNearbyCodeReceiver(
                                                              codeController
                                                                  .text
                                                                  .trim()
                                                                  .toUpperCase(),
                                                              sendBack:
                                                                  sendBack,
                                                            );
                                                      },
                                                      child: const Text(
                                                        'Connect',
                                                      ),
                                                    ),
                                                  ],
                                                );
                                              },
                                            );
                                          },
                                          child: const Text('Enter code'),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                    icon: const Icon(Icons.wifi_tethering),
                    label: const Text('Share Nearby'),
                  ),
                  // QR Code Share
                  ElevatedButton.icon(
                    onPressed: () async {
                      showDialog(
                        context: context,
                        builder: (ctx) {
                          return AlertDialog(
                            title: const Text('Share by QR Code'),
                            content:
                                controller.name.value.trim().isEmpty &&
                                        controller.phone.value.trim().isEmpty &&
                                        controller.email.value.trim().isEmpty
                                    ? const Text(
                                      'Fill contact info to generate QR',
                                    )
                                    : SingleChildScrollView(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          QrShareService.generateQr(
                                            controller.contactJson,
                                            size: 220,
                                          ),
                                          const SizedBox(height: 12),
                                          Text(
                                            'Scan this QR to receive contact',
                                          ),
                                        ],
                                      ),
                                    ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(ctx).pop(),
                                child: const Text('Close'),
                              ),
                            ],
                          );
                        },
                      );
                    },
                    icon: const Icon(Icons.qr_code),
                    label: const Text('Share by QR'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  // QR Code Scan
                  ElevatedButton.icon(
                    onPressed: () async {
                      showDialog(
                        context: context,
                        builder:
                            (ctx) => AlertDialog(
                              title: const Text('Scan QR Code'),
                              content: SizedBox(
                                width: 260,
                                height: 320,
                                child: QrShareService.buildQrScanner(
                                  onScanned: (data) async {
                                    Navigator.of(ctx).pop();
                                    final contact = controller
                                        .parseScannedPayload(data);
                                    if (contact == null) return;

                                    // Reuse controller's preview sheet for consistency
                                    await controller.presentContactPreview(
                                      contact,
                                    );
                                  },
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(ctx).pop(),
                                  child: const Text('Close'),
                                ),
                              ],
                            ),
                      );
                    },
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan QR'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'Logs:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Obx(
                () => Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(
                    minHeight: 80,
                    maxHeight: 180,
                  ),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade400),
                    borderRadius: BorderRadius.circular(6),
                    color: Colors.black.withValues(alpha: 0.04),
                  ),
                  child: SingleChildScrollView(
                    reverse: true,
                    child: Text(
                      controller.log.value,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Saved Contacts:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Obx(
                () => ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: controller.contacts.length,
                  itemBuilder: (ctx, i) {
                    final c = controller.contacts[i];
                    return Card(
                      child: ListTile(
                        title: Text(c.name),
                        subtitle: Text('${c.phone}\n${c.email}'),
                        isThreeLine: true,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
