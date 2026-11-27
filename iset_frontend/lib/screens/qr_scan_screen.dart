import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../theme.dart';

/// Scans the QR shown on another student's Files tab and returns the raw
/// payload through Navigator.pop().
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  bool _handled = false;
  bool _checkingPermission = true;
  String? _cameraError;

  @override
  void initState() {
    super.initState();
    _requestCameraPermission();
  }

  Future<void> _requestCameraPermission() async {
    final status = await Permission.camera.request();
    if (!mounted) return;
    if (!status.isGranted) {
      setState(() {
        _checkingPermission = false;
        _cameraError = status.isPermanentlyDenied
            ? 'Camera access is blocked. Open Android settings and allow Camera for ISET Community Hub.'
            : 'Camera access is needed to scan a device QR.';
      });
    } else {
      // Building MobileScanner after permission is granted lets the widget
      // attach its controller before the camera starts.
      setState(() => _checkingPermission = false);
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled || !mounted) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw != null && raw.isNotEmpty) {
        _handled = true;
        Navigator.of(context).pop(raw);
        return;
      }
    }
  }

  String _scannerMessage(MobileScannerException error) {
    switch (error.errorCode) {
      case MobileScannerErrorCode.permissionDenied:
        return 'Camera access is needed to scan a device QR.';
      case MobileScannerErrorCode.unsupported:
        return 'This device has no usable camera for QR scanning.';
      case MobileScannerErrorCode.controllerNotAttached:
        return 'The camera was not ready. Close this screen and try again.';
      default:
        return error.errorCode.message;
    }
  }

  Widget _cameraErrorView(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.qr_code_scanner, size: 48, color: AppColors.muted),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
            if (message.contains('Android settings') ||
                message.contains('Camera access')) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: openAppSettings,
                child: const Text('Open settings'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan device QR')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_cameraError != null)
            _cameraErrorView(_cameraError!)
          else if (_checkingPermission)
            const Center(child: CircularProgressIndicator())
          else
            MobileScanner(
              onDetect: _onDetect,
              errorBuilder: (_, error) =>
                  _cameraErrorView(_scannerMessage(error)),
            ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 28,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: BoxDecoration(
                color: AppColors.surface.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Text(
                'Point the camera at your classmate\'s device QR. '
                'Nearby will start automatically if needed.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
