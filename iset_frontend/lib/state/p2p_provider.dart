import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/p2p/android_nearby.dart';

class Peer {
  final String id;

  /// Friendly name used only by the UI.
  final String name;

  /// Raw Nearby endpoint name, e.g. `ISET-AB12CD`. Kept for QR code matching.
  final String rawName;

  const Peer({required this.id, required this.name, String? rawName})
      : rawName = rawName ?? name;
}

/// Connection-request name used by the two devices during QR pairing.
/// New format: `ISET-CODE|name|targetCode|studentId|userId` where targetCode is
/// the QR code being scanned. Older `name|ISET-CODE` requests are still read.
class NearbyHandshake {
  final String code;
  final String name;
  final String? targetCode;
  final String? studentId;
  final int? userId;

  const NearbyHandshake({
    required this.code,
    required this.name,
    this.targetCode,
    this.studentId,
    this.userId,
  });

  static final RegExp _codePattern = RegExp(r'^[A-F0-9]{6}$');

  static String? codeFromAdvertised(String raw) {
    final trimmed = raw.trim();
    if (trimmed.toUpperCase().startsWith('ISET-')) {
      return _normalizeCode(trimmed.substring(5));
    }
    return null;
  }

  static String? _normalizeCode(String raw) {
    final code = raw.trim().toUpperCase();
    return _codePattern.hasMatch(code) ? code : null;
  }

  static NearbyHandshake? parse(String raw) {
    final parts = raw.trim().split('|');
    if (parts.isEmpty) return null;

    final firstCode = codeFromAdvertised(parts.first);
    if (firstCode != null) {
      final name = parts.length > 1 && parts[1].trim().isNotEmpty
          ? parts[1].trim()
          : firstCode;
      return NearbyHandshake(
        code: firstCode,
        name: name,
        targetCode: parts.length > 2 ? _normalizeCode(parts[2]) : null,
        studentId: parts.length > 3 && parts[3].trim().isNotEmpty
            ? parts[3].trim()
            : null,
        userId: parts.length > 4 ? int.tryParse(parts[4].trim()) : null,
      );
    }

    if (parts.length >= 2) {
      final code = codeFromAdvertised(parts[1]);
      if (code != null) {
        final name = parts.first.trim();
        return NearbyHandshake(
          code: code,
          name: name.isEmpty ? code : name,
          targetCode: parts.length > 2 ? _normalizeCode(parts[2]) : null,
          studentId: parts.length > 3 && parts[3].trim().isNotEmpty
              ? parts[3].trim()
              : null,
          userId: parts.length > 4 ? int.tryParse(parts[4].trim()) : null,
        );
      }
    }

    final advertised = codeFromAdvertised(raw);
    if (advertised != null) {
      return NearbyHandshake(code: advertised, name: advertised);
    }
    return null;
  }
}

/// Payload shown in "My device QR" and read by the scanner.
/// Format: `ISET1|<6 hex chars>|<friendly name>|<student id>|<user id>`
/// Older `ISET1|CODE|name` payloads are still accepted.
class NearbyQrPayload {
  final String code;
  final String? name;
  final String? studentId;
  final int? userId;

  const NearbyQrPayload(
    this.code, {
    this.name,
    this.studentId,
    this.userId,
  });

  static final RegExp _codePattern = RegExp(r'^[A-F0-9]{6}$');

