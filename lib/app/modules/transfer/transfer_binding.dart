import 'package:get/get.dart';
import '../../services/nfc_service.dart';
import '../../services/bluetooth_service.dart';
import 'transfer_controller.dart';

class TransferBinding extends Bindings {
  @override
  void dependencies() {
    Get.put<NfcService>(NfcService(), permanent: true);
    Get.put<TransferService>(TransferService(), permanent: true);
    Get.put<TransferController>(
      TransferController(nfcService: Get.find(), transferService: Get.find()),
    );
  }
}
