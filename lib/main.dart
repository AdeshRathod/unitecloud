import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'app/modules/transfer/transfer_binding.dart';
import 'app/modules/transfer/transfer_view.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const UniteCloudApp());
}

class UniteCloudApp extends StatelessWidget {
  const UniteCloudApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'UniteCloud',
      debugShowCheckedModeBanner: false,
      initialBinding: TransferBinding(),
      home: const TransferView(),
      getPages: [
        GetPage(
          name: '/transfer',
          page: () => const TransferView(),
          binding: TransferBinding(),
        ),
      ],
    );
  }
}
