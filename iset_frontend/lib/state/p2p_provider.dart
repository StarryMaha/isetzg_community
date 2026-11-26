import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/p2p/android_nearby.dart';

class Peer {
  final String id;
  final String name;

  const Peer({required this.id, required this.name});
}

/// Payload shown in "My device QR" and read by the scanner.
/// Format: `ISET1|<6 hex chars>|<friendly name>`
class NearbyQrPayload {
  final String code;
  final String? name;

  const NearbyQrPayload(this.code, {this.name});

  static final RegExp _codePattern = RegExp(r'^[A-F0-9]{6}$');

  static NearbyQrPayload? parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    final parts = trimmed.split('|');
    if (parts.first == 'ISET1' && parts.length >= 2) {
      final code = parts[1].trim().toUpperCase();
      if (_codePattern.hasMatch(code)) {
        final name = parts.length > 2 ? parts.sublist(2).join('|').trim() : null;
        return NearbyQrPayload(code, name: name?.isEmpty == true ? null : name);
      }
    }

    if (trimmed.toUpperCase().startsWith('ISET-')) {
      final code = trimmed.substring(5).trim().toUpperCase();
      if (_codePattern.hasMatch(code)) return NearbyQrPayload(code);
    }
    return null;
  }
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
  P2PProvider({SharedPreferences? prefs})
      : _deviceCode = _initialCode(prefs) {
    if (supported) {
      _service = AndroidNearby(
        onEndpointFound: (id, name) =>
            _addUnique(_endpoints, Peer(id: id, name: _friendlyName(name))),
        onEndpointLost: (id) => _remove(_endpoints, id),
        onConnectionInitiated: (id, name) {
          final friendly = _friendlyName(name);
          _addUnique(_pending, Peer(id: id, name: friendly));
          _status = '$friendly wants to connect';
          notifyListeners();
        },
        onConnectionResult: (id, connected) {
          final peer = _endpoints.firstWhere(
            (p) => p.id == id,
            orElse: () => _pending.firstWhere(
              (p) => p.id == id,
              orElse: () => Peer(
                    id: id,
                    name: id.length > 6 ? id.substring(0, 6) : id,
                  ),
            ),
          );
          _remove(_pending, id);
          if (connected) {
            _addUnique(_connected, peer);
            _status = 'Connected to ${peer.name}';
          } else {
            _status = 'Connection failed. Try again.';
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
              _receiveChat(
                endpointId,
                text.substring(AndroidNearby.chatPrefix.length),
              );
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
              kind: TransferKind.incoming,
            ),
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

  static const _codeKey = 'nearby_pairing_code';
  static final RegExp _codePattern = RegExp(r'^[A-F0-9]{6}$');

  static String _initialCode(SharedPreferences? prefs) {
    final saved = prefs?.getString(_codeKey);
    if (saved != null && _codePattern.hasMatch(saved.toUpperCase())) {
      return saved.toUpperCase();
    }
    final random = Random.secure();
    final code = List<int>.generate(3, (_) => random.nextInt(256))
        .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join();
    prefs?.setString(_codeKey, code);
    return code;
  }

  final bool supported = defaultTargetPlatform == TargetPlatform.android;
  AndroidNearby? _service;

  final String _deviceCode;
  final Map<String, String> _qrNames = {};
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

  /// Stable short code advertised by Nearby and shown in the device QR.
  String get pairingCode => 'ISET-$_deviceCode';

  String get qrPayload => 'ISET1|$_deviceCode|${_myName.trim()}';

  String? _codeFromAdvertised(String advertised) {
    final trimmed = advertised.trim();
    if (trimmed.toUpperCase().startsWith('ISET-')) {
      return trimmed.substring(5).trim().toUpperCase();
    }
    return null;
  }

  String _friendlyName(String advertised) {
    final code = _codeFromAdvertised(advertised);
    if (code != null && _qrNames.containsKey(code)) return _qrNames[code]!;
    return advertised;
  }

  void setDisplayName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == _myName) return;
    _myName = trimmed;
    notifyListeners();
  }

  bool isConnectedTo(String peerName) =>
      _connected.any((p) => p.name == peerName);

  Future<void> start(String myName) async {
    final service = _service;
    if (service == null || _running) return;
    setDisplayName(myName);

    // Root-cause fix: actually honour the permission check and use only the
    // permissions relevant to this Android version.
    final permission = await service.requestPermissions();
    if (!permission.ok) {
      _running = false;
      _status = permission.message ?? 'Nearby permissions are missing.';
      notifyListeners();
      return;
    }

    _status = 'Searching for nearby devices…';
    notifyListeners();
    try {
      final started = await service.start(pairingCode, _myName);
      _running = started;
      _status = started
          ? 'Searching for nearby devices…'
          : 'Nearby could not start. Check Google Play Services and try again.';
    } catch (error) {
      _running = false;
      _status = 'Nearby could not start. ${_friendlyError(error)}';
    }
    notifyListeners();
  }

  String _friendlyError(Object error) {
    final text = error.toString();
    if (text.contains('8001')) return 'Nearby was already active. Try again.';
    if (text.contains('8022')) return 'A Nearby permission was denied.';
    if (text.contains('8032')) return 'A required Nearby permission is missing.';
    if (text.contains('8034')) return 'Turn on Bluetooth and try again.';
    return 'Make sure Google Play Services is available, then try again.';
  }

  /// Scans a QR payload, starts Nearby if needed, then connects to the matching
  /// advertising device. Returns false with a readable [status] on failure.
  Future<bool> connectByQr(String raw) async {
    final payload = NearbyQrPayload.parse(raw);
    if (payload == null) {
      _status = 'That QR code is not an ISET device code.';
      notifyListeners();
      return false;
    }

    if (payload.code == _deviceCode.toUpperCase()) {
      _status = 'That is your own QR code. Scan your classmate\'s code.';
      notifyListeners();
      return false;
    }

    if (payload.name != null) _qrNames[payload.code] = payload.name!;

    if (!_running) {
      await start(_myName);
      if (!_running) return false;
    }

    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!DateTime.now().isAfter(deadline)) {
      final endpoint = _endpoints.firstWhere(
        (p) => _codeFromAdvertised(p.name) == payload.code,
        orElse: () => const Peer(id: '', name: ''),
      );
      if (endpoint.id.isNotEmpty) {
        final peerName = payload.name ?? endpoint.name;
        _status = 'Found $peerName. Sending connect request…';
        notifyListeners();
        await connect(Peer(id: endpoint.id, name: peerName));
        return true;
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }

    _status = 'Could not find that device yet. Keep its QR screen open and try again.';
    notifyListeners();
    return false;
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
      _status = 'Connection request failed: ${_friendlyError(error)}';
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
      _status = 'Nearby message failed: ${_friendlyError(error)}';
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
    final service = _service;
    if (service != null) unawaited(service.stop());
    super.dispose();
  }
}
