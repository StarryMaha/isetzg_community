import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../config.dart';
import '../models/chat_message.dart';
import '../models/user.dart';
import '../services/api_client.dart';
import 'auth_provider.dart';
import 'p2p_provider.dart';

enum ChatConnection { offline, connecting, online, failed }

/// Merges server history with messages already shown from live delivery.
/// Duplicates are removed by message id and the result stays chronological.
List<ChatMessage> mergeChatMessages(
  Iterable<ChatMessage> current,
  Iterable<ChatMessage> incoming,
) {
  final byId = <int, ChatMessage>{};
  for (final message in current) {
    byId[message.id] = message;
  }
  for (final message in incoming) {
    byId[message.id] = message;
  }
  final merged = byId.values.toList();
  merged.sort((a, b) {
    final aTime = a.sentAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final bTime = b.sentAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final byTime = aTime.compareTo(bTime);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  });
  return merged;
}

class ChatProvider extends ChangeNotifier {
  ChatProvider(this._api, this._prefs,
      {P2PProvider? p2p, bool connectSocket = true})
      : _p2p = p2p,
        _connectSocket = connectSocket,
        _autoNearby = _prefs.getBool(_autoNearbyKey) ?? true {
    _p2p?.onChatText = _onNearbyText;
  }

  static const _contactsKey = 'cached_contacts';
  static const _autoNearbyKey = 'auto_nearby_switch';

  final ApiClient _api;
  final SharedPreferences _prefs;
  final P2PProvider? _p2p;

  /// Production leaves this on. Tests can disable it while exercising the
  /// REST/history path without opening a real socket.
  final bool _connectSocket;
  io.Socket? _socket;
  String? _token;
  int? _myId;

  ChatConnection _connection = ChatConnection.offline;
  List<AppUser> _contacts = const [];
  final Map<int, List<ChatMessage>> _threads = {};
  final Set<int> _loadingThreads = {};
  final Set<int> _onlineUsers = {};
  bool _sending = false;
  String? _error;
  String? _lastDelivery;
  bool _autoNearby;
  bool _offlineMode = false;
  String _myName = 'ISET student';

  ChatConnection get connection => _connection;
  List<AppUser> get contacts => _contacts;
  Set<int> get onlineUsers => Set.unmodifiable(_onlineUsers);
  bool get sending => _sending;
  String? get error => _error;
  String? get lastDelivery => _lastDelivery;
  bool get autoNearby => _autoNearby;
  bool get offlineMode => _offlineMode;

  String get modeLabel {
    switch (_connection) {
      case ChatConnection.online:
        return 'Online';
      case ChatConnection.connecting:
        return 'Connecting…';
      default:
        return "Offline mode";
    }
  }

  bool isLoading(int userId) => _loadingThreads.contains(userId);
  List<ChatMessage> messages(int userId) => _threads[userId] ?? const [];
  ChatMessage? lastMessage(int userId) {
    final list = messages(userId);
    return list.isEmpty ? null : list.last;
  }

  /// Called by ProxyProvider whenever the auth state changes.
  void update(AuthProvider auth) {
    final token = auth.status == AuthStatus.authenticated ? auth.token : null;
    final myId = auth.user?.id;
    final studentId = auth.user?.studentId;
    final name = auth.user?.name.trim() ?? 'ISET student';
    if (name.isNotEmpty && name != _myName) {
      _myName = name;
    }
    _p2p?.setIdentity(userId: myId, studentId: studentId, name: name);
    if (token == _token && myId == _myId) return;
    _token = token;
    _myId = myId;
    _teardownSocket();

    if (token == null) {
      _contacts = const [];
      _threads.clear();
      _loadingThreads.clear();
      _onlineUsers.clear();
      _connection = ChatConnection.offline;
      _offlineMode = false;
      _prefs.remove(_contactsKey);
      final p2p = _p2p;
      if (p2p != null) {
        if (p2p.running) unawaited(p2p.stop());
        p2p.clearIdentity();
      }
      Future.microtask(notifyListeners);
      return;
    }

    _loadCachedContacts();
    _connection = ChatConnection.connecting;
    Future.microtask(() {
      if (_connectSocket) _connect(token);
      refreshContacts();
    });
  }

