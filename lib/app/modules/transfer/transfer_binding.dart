import 'package:get/get.dart';
import '../../services/bluetooth_service.dart';
import 'transfer_controller.dart';

class TransferBinding extends Bindings {
  @override
  void dependencies() {
    Get.put<TransferService>(TransferService(), permanent: true);
    Get.put<TransferController>(
      TransferController(transferService: Get.find()),
    );
  }
}
