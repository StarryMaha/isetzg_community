import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:iset_community/services/api_client.dart';
import 'package:iset_community/state/chat_provider.dart';
import 'package:iset_community/state/p2p_provider.dart';

class _FailingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw http.ClientException('Connection failed');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('network failures become friendly offline errors', () async {
    final api = ApiClient(client: _FailingClient());
    expect(
      api.fetchMe('token'),
      throwsA(isA<ApiException>()
          .having((e) => e.isNetworkError, 'isNetworkError', isTrue)
          .having((e) => e.message, 'message', contains("You're in offline mode"))),
    );
  });

  test('QR payloads identify a nearby device', () {
    final parsed = NearbyQrPayload.parse('ISET1|AB12CD|Alice');
    expect(parsed?.code, 'AB12CD');
    expect(parsed?.name, 'Alice');
    expect(NearbyQrPayload.parse('ISET-AB12CD')?.code, 'AB12CD');
    expect(NearbyQrPayload.parse('not-a-code'), isNull);
  });

  test('automatic Nearby toggle is visible and persisted', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final chat = ChatProvider(ApiClient(client: _FailingClient()), prefs);

    expect(chat.autoNearby, isTrue);
    expect(chat.modeLabel, "Offline mode");

    chat.setAutoNearby(false);
    expect(chat.autoNearby, isFalse);
    expect(prefs.getBool('auto_nearby_switch'), isFalse);
  });
}
