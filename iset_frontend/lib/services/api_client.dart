import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/chat_message.dart';
import '../models/user.dart';

class ApiException implements Exception {
  final String message;
  const ApiException(this.message);
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
      throw const ApiException('Server timed out. Check your connection.');
    } on http.ClientException catch (e) {
      throw ApiException('Cannot reach server: ${e.message}');
    }

    Map<String, dynamic> data;
    try {
      data = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException('Unexpected server response (${response.statusCode})');
    }

    if (response.statusCode >= 200 && response.statusCode < 300) return data;
    throw ApiException(data['error']?.toString() ?? 'Request failed (${response.statusCode})');
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
    final data = await _send('/api/auth/login',
        method: 'POST', body: {'student_id': studentId, 'password': password});
    return AuthResult(
      token: data['token'] as String,
      user: AppUser.fromJson(data['user'] as Map<String, dynamic>),
    );
  }

  Future<AppUser> fetchMe(String token) async {
    final data = await _send('/api/auth/me', token: token);
    return AppUser.fromJson(data['user'] as Map<String, dynamic>);
  }

  Future<List<AppUser>> fetchUsers(String token) async {
    final data = await _send('/api/auth/users', token: token);
    final list = data['users'] as List<dynamic>;
    return list
        .map((u) => AppUser.fromJson(u as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<List<ChatMessage>> fetchConversation(String token, int otherId) async {
    final data = await _send('/api/messages/$otherId', token: token);
    final list = data as List<dynamic>;
    return list
        .map((m) => ChatMessage.fromJson(m as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<ChatMessage> sendMessage(
    String token,
    int receiverId,
    String content,
  ) async {
    final data = await _send(
      '/api/messages/send',
      method: 'POST',
      token: token,
      body: {'receiver_id': receiverId, 'content': content.trim()},
    );
    return ChatMessage.fromJson(data as Map<String, dynamic>);
  }
}
