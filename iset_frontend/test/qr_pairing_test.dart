import 'package:flutter_test/flutter_test.dart';

import 'package:iset_community/state/p2p_provider.dart';

void main() {
  test('QR payload uses the stable six-character code and user identity', () {
    final parsed = NearbyQrPayload.parse('ISET1|AB12CD|Alice|S123|7');
    expect(parsed?.code, 'AB12CD');
    expect(parsed?.name, 'Alice');
    expect(parsed?.studentId, 'S123');
    expect(parsed?.userId, 7);
  });

  test('new QR handshake carries both codes and sender identity', () {
    final handshake =
        NearbyHandshake.parse('ISET-BB22CC|Bob|AA11DD|S456|8');
    expect(handshake?.code, 'BB22CC');
    expect(handshake?.name, 'Bob');
    expect(handshake?.targetCode, 'AA11DD');
    expect(handshake?.studentId, 'S456');
    expect(handshake?.userId, 8);
  });

  test('older handshake format is still understood', () {
    final handshake = NearbyHandshake.parse('Bob|ISET-BB22CC');
    expect(handshake?.code, 'BB22CC');
    expect(handshake?.name, 'Bob');
    expect(handshake?.targetCode, isNull);
  });

  test('QR matching uses raw advertised identifier, not the friendly name', () {
    const peer = Peer(id: 'endpoint-1', name: 'Alice', rawName: 'ISET-AB12CD');
    expect(peer.name, 'Alice');
    expect(NearbyHandshake.codeFromAdvertised(peer.rawName), 'AB12CD');
    expect(NearbyHandshake.codeFromAdvertised(peer.name), isNull);
  });
}
