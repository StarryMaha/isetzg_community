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
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool _handled = false;
  bool _starting = true;
  bool _permissionGranted = false;
  String? _cameraError;

  @override
  void initState() {
    super.initState();
    _requestCamera();
  }

  Future<void> _requestCamera() async {
    final status = await Permission.camera.request();
    if (!mounted) return;
    if (!status.isGranted) {
      setState(() {
        _starting = false;
        _cameraError = status.isPermanentlyDenied
            ? 'Camera access is blocked. Open Android settings and allow Camera for ISET Community Hub.'
            : 'Camera access is needed to scan a device QR.';
      });
      return;
    }
    // Build the MobileScanner widget first. It starts the controller only once
    // the camera view is attached, which avoids the common "start before mount"
    // failure on Android.
    setState(() {
      _permissionGranted = true;
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
      default:
        return error.errorCode.message;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan device QR')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_cameraError != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.qr_code_scanner, size: 48,
                        color: AppColors.muted),
                    const SizedBox(height: 16),
                    Text(
                      _cameraError!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white),
                    ),
                    if (_cameraError!.contains('Android settings')) ...[
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: openAppSettings,
                        child: const Text('Open settings'),
                      ),
                    ],
                  ],
                ),
              ),
            )
          else if (_starting || !_permissionGranted)
            const Center(child: CircularProgressIndicator())
          else
            MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              errorBuilder: (_, error) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Text(
                    _scannerMessage(error),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
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
