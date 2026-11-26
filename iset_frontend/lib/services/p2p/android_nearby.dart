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

class AndroidNearby {
  static const serviceId = 'com.iset.community.nearby.v2';
  static const strategy = Strategy.P2P_STAR;
  static const _filesChannel = MethodChannel('com.iset.community/files');
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

  Future<bool> requestPermissions() async {
    final permissions = <Permission>[
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.nearbyWifiDevices,
      Permission.location,
    ];
    final results = await permissions.request();
    return results.values.every((status) => status.isGranted);
  }

  Future<bool> start(String myName) async {
    // Clear any stale session left behind by a previous run so Nearby doesn't
    // report STATUS_ALREADY_ADV (8001) when we start advertising again.
    await stop();
    final advertised = await _nearby.startAdvertising(
      myName,
      strategy,
      serviceId: serviceId,
      onConnectionInitiated: (id, info) =>
          onConnectionInitiated(id, info.endpointName),
      onConnectionResult: (id, status) =>
          onConnectionResult(id, status == Status.CONNECTED),
      onDisconnected: (id) => onDisconnected(id),
    );

    final discovered = await _nearby.startDiscovery(
      myName,
      strategy,
      serviceId: serviceId,
      onEndpointFound: (id, name, service) => onEndpointFound(id, name),
      onEndpointLost: (id) => onEndpointLost(id ?? ''),
    );
    return advertised && discovered;
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
