// Android-only implementation. Never call this from Windows code.
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';

class PickedTransfer {
  final int payloadId;
  final String fileName;

  const PickedTransfer({required this.payloadId, required this.fileName});
}

class NearbyPermissionResult {
  final bool ok;
  final String? message;

  const NearbyPermissionResult.ok()
      : ok = true,
        message = null;

  const NearbyPermissionResult.blocked(this.message)
      : ok = false;
}

class AndroidNearby {
  static const serviceId = 'com.iset.community.nearby.v2';
  static const strategy = Strategy.P2P_STAR;
  static const _filesChannel = MethodChannel('com.iset.community/files');
  static const _deviceChannel = MethodChannel('com.iset.community/device');
  static const receivedFolder = 'ISET Community Hub files';
  static const chatPrefix = 'MSG:';

  AndroidNearby({
    required this.onEndpointFound,
    required this.onEndpointLost,
    required this.onConnectionInitiated,
    required this.onConnectionResult,
    required this.onDisconnected,
    required this.onBytes,
    required this.onFilePayload,
    required this.onTransferUpdate,
  });

  final Nearby _nearby = Nearby();

  final void Function(String id, String name) onEndpointFound;
  final void Function(String id) onEndpointLost;
  final void Function(String id, String name) onConnectionInitiated;
  final void Function(String id, bool connected) onConnectionResult;
  final void Function(String id) onDisconnected;
  final void Function(String endpointId, int payloadId, Uint8List bytes) onBytes;
  final void Function(int payloadId, String uri) onFilePayload;
  final void Function(int payloadId, int transferred, int total, bool success, bool inProgress)
      onTransferUpdate;

