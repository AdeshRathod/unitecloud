import 'package:qr_flutter/qr_flutter.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';
import 'package:flutter/material.dart';

class QrShareService {
  static Widget generateQr(String contactJson, {double size = 200}) {
    return SizedBox(
      width: size,
      height: size,
      child: QrImageView(
        data: contactJson,
        version: QrVersions.auto,
        size: size,
      ),
    );
  }

  static Widget buildQrScanner({required void Function(String) onScanned}) {
    return _QrScannerWidget(onScanned: onScanned);
  }
}

class _QrScannerWidget extends StatefulWidget {
  final void Function(String) onScanned;
  const _QrScannerWidget({required this.onScanned});

  @override
  State<_QrScannerWidget> createState() => _QrScannerWidgetState();
}

class _QrScannerWidgetState extends State<_QrScannerWidget> {
  final GlobalKey qrKey = GlobalKey(debugLabel: 'QR');
  QRViewController? controller;

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return QRView(
      key: qrKey,
      onQRViewCreated: (ctrl) {
        controller = ctrl;
        controller?.scannedDataStream.listen((scanData) {
          widget.onScanned(scanData.code ?? '');
        });
      },
      overlay: QrScannerOverlayShape(
        borderColor: Colors.blue,
        borderRadius: 10,
        borderLength: 30,
        borderWidth: 10,
        cutOutSize: 220,
      ),
    );
  }
}
