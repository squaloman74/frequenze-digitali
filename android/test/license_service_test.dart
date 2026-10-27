import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frequenze_digitali/license_service.dart';

void main() {
  test(
    'verifies signed alphanumeric device licenses and rejects tampering',
    () async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final publicKeyHex = publicKey.bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      final hwid = '0123456789abcdef0123456789abcdef';
      const issued = '2026-01-01';
      final payload = utf8.encode(
        jsonEncode({
          'ctx': 'FD-LICENSE-v1',
          'expires': null,
          'hwid': hwid,
          'issued': issued,
        }),
      );
      final signature = await algorithm.sign(payload, keyPair: keyPair);
      final code = _encodeLicenseCode(
        hwid: hwid,
        issued: DateTime.utc(2026).difference(DateTime.utc(1)).inDays + 1,
        signature: signature.bytes,
      );
      final service = LicenseService(verificationKeyHexes: [publicKeyHex]);
      final changedCharacter = code[60] == 'A' ? 'B' : 'A';
      final tamperedCode =
          '${code.substring(0, 60)}$changedCharacter${code.substring(61)}';

      expect(await service.verify(code, hwid), isTrue);
      await expectLater(
        service.verify(tamperedCode, hwid),
        throwsFormatException,
      );
      await expectLater(
        service.verify(code, 'fedcba9876543210fedcba9876543210'),
        throwsFormatException,
      );
    },
  );
}

String _encodeLicenseCode({
  required String hwid,
  required int issued,
  required List<int> signature,
}) {
  final payload = <int>[
    1,
    for (var i = 0; i < hwid.length; i += 2)
      int.parse(hwid.substring(i, i + 2), radix: 16),
    (issued >> 16) & 0xff,
    (issued >> 8) & 0xff,
    issued & 0xff,
    0,
    0,
    0,
    ...signature,
  ];
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final output = StringBuffer();
  var buffer = 0;
  var bits = 0;
  for (final byte in payload) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      output.write(alphabet[(buffer >> bits) & 31]);
      buffer &= (1 << bits) - 1;
    }
  }
  if (bits > 0) output.write(alphabet[(buffer << (5 - bits)) & 31]);
  return output.toString();
}