  void _connect(String token) {
    final socket = io.io(
      apiBaseUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .setExtraHeaders({'Authorization': 'Bearer $token'})
          .build(),
    );
    _socket = socket;

    socket.onConnect((_) {
      _connection = ChatConnection.online;
      _offlineMode = false;
      notifyListeners();
    });
    socket.onDisconnect((_) => _handleNetworkLoss());
    socket.onConnectError((data) {
      final text = data?.toString().toLowerCase() ?? '';
      if (text.contains('token') || text.contains('unauthorized')) {
        // Bad credentials are an auth failure, not an offline connection.
        _connection = ChatConnection.failed;
        _error = 'Your session is no longer valid. Please sign in again.';
        notifyListeners();
        return;
      }
      _handleNetworkLoss();
    });
    socket.on('users:online', (data) {
      final ids = (data as List<dynamic>)
          .map((e) => e is int ? e : int.parse(e.toString()))
          .toSet();
      _onlineUsers
        ..clear()
        ..addAll(ids);
      notifyListeners();
    });
    socket.on('message:new', (data) {
      final message = ChatMessage.fromJson(data as Map<String, dynamic>);
      _addMessage(message.senderId, message);
      notifyListeners();
    });

    socket.connect();
  }

  void _teardownSocket() {
    _socket?.disconnect();
    _socket = null;
  }

  bool get _socketStillConnected {
    final socket = _socket;
    return socket != null && socket.connected;
  }

  void _handleNetworkLossIfSocketDown() {
    if (!_socketStillConnected) _handleNetworkLoss();
  }

  /// Visible user control for automatic offline -> Nearby switching.
  void setAutoNearby(bool value) {
    if (value == _autoNearby) return;
    _autoNearby = value;
    unawaited(_prefs.setBool(_autoNearbyKey, value));
    if (_connection != ChatConnection.online) {
      final p2p = _p2p;
      if (value) {
        _activateNearbyIfAllowed();
      } else if (p2p != null &&
          p2p.running &&
          !p2p.hasActiveFileTransfer &&
          p2p.connected.isEmpty) {
        // Turning off automatic switching must not kill an active share.
        unawaited(p2p.stop());
      }
    }
    notifyListeners();
  }

  void _handleNetworkLoss() {
    _connection = ChatConnection.offline;
    _onlineUsers.clear();
    _offlineMode = true;
    _activateNearbyIfAllowed();
    notifyListeners();
  }

  void _activateNearbyIfAllowed() {
    final p2p = _p2p;
    if (!_autoNearby || p2p == null || !p2p.supported || p2p.running) return;
    p2p.setDisplayName(_myName);
    unawaited(p2p.start(_myName));
  }

  Future<void> refreshContacts() async {
    final token = _token;
    if (token == null) return;
    try {
      _contacts = await _api.fetchUsers(token);
      await _cacheContacts();
    } on ApiException catch (error) {
      // Keep the cached list. A REST failure must not override a working
      // Socket.IO connection.
      if (error.isNetworkError) _handleNetworkLossIfSocketDown();
    }
    notifyListeners();
  }

  Future<void> loadHistory(int otherId) async {
    final token = _token;
    if (token == null) return;
    // Always reload: reopening a conversation must pick up messages that
    // arrived from the server or another device since the last visit.
    if (_loadingThreads.contains(otherId)) return;
    _loadingThreads.add(otherId);
    notifyListeners();
    try {
      final history = await _api.fetchConversation(token, otherId);
      // Merge instead of replacing: a live message may already be on screen.
      _threads[otherId] = mergeChatMessages(_threads[otherId] ?? const [], history);
    } on ApiException catch (error) {
      // Keep any Nearby messages already received for this peer.
      _threads.putIfAbsent(otherId, () => <ChatMessage>[]);
      if (error.isNetworkError) _handleNetworkLossIfSocketDown();
    } finally {
      _loadingThreads.remove(otherId);
      notifyListeners();
    }
  }

