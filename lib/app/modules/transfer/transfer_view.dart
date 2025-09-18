import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'transfer_controller.dart';

class TransferView extends GetView<TransferController> {
  const TransferView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tap to Transfer')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                decoration: const InputDecoration(labelText: 'Name'),
                onChanged: (v) => controller.name.value = v,
              ),
              TextField(
                decoration: const InputDecoration(labelText: 'Phone'),
                keyboardType: TextInputType.phone,
                onChanged: (v) => controller.phone.value = v,
              ),
              TextField(
                decoration: const InputDecoration(labelText: 'Email'),
                keyboardType: TextInputType.emailAddress,
                onChanged: (v) => controller.email.value = v,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: controller.shareByTap,
                    icon: const Icon(Icons.share),
                    label: const Text('Share by Tap'),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: controller.listenForTap,
                    icon: const Icon(Icons.sensors),
                    label: const Text('Listen for Tap'),
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
