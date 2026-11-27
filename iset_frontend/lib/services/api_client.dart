import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/chat_message.dart';
import '../models/user.dart';

class ApiException implements Exception {
  final String message;

  /// True when the request failed because the device has no usable network path
  /// to the server. The UI shows the friendly offline message for these.
  final bool isNetworkError;

  const ApiException(this.message, {this.isNetworkError = false});
  @override
  String toString() => message;
}

class AuthResult {
  final String token;
  final AppUser user;
  const AuthResult({required this.token, required this.user});
}

class ApiClient {
  ApiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const _timeout = Duration(seconds: 10);

  Future<dynamic> _send(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
    String? token,
  }) async {
    final uri = Uri.parse(apiUrl(path));
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (token != null) headers['Authorization'] = 'Bearer $token';

    late http.Response response;
    try {
      final request = method == 'POST'
          ? _client.post(uri, headers: headers, body: jsonEncode(body ?? const {}))
          : _client.get(uri, headers: headers);
      response = await request.timeout(_timeout);
    } on TimeoutException {
      throw const ApiException(
        "You're in offline mode. Check your connection.",
        isNetworkError: true,
      );
    } on http.ClientException {
      throw const ApiException(
        "You're in offline mode. Check your connection.",
        isNetworkError: true,
      );
    }

    dynamic data;
    try {
      data = jsonDecode(response.body);
    } catch (_) {
      throw ApiException('Unexpected server response (${response.statusCode})');
    }

    if (response.statusCode >= 200 && response.statusCode < 300) return data;

    final serverMessage = data is Map<String, dynamic>
        ? data['error']?.toString()
        : null;
    throw ApiException(
        serverMessage ?? 'Request failed (${response.statusCode})');
  }

  /// Most endpoints return a JSON object. Decode defensively so a wrong shape
  /// becomes a readable error instead of a cast exception.
  Map<String, dynamic> _object(dynamic data, String path) {
    if (data is Map<String, dynamic>) return data;
    throw ApiException('Unexpected server response for $path');
  }

  Future<void> register({
    required String studentId,
    required String name,
    required String password,
  }) async {
    await _send('/api/auth/register',
        method: 'POST',
        body: {'student_id': studentId, 'name': name, 'password': password});
  }

  Future<AuthResult> login({
    required String studentId,
    required String password,
  }) async {
    final data = _object(
      await _send('/api/auth/login',
          method: 'POST',
          body: {'student_id': studentId, 'password': password}),
      'login',
    );
    return AuthResult(
      token: data['token'] as String,
      user: AppUser.fromJson(data['user'] as Map<String, dynamic>),
    );
  }

  Future<AppUser> fetchMe(String token) async {
    final data = _object(await _send('/api/auth/me', token: token), 'me');
    return AppUser.fromJson(data['user'] as Map<String, dynamic>);
  }

  Future<List<AppUser>> fetchUsers(String token) async {
    final data = _object(await _send('/api/auth/users', token: token), 'users');
    final list = data['users'] as List<dynamic>;
    return list
        .map((u) => AppUser.fromJson(u as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<List<ChatMessage>> fetchConversation(String token, int otherId) async {
    final data = await _send('/api/messages/$otherId', token: token);
    final list = _conversationList(data);
    return list
        .map((m) => ChatMessage.fromJson(m as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// The backend currently returns a bare JSON array. A small wrapper object
  /// is also accepted so older/newer API shapes can both be read without
  /// losing messages.
  static List<dynamic> _conversationList(dynamic data) {
    if (data is List<dynamic>) return data;
    if (data is Map<String, dynamic>) {
      for (final key in const ['messages', 'conversation', 'history']) {
        final value = data[key];
        if (value is List<dynamic>) return value;
      }
    }
    throw const ApiException('Unexpected conversation response');
  }

  Future<ChatMessage> sendMessage(
    String token,
    int receiverId,
    String content,
  ) async {
    final data = _object(
      await _send(
        '/api/messages/send',
        method: 'POST',
        token: token,
        body: {'receiver_id': receiverId, 'content': content.trim()},
      ),
      'send message',
    );
    return ChatMessage.fromJson(data);
  }
}
