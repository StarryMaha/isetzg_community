import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:iset_community/services/api_client.dart';
import 'package:iset_community/state/auth_provider.dart';

class _FailingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw http.ClientException('Connection failed');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('restores cached session when the server is unreachable', () async {
    SharedPreferences.setMockInitialValues({
      'auth_token': 'cached-token',
      'user_id': 7,
      'student_id': 'PM_A_1795525689000',
      'user_name': 'Alice',
    });
    final prefs = await SharedPreferences.getInstance();
    final auth = AuthProvider(ApiClient(client: _FailingClient()), prefs);

    await auth.restore();

    expect(auth.status, AuthStatus.authenticated);
    expect(auth.user?.id, 7);
    expect(auth.user?.name, 'Alice');
    expect(auth.token, 'cached-token');
  });

  test('does not clear cached session on a server timeout', () async {
    SharedPreferences.setMockInitialValues({
      'auth_token': 'cached-token',
      'user_id': 8,
      'student_id': 'PM_B_1795525689798',
      'user_name': 'Bob',
    });
    final prefs = await SharedPreferences.getInstance();
    final auth = AuthProvider(ApiClient(client: _FailingClient()), prefs);

    await auth.restore();

    expect(auth.status, AuthStatus.authenticated);
    expect(auth.user?.studentId, 'PM_B_1795525689798');
  });
}