  static NearbyQrPayload? parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    final parts = trimmed.split('|');
    if (parts.first == 'ISET1' && parts.length >= 2) {
      final code = parts[1].trim().toUpperCase();
      if (_codePattern.hasMatch(code)) {
        final name = parts.length > 2 && parts[2].trim().isNotEmpty
            ? parts[2].trim()
            : null;
        final studentId = parts.length > 3 && parts[3].trim().isNotEmpty
            ? parts[3].trim()
            : null;
        final userId = parts.length > 4 ? int.tryParse(parts[4].trim()) : null;
        return NearbyQrPayload(
          code,
          name: name,
          studentId: studentId,
          userId: userId,
        );
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
        onEndpointFound: (id, name) => _addUnique(
              _endpoints,
              Peer(id: id, name: _friendlyName(name), rawName: name),
            ),
        onEndpointLost: (id) => _remove(_endpoints, id),
        onConnectionInitiated: (id, name) {
          final handshake = NearbyHandshake.parse(name);
          final friendly = handshake?.name ?? _friendlyName(name);
          final remoteCode = handshake?.code ?? _codeFromAdvertised(name);
          final targetCode = handshake?.targetCode;
          final peer = Peer(id: id, name: friendly, rawName: name);

          if (handshake != null && remoteCode != null) {
            registerPeerIdentity(
              remoteCode,
              userId: handshake.userId,
              studentId: handshake.studentId,
              name: handshake.name,
            );
          }

          // Auto-accept only when this request is tied to the QR code currently
          // being shown/scanned. A plain Nearby discovery request still needs
          // the normal Accept tap.
          final isQrOwner =
              _qrSharing && targetCode != null && targetCode == _deviceCode;
          final isQrScanner =
              remoteCode != null && _qrHandshakeCodes.contains(remoteCode);

          _addUnique(_pending, peer);
          if (isQrOwner || isQrScanner) {
            _status = 'Auto-accepting QR connection from $friendly…';
            notifyListeners();
            unawaited(accept(peer));
            return;
          }

          _status = '$friendly wants to connect';
          notifyListeners();
        },
        onConnectionResult: (id, connected) {
          final peer = _pending.firstWhere(
            (p) => p.id == id,
            orElse: () => _endpoints.firstWhere(
              (p) => p.id == id,
              orElse: () => Peer(
                    id: id,
                    name: id.length > 6 ? id.substring(0, 6) : id,
                  ),
            ),
          );
          _remove(_pending, id);
          final waiter = _connectionWaiters.remove(id);
          if (!connected) {
            if (waiter != null && !waiter.isCompleted) waiter.complete(false);
            _status = 'Connection failed. Try again.';
            notifyListeners();
            return;
          }

          _addUnique(_connected, peer);
          _status = 'Connected to ${peer.name}';
          if (waiter != null && !waiter.isCompleted) waiter.complete(true);
          // Nearby discovery is radio-heavy; stop it for a stable link.
          final service = _service;
          if (service != null) {
            unawaited(service.stopDiscovery().then((_) {
              _discoveryRunning = false;
            }));
          }
          notifyListeners();
        },
        onDisconnected: (id) {
          _remove(_connected, id);
          _status = 'Device disconnected';
          final service = _service;
          if (_running && _connected.isEmpty && service != null) {
            unawaited(service.restartDiscovery(_myName).then((ok) {
              _discoveryRunning = ok;
            }));
            _status = 'Device disconnected. Searching again…';
          }
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
            final uri = _incomingUris[payloadId];
            if (transfer.kind == TransferKind.incoming) {
              if (uri == null) {
                transfer.status = TransferStatus.failed;
                _status = 'Received ${transfer.fileName} but could not save it.';
              } else {
                // Keep the transfer running until the native save confirms.
                _service!.saveReceivedFile(uri, transfer.fileName).then((path) {
                  if (path == null) {
                    transfer.status = TransferStatus.failed;
                    _status = 'Received ${transfer.fileName} but could not save it.';
                  } else {
                    transfer.status = TransferStatus.done;
                    transfer.savedPath = path;
                    _status = 'Saved ${transfer.fileName} to $AndroidNearby.receivedFolder';
                  }
                  notifyListeners();
                }).catchError((_) {
                  transfer.status = TransferStatus.failed;
                  _status = 'Received ${transfer.fileName} but could not save it.';
                  notifyListeners();
                });
              }
            } else {
              transfer.status = TransferStatus.done;
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
  final Map<String, int> _peerUserIds = {};
  final Map<String, String> _peerStudentIds = {};
  final Set<String> _qrHandshakeCodes = {};
  final Map<String, Completer<bool>> _connectionWaiters = {};
  bool _qrSharing = false;
  String _myName = 'ISET student';
  int? _myUserId;
  String? _myStudentId;
  bool _running = false;
  bool _discoveryRunning = false;
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
  /// Peer identity is supplied when QR pairing provided a stable user id.
  void Function(
    String peerName,
    String text,
    int? peerUserId,
    String? peerStudentId,
  )? onChatText;

  bool get running => _running;
  String get status => _status;
  List<Peer> get endpoints => List.unmodifiable(_endpoints);
  List<Peer> get pending => List.unmodifiable(_pending);
  List<Peer> get connected => List.unmodifiable(_connected);
  List<TransferItem> get transfers => List.unmodifiable(_transfers);
  List<NearbyChatMessage> get chatMessages => List.unmodifiable(_chatMessages);
  bool get hasActiveFileTransfer =>
      _transfers.any((t) => t.status == TransferStatus.running);

  /// Stable short code advertised by Nearby and shown in the device QR.
  String get pairingCode => 'ISET-$_deviceCode';

  String get qrPayload =>
      'ISET1|$_deviceCode|${_myName.trim()}|${_myStudentId ?? ''}|${_myUserId ?? ''}';

  String? _codeFromAdvertised(String advertised) =>
      NearbyHandshake.codeFromAdvertised(advertised);

  String _friendlyName(String advertised) {
    final code = _codeFromAdvertised(advertised);
    if (code != null && _qrNames.containsKey(code)) return _qrNames[code]!;
    return advertised;
  }

  /// Called while the "My device QR" dialog is visible. Incoming requests
  /// during this window are treated as QR-initiated and auto-accepted.
  void beginQrSharing() {
    _qrSharing = true;
  }

  void endQrSharing() {
    _qrSharing = false;
    _qrHandshakeCodes.clear();
  }

  void setDisplayName(String name) {
    final trimmed = name.trim().replaceAll('|', ' ');
    if (trimmed.isEmpty || trimmed == _myName) return;
    _myName = trimmed;
    notifyListeners();
  }

  /// Stable identity is attached to QR payloads and connection requests so
  /// nearby chat can route by user id instead of a display name.
  void setIdentity({int? userId, String? studentId, String? name}) {
    if (userId != null) _myUserId = userId;
    if (studentId != null) _myStudentId = studentId.trim();
    if (name != null) setDisplayName(name);
  }

  void clearIdentity() {
    _myUserId = null;
    _myStudentId = null;
    _peerUserIds.clear();
    _peerStudentIds.clear();
    _qrNames.clear();
  }

  void registerPeerIdentity(
    String code, {
    int? userId,
    String? studentId,
    String? name,
  }) {
    final normalized = code.trim().toUpperCase();
    if (!_codePattern.hasMatch(normalized)) return;
    if (userId != null) _peerUserIds[normalized] = userId;
    if (studentId != null && studentId.trim().isNotEmpty) {
      _peerStudentIds[normalized] = studentId.trim();
    }
    if (name != null && name.trim().isNotEmpty) {
      _qrNames[normalized] = name.trim();
    }
    notifyListeners();
  }

  bool isConnectedTo(String peerName) =>
      _connected.any((p) => p.name == peerName);

  String? _codeForPeer(Peer peer) =>
      NearbyHandshake.parse(peer.rawName)?.code ?? _codeFromAdvertised(peer.rawName);

  Peer? _connectedPeerForUser(int userId) {
    for (final peer in _connected) {
      final code = _codeForPeer(peer);
      if (code != null && _peerUserIds[code] == userId) return peer;
    }
    return null;
  }

  bool isConnectedToUser(int userId) => _connectedPeerForUser(userId) != null;

  Future<bool> sendChatTextToUser(int userId, String text) async {
    final peer = _connectedPeerForUser(userId);
    if (peer == null) return false;
    return _sendChatText(peer, text);
  }

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
      _discoveryRunning = started;
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

    registerPeerIdentity(
      payload.code,
      userId: payload.userId,
      studentId: payload.studentId,
      name: payload.name,
    );
    _qrHandshakeCodes.add(payload.code);

    if (!_running) {
      await start(_myName);
      if (!_running) return false;
    }
    await _ensureDiscovering();

    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!DateTime.now().isAfter(deadline)) {
      final endpoint = _endpoints.firstWhere(
        (p) => _codeFromAdvertised(p.rawName) == payload.code,
        orElse: () => const Peer(id: '', name: ''),
      );
      if (endpoint.id.isNotEmpty) {
        final peerName = payload.name ?? endpoint.name;
        final peer = Peer(
          id: endpoint.id,
          name: peerName,
          rawName: endpoint.rawName,
        );
        _status = 'Found $peerName. Sending connect request…';
        notifyListeners();

        final waiter = Completer<bool>();
        _connectionWaiters[endpoint.id] = waiter;
        await connect(peer, targetCode: payload.code);
        final connected = await waiter.future.timeout(
          const Duration(seconds: 20),
          onTimeout: () => false,
        );
        _connectionWaiters.remove(endpoint.id);
        if (!connected) {
          _status = 'Could not complete the connection. Keep both screens open and try again.';
          notifyListeners();
        }
        return connected;
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }

    _status = 'Could not find that device yet. Keep its QR screen open and try again.';
    notifyListeners();
    return false;
  }

  /// Discovery is stopped after a connection to keep the link stable. QR
  /// scanning needs it running again, even if Nearby itself is still active.
  Future<void> _ensureDiscovering() async {
    final service = _service;
    if (service == null || !_running || _discoveryRunning) return;
    _endpoints.clear();
    final ok = await service.restartDiscovery(_myName);
    _discoveryRunning = ok;
    notifyListeners();
  }

  Future<void> stop() async {
    final service = _service;
    if (service == null) return;
    await service.stop();
    _running = false;
    _discoveryRunning = false;
    _qrSharing = false;
    _qrHandshakeCodes.clear();
    for (final waiter in _connectionWaiters.values) {
      if (!waiter.isCompleted) waiter.complete(false);
    }
    _connectionWaiters.clear();
    _status = '';
    _endpoints.clear();
    _pending.clear();
    _connected.clear();
    notifyListeners();
  }

  Future<void> connect(Peer peer, {String? targetCode}) async {
    final service = _service;
    if (service == null) return;
    try {
      // Include our own code and, for QR flow, the code we scanned. The QR
      // owner can then verify this request really came from that scan.
      final parts = <String>[
        pairingCode,
        _myName,
        targetCode ?? '',
        _myStudentId ?? '',
        _myUserId?.toString() ?? '',
      ];
      await service.requestConnection(parts.join('|'), peer.id);
      _status = 'Connecting to ${peer.name}…';
    } catch (error) {
      _status = 'Connection request failed: ${_friendlyError(error)}';
      final waiter = _connectionWaiters.remove(peer.id);
      if (waiter != null && !waiter.isCompleted) waiter.complete(false);
    }
    notifyListeners();
  }

  Future<void> accept(Peer peer) async {
    final service = _service;
    if (service == null) return;
    try {
      final accepted = await service.accept(peer.id);
      if (!accepted) {
        _remove(_pending, peer.id);
        _status = 'Could not accept the connection from ${peer.name}.';
      } else {
        // Do not mark connected until onConnectionResult reports native success.
        _status = 'Connecting to ${peer.name}…';
      }
    } catch (error) {
      _remove(_pending, peer.id);
      _status = 'Connection failed: ${_friendlyError(error)}';
      final waiter = _connectionWaiters.remove(peer.id);
      if (waiter != null && !waiter.isCompleted) waiter.complete(false);
    }
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
    final peer = _connected.firstWhere(
      (p) => p.name == peerName,
      orElse: () => const Peer(id: '', name: ''),
    );
    if (peer.id.isEmpty) return false;
    return _sendChatText(peer, text);
  }

  Future<bool> _sendChatText(Peer peer, String text) async {
    final service = _service;
    if (service == null || text.trim().isEmpty) return false;

    try {
      await service.sendChatText(peer.id, text.trim());
      _chatMessages.add(NearbyChatMessage(
        peerName: peer.name,
        text: text.trim(),
        mine: true,
        at: DateTime.now(),
      ));
      _status = 'Sent message to ${peer.name} via Nearby';
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
            rawName: endpointId,
          ),
    );
    _chatMessages.add(NearbyChatMessage(
      peerName: peer.name,
      text: text,
      mine: false,
      at: DateTime.now(),
    ));
    final code = _codeForPeer(peer);
    onChatText?.call(
      peer.name,
      text,
      code == null ? null : _peerUserIds[code],
      code == null ? null : _peerStudentIds[code],
    );
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
