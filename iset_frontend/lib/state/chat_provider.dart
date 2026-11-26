import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../config.dart';
import '../models/chat_message.dart';
import '../models/user.dart';
import '../services/api_client.dart';
import 'auth_provider.dart';

enum ChatConnection { offline, connecting, online, failed }

class ChatProvider extends ChangeNotifier {
  ChatProvider(this._api);

  final ApiClient _api;
  io.Socket? _socket;
  String? _token;

  ChatConnection _connection = ChatConnection.offline;
  List<AppUser> _contacts = const [];
  final Map<int, List<ChatMessage>> _threads = {};
  final Set<int> _loadingThreads = {};
  final Set<int> _onlineUsers = {};
  bool _sending = false;
  String? _error;

  ChatConnection get connection => _connection;
  List<AppUser> get contacts => _contacts;
  Set<int> get onlineUsers => Set.unmodifiable(_onlineUsers);
  bool get sending => _sending;
  String? get error => _error;

  bool isLoading(int userId) => _loadingThreads.contains(userId);
  List<ChatMessage> messages(int userId) => _threads[userId] ?? const [];
  ChatMessage? lastMessage(int userId) {
    final list = messages(userId);
    return list.isEmpty ? null : list.last;
  }

  /// Called by ProxyProvider whenever the auth state changes.
  void update(AuthProvider auth) {
    final token = auth.status == AuthStatus.authenticated ? auth.token : null;
    if (token == _token) return;
    _token = token;
    _teardownSocket();

    if (token == null) {
      _contacts = const [];
      _threads.clear();
      _onlineUsers.clear();
      _connection = ChatConnection.offline;
      Future.microtask(notifyListeners);
      return;
    }

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
      notifyListeners();
    });
    socket.onDisconnect((_) {
      _connection = ChatConnection.offline;
      _onlineUsers.clear();
      notifyListeners();
    });
    socket.onConnectError((_) {
      _connection = ChatConnection.failed;
      notifyListeners();
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

  Future<void> refreshContacts() async {
    final token = _token;
    if (token == null) return;
    try {
      _contacts = await _api.fetchUsers(token);
    } on ApiException catch (_) {
      // Keep the previous list; the connection banner shows the problem.
    }
    notifyListeners();
  }

  Future<void> loadHistory(int otherId) async {
    if (_threads.containsKey(otherId)) return;
    _loadingThreads.add(otherId);
    notifyListeners();
    try {
      _threads[otherId] = await _api.fetchConversation(_token!, otherId);
    } on ApiException catch (_) {
      _threads[otherId] = <ChatMessage>[];
    } finally {
      _loadingThreads.remove(otherId);
      notifyListeners();
    }
  }

  Future<bool> send(int receiverId, String content) async {
    final token = _token;
    final text = content.trim();
    if (token == null || text.isEmpty) return false;

    _sending = true;
    _error = null;
    notifyListeners();

    try {
      // Send over HTTP so delivery does not depend on a Socket.IO ack.
      // The backend broadcasts the saved message to the recipient's room.
      final message = await _api.sendMessage(token, receiverId, text);
      if (!_threads.containsKey(receiverId)) {
        _threads[receiverId] = <ChatMessage>[];
      }
      _threads[receiverId]!.add(message);
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      _error = e.message;
      return false;
    } catch (e) {
      _error = e.toString();
      return false;
    } finally {
      _sending = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _teardownSocket();
    super.dispose();
  }
}
