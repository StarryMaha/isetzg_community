import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:iset_community/models/chat_message.dart';
import 'package:iset_community/models/user.dart';
import 'package:iset_community/services/api_client.dart';
import 'package:iset_community/state/auth_provider.dart';
import 'package:iset_community/state/chat_provider.dart';

class _JsonClient extends http.BaseClient {
  _JsonClient(this.bodies);

  final Map<String, String> bodies;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = bodies[request.url.path] ?? '{}';
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable([utf8.encode(body)]),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }
}

class _HistoryApi extends ApiClient {
  _HistoryApi(http.Client client, this.history, {this.failFirst = false})
      : super(client: client);

  final List<ChatMessage> history;
  final bool failFirst;
  bool _failedOnce = false;

  @override
  Future<AppUser> fetchMe(String token) async {
    return const AppUser(id: 1, studentId: 'S1', name: 'Alice');
  }

  @override
  Future<List<AppUser>> fetchUsers(String token) async {
    return const [
      AppUser(id: 1, studentId: 'S1', name: 'Alice'),
      AppUser(id: 2, studentId: 'S2', name: 'Bob'),
    ];
  }

  @override
  Future<List<ChatMessage>> fetchConversation(String token, int otherId) async {
    if (failFirst && !_failedOnce) {
      _failedOnce = true;
      throw const ApiException('offline', isNetworkError: true);
    }
    return history;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('conversation history accepts a bare JSON array', () async {
    final body = jsonEncode([
      {
        'id': 11,
        'sender_id': 2,
        'receiver_id': 1,
        'content': 'first',
        'timestamp': '2026-01-01T09:00:00Z',
      },
      {
        'id': 12,
        'sender_id': 1,
        'receiver_id': 2,
        'content': 'second',
        'timestamp': '2026-01-01T10:00:00Z',
      },
    ]);
    final api = ApiClient(client: _JsonClient({'/api/messages/2': body}));

    final messages = await api.fetchConversation('token', 2);

    expect(messages.map((m) => m.id), [11, 12]);
  });

  test('conversation history accepts a messages wrapper object', () async {
    final body = jsonEncode({
      'messages': [
        {
          'id': 21,
          'sender_id': 2,
          'receiver_id': 1,
          'content': 'wrapped',
          'timestamp': '2026-01-01 09:30:00',
        },
      ],
    });
    final api = ApiClient(client: _JsonClient({'/api/messages/2': body}));

    final messages = await api.fetchConversation('token', 2);

    expect(messages.single.id, 21);
    expect(messages.single.content, 'wrapped');
  });

  test('history loads even when a live message already opened the thread',
      () async {
    SharedPreferences.setMockInitialValues({
      'auth_token': 'token',
      'user_id': 1,
      'student_id': 'S1',
      'user_name': 'Alice',
    });
    final prefs = await SharedPreferences.getInstance();
    final history = [
      ChatMessage(
        id: 11,
        senderId: 2,
        receiverId: 1,
        content: 'older server message',
        timestamp: '2026-01-01T09:00:00Z',
      ),
      ChatMessage(
        id: 12,
        senderId: 1,
        receiverId: 2,
        content: 'server copy',
        timestamp: '2026-01-01T10:00:00Z',
      ),
    ];
    final api = _HistoryApi(_JsonClient({}), history, failFirst: true);

    final auth = AuthProvider(api, prefs);
    await auth.restore();

    final chat = ChatProvider(api, prefs, connectSocket: false);
    chat.update(auth);
    await Future<void>.delayed(Duration.zero);

    // First attempt fails, leaving an empty thread for this peer.
    await chat.loadHistory(2);
    expect(chat.messages(2), isEmpty);

    // A live message arrives before history can be fetched.
    chat.messages(2).add(ChatMessage(
          id: 12,
          senderId: 1,
          receiverId: 2,
          content: 'live copy',
          timestamp: '2026-01-01T10:00:00Z',
        ));

    // Retry must load history, deduplicate id 12, and keep chronological order.
    await chat.loadHistory(2);

    final loaded = chat.messages(2);
    expect(loaded.map((m) => m.id), [11, 12]);
    expect(loaded.first.content, 'older server message');
    expect(loaded.last.content, 'server copy');
  });
}
