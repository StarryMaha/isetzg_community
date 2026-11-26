import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../services/p2p/android_nearby.dart';

class Peer {
  final String id;
  final String name;

  const Peer({required this.id, required this.name});
}

enum TransferKind { incoming, outgoing }
enum TransferStatus { running, done, failed }

class TransferItem {
  final int payloadId;
  String fileName;
  final TransferKind kind;

  int transferred = 0;
  int total = 0;
  TransferStatus status = TransferStatus.running;
  String? savedPath;

  TransferItem({
    required this.payloadId,
    required this.fileName,
    required this.kind,
  });

  double get progress => total <= 0 ? 0 : transferred / total;
}

class NearbyChatMessage {
  final String peerName;
  final String text;
  final bool mine;
  final DateTime at;

  const NearbyChatMessage({
    required this.peerName,
    required this.text,
    required this.mine,
    required this.at,
  });
}

/// Exposes Android Nearby Connections state to the UI. All Android-only calls
/// live in android_nearby.dart and are only made when [supported] is true.
class P2PProvider extends ChangeNotifier {
  P2PProvider() {
    if (supported) {
      _service = AndroidNearby(
        onEndpointFound: (id, name) => _addUnique(_endpoints, Peer(id: id, name: name)),
        onEndpointLost: (id) => _remove(_endpoints, id),
        onConnectionInitiated: (id, name) {
          _addUnique(_pending, Peer(id: id, name: name));
          _status = '$name wants to connect';
          notifyListeners();
        },
        onConnectionResult: (id, connected) {
          _remove(_pending, id);
          if (connected) {
            final peer = _endpoints.firstWhere(
              (p) => p.id == id,
              orElse: () => Peer(
                    id: id,
                    name: id.length > 6 ? id.substring(0, 6) : id,
                  ),
            );
            _addUnique(_connected, peer);
            _status = 'Connected to ${peer.name}';
          } else {
            _status = 'Connection failed';
          }
          notifyListeners();
        },
        onDisconnected: (id) {
          _remove(_connected, id);
          _status = 'Device disconnected';
          notifyListeners();
        },
        onBytes: (endpointId, payloadId, bytes) {
          try {
            final text = utf8.decode(bytes);
            if (text.startsWith(AndroidNearby.chatPrefix)) {
              _receiveChat(endpointId, text.substring(AndroidNearby.chatPrefix.length));
            } else {
              _controlPayloadIds.add(payloadId);
              final separator = text.indexOf(':');
              if (separator > 0) {
                final id = int.tryParse(text.substring(0, separator));
                if (id != null) {
                  final name = text.substring(separator + 1);
                  _incomingNames[id] = name;
                  for (final transfer in _transfers) {
                    if (transfer.payloadId == id) transfer.fileName = name;
                  }
                }
              }
            }
          } catch (_) {
            // Ignore unrelated control payloads.
          }
          notifyListeners();
        },
        onFilePayload: (payloadId, uri) {
          _incomingUris[payloadId] = uri;
          if (!_transfers.any((t) => t.payloadId == payloadId)) {
            _transfers.add(TransferItem(
              payloadId: payloadId,
              fileName: _incomingNames[payloadId] ?? 'received_file',
              kind: TransferKind.incoming,
            ));
          }
          notifyListeners();
        },
        onTransferUpdate: (payloadId, transferred, total, success, inProgress) {
          // The small bytes payload only carries the real file name.
          if (_controlPayloadIds.contains(payloadId)) return;
          final transfer = _transfers.firstWhere(
            (t) => t.payloadId == payloadId,
            orElse: () => TransferItem(
                payloadId: payloadId,
                fileName: 'transfer_$payloadId',
                kind: TransferKind.incoming),
          );
          if (!_transfers.contains(transfer)) _transfers.add(transfer);
          transfer.transferred = transferred;
          transfer.total = total;
          if (success) {
            transfer.status = TransferStatus.done;
            final uri = _incomingUris[payloadId];
            if (transfer.kind == TransferKind.incoming && uri != null) {
              _service!.saveReceivedFile(uri, transfer.fileName).then((path) {
                transfer.savedPath = path;
                notifyListeners();
              });
            }
          } else if (!inProgress) {
            transfer.status = TransferStatus.failed;
          }
          notifyListeners();
        },
      );
    }
  }

  final bool supported = defaultTargetPlatform == TargetPlatform.android;
  AndroidNearby? _service;

