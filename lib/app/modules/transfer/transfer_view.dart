import 'package:flutter/material.dart';
import 'package:get/get.dart';
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
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // NFC Share
                  Obx(
                    () =>
                        controller.hasNfc.value
                            ? ElevatedButton.icon(
                              onPressed: () async {
                                await controller.shareByTap(context);
                              },
                              icon: const Icon(Icons.nfc),
                              label: const Text('Share by NFC'),
                            )
                            : const SizedBox.shrink(),
                  ),
                  const SizedBox(width: 12),
                  // TransferService (Nearby/Bluetooth)
                  ElevatedButton.icon(
                    onPressed: () async {
                      await controller.shareByNearby(context);
                    },
                    icon: const Icon(Icons.wifi_tethering),
                    label: const Text('Share Nearby'),
                  ),
                  const SizedBox(width: 12),
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
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // NFC Listen
                  Obx(
                    () =>
                        controller.hasNfc.value
                            ? ElevatedButton.icon(
                              onPressed: () async {
                                await controller.listenForTap(context);
                              },
                              icon: const Icon(Icons.sensors),
                              label: const Text('Listen for Tap'),
                            )
                            : const SizedBox.shrink(),
                  ),
                  const SizedBox(width: 12),
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

                                    // Present a modern contact card bottom sheet
                                    // with avatar initials and Save action
                                    // Use parent context to show the sheet
                                    // ignore: use_build_context_synchronously
                                    await showModalBottomSheet(
                                      context: context,
                                      isScrollControlled: true,
                                      shape: const RoundedRectangleBorder(
                                        borderRadius: BorderRadius.vertical(
                                          top: Radius.circular(16),
                                        ),
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
                                              bottom:
                                                  MediaQuery.of(
                                                    sheetCtx,
                                                  ).viewInsets.bottom +
                                                  16,
                                              top: 16,
                                            ),
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.stretch,
                                              children: [
                                                Row(
                                                  children: [
                                                    CircleAvatar(
                                                      radius: 28,
                                                      backgroundColor: Theme.of(
                                                            sheetCtx,
                                                          ).colorScheme.primary
                                                          .withOpacity(0.15),
                                                      child: Text(
                                                        initials,
                                                        style: TextStyle(
                                                          fontWeight:
                                                              FontWeight.w700,
                                                          color:
                                                              Theme.of(sheetCtx)
                                                                  .colorScheme
                                                                  .primary,
                                                          fontSize: 20,
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 16),
                                                    Expanded(
                                                      child: Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        children: [
                                                          Text(
                                                            contact.name,
                                                            style: Theme.of(
                                                                  sheetCtx,
                                                                )
                                                                .textTheme
                                                                .titleLarge
                                                                ?.copyWith(
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w700,
                                                                ),
                                                          ),
                                                          const SizedBox(
                                                            height: 4,
                                                          ),
                                                          Text(
                                                            'New contact',
                                                            style: Theme.of(
                                                                  sheetCtx,
                                                                )
                                                                .textTheme
                                                                .bodySmall
                                                                ?.copyWith(
                                                                  color:
                                                                      Colors
                                                                          .grey[600],
                                                                ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(height: 16),
                                                Card(
                                                  elevation: 0,
                                                  color: Theme.of(sheetCtx)
                                                      .colorScheme
                                                      .surfaceVariant
                                                      .withOpacity(0.5),
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          12,
                                                        ),
                                                  ),
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsets.all(
                                                          12.0,
                                                        ),
                                                    child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        Row(
                                                          children: [
                                                            const Icon(
                                                              Icons.phone,
                                                              size: 20,
                                                            ),
                                                            const SizedBox(
                                                              width: 8,
                                                            ),
                                                            Expanded(
                                                              child: Text(
                                                                contact.phone,
                                                                style:
                                                                    Theme.of(
                                                                          sheetCtx,
                                                                        )
                                                                        .textTheme
                                                                        .bodyMedium,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                        const SizedBox(
                                                          height: 8,
                                                        ),
                                                        Row(
                                                          children: [
                                                            const Icon(
                                                              Icons
                                                                  .email_outlined,
                                                              size: 20,
                                                            ),
                                                            const SizedBox(
                                                              width: 8,
                                                            ),
                                                            Expanded(
                                                              child: Text(
                                                                contact.email,
                                                                style:
                                                                    Theme.of(
                                                                          sheetCtx,
                                                                        )
                                                                        .textTheme
                                                                        .bodyMedium,
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
                                                        onPressed:
                                                            () =>
                                                                Navigator.of(
                                                                  sheetCtx,
                                                                ).pop(),
                                                        child: const Text(
                                                          'Cancel',
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 12),
                                                    Expanded(
                                                      child:
                                                          ElevatedButton.icon(
                                                            icon: const Icon(
                                                              Icons
                                                                  .save_rounded,
                                                            ),
                                                            onPressed: () {
                                                              controller
                                                                  .saveContact(
                                                                    contact,
                                                                  );
                                                              Navigator.of(
                                                                sheetCtx,
                                                              ).pop();
                                                            },
                                                            label: const Text(
                                                              'Save contact',
                                                            ),
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
                    color: Colors.black.withOpacity(0.04),
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
