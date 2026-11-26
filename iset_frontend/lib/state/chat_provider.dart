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

class ChatProvider extends ChangeNotifier {
  ChatProvider(this._api, this._prefs, {P2PProvider? p2p})
      : _p2p = p2p,
        _autoNearby = _prefs.getBool(_autoNearbyKey) ?? true {
    _p2p?.onChatText = _onNearbyText;
  }

  static const _contactsKey = 'cached_contacts';
  static const _autoNearbyKey = 'auto_nearby_switch';

  final ApiClient _api;
  final SharedPreferences _prefs;
  final P2PProvider? _p2p;
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
    final name = auth.user?.name.trim() ?? 'ISET student';
    if (name.isNotEmpty && name != _myName) {
      _myName = name;
      _p2p?.setDisplayName(name);
    }
    if (token == _token && myId == _myId) return;
    _token = token;
    _myId = myId;
    _teardownSocket();

    if (token == null) {
      _contacts = const [];
      _threads.clear();
      _onlineUsers.clear();
      _connection = ChatConnection.offline;
      _offlineMode = false;
      _prefs.remove(_contactsKey);
      Future.microtask(notifyListeners);
      return;
    }

    _loadCachedContacts();
    _connection = ChatConnection.connecting;
    Future.microtask(() {
      _connect(token);
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
    socket.onConnectError((_) => _handleNetworkLoss());
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
      if (!_threads.containsKey(message.senderId)) {
        _threads[message.senderId] = <ChatMessage>[];
      }
      _threads[message.senderId]!.add(message);
      notifyListeners();
    });

    socket.connect();
  }

  void _teardownSocket() {
    _socket?.disconnect();
    _socket = null;
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
      } else if (p2p != null && p2p.running) {
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
      // Keep the cached list; switch to Nearby if this was a network failure.
      if (error.isNetworkError) _handleNetworkLoss();
    }
    notifyListeners();
  }

  Future<void> loadHistory(int otherId) async {
    if (_threads.containsKey(otherId)) return;
    _loadingThreads.add(otherId);
    notifyListeners();
    try {
      _threads[otherId] = await _api.fetchConversation(_token!, otherId);
    } on ApiException catch (error) {
      // Keep any Nearby messages already received for this peer.
      if (_threads[otherId] == null) _threads[otherId] = <ChatMessage>[];
      if (error.isNetworkError) _handleNetworkLoss();
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
    if (!_threads.containsKey(receiverId)) {
      _threads[receiverId] = <ChatMessage>[];
    }
    _threads[receiverId]!.add(message);
  }

  String? _contactName(int userId) {
    for (final contact in _contacts) {
      if (contact.id == userId) return contact.name;
    }
    return null;
  }

  Future<bool> _sendViaNearby(int receiverId, String text) async {
    final p2p = _p2p;
    final peerName = _contactName(receiverId);
    if (p2p == null ||
        !p2p.supported ||
        peerName == null ||
        !p2p.isConnectedTo(peerName)) {
      return false;
    }
    final sent = await p2p.sendChatText(peerName, text);
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

  void _onNearbyText(String peerName, String text) {
    final contact = _contacts.firstWhere(
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