  String _myName = 'ISET student';
  bool _running = false;
  String _status = '';
  final List<Peer> _endpoints = [];
  final List<Peer> _pending = [];
  final List<Peer> _connected = [];
  final List<TransferItem> _transfers = [];
  final Map<int, String> _incomingNames = {};
  final Map<int, String> _incomingUris = {};
  final Set<int> _controlPayloadIds = {};
  final List<NearbyChatMessage> _chatMessages = [];

  /// Set by ChatProvider so incoming Nearby text lands in the chat thread.
  void Function(String peerName, String text)? onChatText;

  bool get running => _running;
  String get status => _status;
  List<Peer> get endpoints => List.unmodifiable(_endpoints);
  List<Peer> get pending => List.unmodifiable(_pending);
  List<Peer> get connected => List.unmodifiable(_connected);
  List<TransferItem> get transfers => List.unmodifiable(_transfers);
  List<NearbyChatMessage> get chatMessages => List.unmodifiable(_chatMessages);

  bool isConnectedTo(String peerName) =>
      _connected.any((p) => p.name == peerName);

  Future<void> start(String myName) async {
    final service = _service;
    if (service == null || _running) return;
    _myName = myName;
    final granted = await service.requestPermissions();
    _status = granted
        ? 'Searching for nearby devices…'
        : 'Some permissions denied; discovery may fail';
    notifyListeners();
    try {
      final started = await service.start(_myName);
      _running = started;
      _status = started ? 'Searching for nearby devices…' : 'Could not start discovery';
    } catch (error) {
      _running = false;
      _status = 'Nearby unavailable: $error';
    }
    notifyListeners();
  }

  Future<void> stop() async {
    final service = _service;
    if (service == null) return;
    await service.stop();
    _running = false;
    _status = '';
    _endpoints.clear();
    _pending.clear();
    _connected.clear();
    notifyListeners();
  }

  Future<void> connect(Peer peer) async {
    final service = _service;
    if (service == null) return;
    try {
      await service.requestConnection(_myName, peer.id);
      _status = 'Connection request sent to ${peer.name}';
    } catch (error) {
      _status = 'Connection request failed: $error';
    }
    notifyListeners();
  }

  Future<void> accept(Peer peer) async {
    final service = _service;
    if (service == null) return;
    await service.accept(peer.id);
    _remove(_pending, peer.id);
    _addUnique(_connected, peer);
    notifyListeners();
  }

  Future<void> reject(Peer peer) async {
    final service = _service;
    if (service == null) return;
    await service.reject(peer.id);
    _remove(_pending, peer.id);
    notifyListeners();
  }

  Future<void> sendFile(Peer peer) async {
    final service = _service;
    if (service == null) return;
    try {
      final picked = await service.pickAndSend(peer.id);
      if (picked == null) return;
      _transfers.add(TransferItem(
        payloadId: picked.payloadId,
        fileName: picked.fileName,
        kind: TransferKind.outgoing,
      ));
      _status = 'Sending ${picked.fileName} to ${peer.name}';
    } catch (error) {
      _status = 'File transfer failed: $error';
    }
    notifyListeners();
  }

  /// Returns false when no connected peer matches [peerName].
  Future<bool> sendChatText(String peerName, String text) async {
    final service = _service;
    if (service == null || text.trim().isEmpty) return false;
    final peer = _connected.firstWhere(
      (p) => p.name == peerName,
      orElse: () => const Peer(id: '', name: ''),
    );
    if (peer.id.isEmpty) return false;

    try {
      await service.sendChatText(peer.id, text.trim());
      _chatMessages.add(NearbyChatMessage(
        peerName: peerName,
        text: text.trim(),
        mine: true,
        at: DateTime.now(),
      ));
      _status = 'Sent message to $peerName via Nearby';
      notifyListeners();
      return true;
    } catch (error) {
      _status = 'Nearby message failed: $error';
      notifyListeners();
      return false;
    }
  }

  void _receiveChat(String endpointId, String text) {
    final peer = _connected.firstWhere(
      (p) => p.id == endpointId,
      orElse: () => Peer(
            id: endpointId,
            name: endpointId.length > 6 ? endpointId.substring(0, 6) : endpointId,
          ),
    );
    _chatMessages.add(NearbyChatMessage(
      peerName: peer.name,
      text: text,
      mine: false,
      at: DateTime.now(),
    ));
    onChatText?.call(peer.name, text);
  }

  void _addUnique(List<Peer> list, Peer peer) {
    if (!list.any((p) => p.id == peer.id)) list.add(peer);
    notifyListeners();
  }

  void _remove(List<Peer> list, String id) {
    list.removeWhere((p) => p.id == id);
    notifyListeners();
  }

  @override
  void dispose() {
    _service?.stop();
    super.dispose();
  }
}