  Future<bool> send(int receiverId, String content) async {
    final token = _token;
    final text = content.trim();
    if (text.isEmpty) return false;

    _sending = true;
    _error = null;
    _lastDelivery = null;
    notifyListeners();

    try {
      if (_offlineMode) _activateNearbyIfAllowed();

      if (token != null) {
        try {
          // Primary path: save to the server so history and live delivery work.
          final message = await _api.sendMessage(token, receiverId, text);
          _addMessage(receiverId, message);
          _lastDelivery = 'server';
          return true;
        } on ApiException catch (serverError) {
          final networkDown = serverError.isNetworkError ||
              serverError.message.contains('offline mode');
          if (networkDown) {
            if (_socketStillConnected) {
              _error = 'The server did not accept that message. Chat is still connected; try again.';
              return false;
            }
            _handleNetworkLoss();
            // Fallback: direct device-to-device text over the Nearby connection.
            if (await _sendViaNearby(receiverId, text)) {
              _lastDelivery = 'nearby';
              return true;
            }
            _error = "You're in offline mode. Connect to another device nearby to send.";
            return false;
          }
          _error = serverError.message;
          return false;
        }
      }

      if (await _sendViaNearby(receiverId, text)) {
        _lastDelivery = 'nearby';
        return true;
      }
      _error = "You're in offline mode. Connect to another device nearby to send.";
      return false;
    } catch (_) {
      _error = 'Something went wrong. Please try again.';
      return false;
    } finally {
      _sending = false;
      notifyListeners();
    }
  }

  void _addMessage(int receiverId, ChatMessage message) {
    _threads[receiverId] =
        mergeChatMessages(_threads[receiverId] ?? const [], [message]);
  }

  String? _contactName(int userId) {
    for (final contact in _contacts) {
      if (contact.id == userId) return contact.name;
    }
    return null;
  }

  Future<bool> _sendViaNearby(int receiverId, String text) async {
    final p2p = _p2p;
    if (p2p == null || !p2p.supported) return false;

    final bool sent;
    if (p2p.isConnectedToUser(receiverId)) {
      sent = await p2p.sendChatTextToUser(receiverId, text);
    } else {
      final peerName = _contactName(receiverId);
      if (peerName == null || !p2p.isConnectedTo(peerName)) return false;
      sent = await p2p.sendChatText(peerName, text);
    }
    if (!sent) return false;

    final now = DateTime.now();
    _addMessage(receiverId, ChatMessage(
          id: -now.microsecondsSinceEpoch,
          senderId: _myId ?? -1,
          receiverId: receiverId,
          content: text,
          timestamp: now.toUtc().toIso8601String(),
        ));
    return true;
  }

  void _onNearbyText(
    String peerName,
    String text,
    int? peerUserId,
    String? peerStudentId,
  ) {
    AppUser? contact;
    if (peerUserId != null) {
      for (final candidate in _contacts) {
        if (candidate.id == peerUserId) {
          contact = candidate;
          break;
        }
      }
    }
    contact ??= peerStudentId == null
        ? null
        : _contacts.firstWhere(
            (c) => c.studentId == peerStudentId,
            orElse: () => const AppUser(id: -1, studentId: '', name: ''),
          );
    if (contact != null && contact.id == -1) contact = null;
    contact ??= _contacts.firstWhere(
      (c) => c.name.toLowerCase() == peerName.toLowerCase(),
      orElse: () => const AppUser(id: -1, studentId: '', name: ''),
    );
    if (contact.id == -1) return;

    final now = DateTime.now();
    _addMessage(contact.id, ChatMessage(
          id: -now.microsecondsSinceEpoch - 1,
          senderId: contact.id,
          receiverId: _myId ?? -1,
          content: text,
          timestamp: now.toUtc().toIso8601String(),
        ));
    notifyListeners();
  }

  void _loadCachedContacts() {
    final raw = _prefs.getString(_contactsKey);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      _contacts = decoded
          .map((e) => AppUser.fromJson(e as Map<String, dynamic>))
          .toList(growable: false);
    } catch (_) {
      // Ignore corrupt cache; refreshContacts will rebuild it.
    }
  }

  Future<void> _cacheContacts() async {
    final raw = jsonEncode(
      _contacts
          .map((c) => {
                'id': c.id,
                'student_id': c.studentId,
                'name': c.name,
              })
          .toList(),
    );
    await _prefs.setString(_contactsKey, raw);
  }

  @override
  void dispose() {
    _teardownSocket();
    super.dispose();
  }
}