  Future<int> _sdkInt() async {
    try {
      return await _deviceChannel.invokeMethod<int>('sdkInt') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<bool> _bluetoothEnabled() async {
    try {
      return await _deviceChannel.invokeMethod<bool>('bluetoothEnabled') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Requests only the permissions that the current Android version actually
  /// uses for Nearby. Wi-Fi connection/internet is never required.
  Future<NearbyPermissionResult> requestPermissions() async {
    final sdk = await _sdkInt();
    final permissions = <Permission>[
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      if (sdk >= 33) Permission.nearbyWifiDevices else Permission.location,
    ];

    final results = await permissions.request();
    final denied = results.entries
        .where((entry) => !entry.value.isGranted)
        .map((entry) => _permissionLabel(entry.key))
        .toList();
    if (denied.isNotEmpty) {
      return NearbyPermissionResult.blocked(
        'Allow ${denied.join(', ')} to use Nearby.',
      );
    }

    // Android 12 and below need Location services ON for BLE discovery, even
    // when the app never asks for the user's position. Android 13+ uses
    // NEARBY_WIFI_DEVICES / BLUETOOTH_SCAN with neverForLocation instead.
    if (sdk < 33) {
      final locationService = await Permission.location.serviceStatus;
      if (locationService != ServiceStatus.enabled) {
        return const NearbyPermissionResult.blocked(
          'Turn on Location services to find nearby devices. Wi-Fi/internet is not needed.',
        );
      }
    }

    // Nearby can use Bluetooth without a Wi-Fi network or internet connection.
    if (!await _bluetoothEnabled()) {
      return const NearbyPermissionResult.blocked(
        'Turn on Bluetooth to use Nearby. Wi-Fi and internet are not required.',
      );
    }

    return const NearbyPermissionResult.ok();
  }

  String _permissionLabel(Permission permission) {
    switch (permission) {
      case Permission.bluetoothAdvertise:
        return 'Nearby devices (Bluetooth advertising)';
      case Permission.bluetoothConnect:
        return 'Nearby devices (Bluetooth connection)';
      case Permission.bluetoothScan:
        return 'Nearby devices (Bluetooth scanning)';
      case Permission.nearbyWifiDevices:
        return 'Nearby devices (Wi-Fi)';
      case Permission.location:
        return 'Location';
      default:
        return 'Nearby permissions';
    }
  }

  /// [advertisingName] carries the short pairing code used by QR recognition;
  /// [myName] is the friendly name shown on connection requests.
  Future<bool> start(String advertisingName, String myName) async {
    // Clear any stale session left behind by a previous run so Nearby doesn't
    // report STATUS_ALREADY_ADV (8001) when we start advertising again.
    await stop();

    final advertised = await _nearby.startAdvertising(
      advertisingName,
      strategy,
      serviceId: serviceId,
      onConnectionInitiated: (id, info) =>
          onConnectionInitiated(id, info.endpointName),
      onConnectionResult: (id, status) =>
          onConnectionResult(id, status == Status.CONNECTED),
      onDisconnected: (id) => onDisconnected(id),
    );
    if (!advertised) {
      await stop();
      return false;
    }

    try {
      final discovered = await _nearby.startDiscovery(
        myName,
        strategy,
        serviceId: serviceId,
        onEndpointFound: (id, name, service) => onEndpointFound(id, name),
        onEndpointLost: (id) => onEndpointLost(id ?? ''),
      );
      if (!discovered) {
        await stop();
      }
      return discovered;
    } catch (error) {
      // Do not leave advertising running if discovery failed.
      await stop();
      rethrow;
    }
  }

  Future<void> stop() async {
    try {
      await _nearby.stopDiscovery();
      await _nearby.stopAdvertising();
      await _nearby.stopAllEndpoints();
    } catch (_) {
      // Ignore cleanup errors; a fresh start will re-initialise Nearby.
    }
  }

  Future<void> requestConnection(String myName, String endpointId) async {
    await _nearby.requestConnection(
      myName,
      endpointId,
      onConnectionInitiated: (id, info) =>
          onConnectionInitiated(id, info.endpointName),
      onConnectionResult: (id, status) =>
          onConnectionResult(id, status == Status.CONNECTED),
      onDisconnected: (id) => onDisconnected(id),
    );
  }

  Future<bool> accept(String endpointId) {
    return _nearby.acceptConnection(
      endpointId,
      onPayLoadRecieved: (endpoint, payload) {
        if (payload.type == PayloadType.BYTES && payload.bytes != null) {
          onBytes(endpoint, payload.id, payload.bytes!);
        } else if (payload.type == PayloadType.FILE && payload.uri != null) {
          onFilePayload(payload.id, payload.uri!);
        }
      },
      onPayloadTransferUpdate: (endpoint, update) => onTransferUpdate(
        update.id,
        update.bytesTransferred,
        update.totalBytes,
        update.status == PayloadStatus.SUCCESS,
        update.status == PayloadStatus.IN_PROGRESS,
      ),
    );
  }

  Future<bool> reject(String endpointId) => _nearby.rejectConnection(endpointId);

  /// Sends one text message over the existing Nearby connection.
  Future<void> sendChatText(String endpointId, String text) {
    return _nearby.sendBytesPayload(
      endpointId,
      Uint8List.fromList(utf8.encode('$chatPrefix$text')),
    );
  }

  Future<PickedTransfer?> pickAndSend(String endpointId) async {
    final result = await FilePicker.platform.pickFiles(withData: false);
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.single;
    if (file.path == null) return null;

    final payloadId = await _nearby.sendFilePayload(endpointId, file.path!);
    // Nearby stores received files with a generic name; send the real name too.
    final nameBytes = Uint8List.fromList(utf8.encode('$payloadId:${file.name}'));
    await _nearby.sendBytesPayload(endpointId, nameBytes);
    return PickedTransfer(payloadId: payloadId, fileName: file.name);
  }

  Future<String?> saveReceivedFile(String uri, String fileName) async {
    final saved = await _filesChannel.invokeMethod<bool>(
          'saveReceivedFile',
          <String, String>{'source': uri, 'name': fileName},
        ) ??
        false;
    return saved ? 'Download/$receivedFolder/$fileName' : null;
  }
}
