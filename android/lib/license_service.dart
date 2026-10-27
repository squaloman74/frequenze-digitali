import 'dart:convert';
import 'package:android_id/android_id.dart';
import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _defaultPublicKeys = [
  '565ffe0474961e868c5e613eff739aa4e7593dabdadf4fec3e5693eb5036f723',
  'c578eef1f4dccd3de39b0c28f7b529c0c0ccf6cf57fc92ea5f130f6c2916a4b1',
  '3dfd19df472615229e73bfc9834b03a78d3f2492a09f66a8d9fddb67218d11f4',
];

class LicenseService {
  LicenseService({List<String>? verificationKeyHexes})
    : _verificationKeyHexes = verificationKeyHexes ?? _defaultPublicKeys;

  final AndroidId _androidId = const AndroidId();
  final Ed25519 _ed25519 = Ed25519();
  final List<String> _verificationKeyHexes;

  Future<String> getHardwareId() async {
    final androidId = (await _androidId.getId())?.trim().toLowerCase() ?? '';
    if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(androidId)) {
      throw StateError('ID Android non disponibile su questo dispositivo.');
    }
    final digest = await Sha256().hash(
      utf8.encode('FD-HWID-v1|android|$androidId'),
    );
    return digest.bytes
        .take(16)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<String?> loadSavedLicense() async {
    return (await SharedPreferences.getInstance()).getString('license_code');
  }

  Future<void> saveLicense(String code) async {
    await (await SharedPreferences.getInstance()).setString(
      'license_code',
      code,
    );
  }

  Future<bool> verify(String input, String expectedHwid) async {
    final license = _parse(input);
    if (license.hwid != expectedHwid) {
      throw const FormatException(
        'La licenza è stata generata per un altro dispositivo.',
      );
    }
    if (license.expires != null &&
        DateTime.parse(license.expires!).isBefore(
          DateTime.now().toUtc().toLocal().copyWith(
            hour: 0,
            minute: 0,
            second: 0,
            millisecond: 0,
            microsecond: 0,
          ),
        )) {
      throw const FormatException('La licenza è scaduta.');
    }

    final payload = utf8.encode(
      jsonEncode({
        'ctx': 'FD-LICENSE-v1',
        'expires': license.expires,
        'hwid': license.hwid,
        'issued': license.issued,
      }),
    );
    for (final keyHex in _verificationKeyHexes) {
      final key = SimplePublicKey(
        _decodeHex(keyHex),
        type: KeyPairType.ed25519,
      );
      final valid = await _ed25519.verify(
        payload,
        signature: Signature(license.signature, publicKey: key),
      );
      if (valid) return true;
    }
    throw const FormatException('Firma della licenza non valida.');
  }

  _ParsedLicense _parse(String input) {
    final value = input.trim();
    if (value.startsWith('{')) {
      return _fromJson(jsonDecode(value));
    }
    final compact = value.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();
    final payload = _decodeBase32(compact);
    if (payload.length != 87 || payload[0] != 1) {
      throw const FormatException('Codice alfanumerico non valido.');
    }
    final hwid = payload
        .sublist(1, 17)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    final issuedOrdinal = _readUint24(payload, 17);
    final expiresOrdinal = _readUint24(payload, 20);
    final issued = _dateFromOrdinal(issuedOrdinal);
    final expires = expiresOrdinal == 0
        ? null
        : _dateFromOrdinal(expiresOrdinal);
    return _ParsedLicense(
      hwid: hwid,
      issued: issued,
      expires: expires,
      signature: payload.sublist(23),
    );
  }

  _ParsedLicense _fromJson(Object? decoded) {
    if (decoded is! Map<String, dynamic> || decoded['schema'] != 1) {
      throw const FormatException('Formato licenza non supportato.');
    }
    final hwid = decoded['hwid'];
    final issued = decoded['issued'];
    final expires = decoded['expires'];
    final signature = decoded['sig'];
    if (hwid is! String ||
        !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(hwid) ||
        issued is! String ||
        (expires != null && expires is! String) ||
        signature is! String) {
      throw const FormatException('Contenuto licenza incompleto o non valido.');
    }
    try {
      DateTime.parse(issued);
      if (expires != null) DateTime.parse(expires as String);
      return _ParsedLicense(
        hwid: hwid.toLowerCase(),
        issued: issued,
        expires: expires as String?,
        signature: base64Decode(signature),
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Date o firma della licenza non valide.');
    }
  }

  List<int> _decodeBase32(String value) {
    if (!RegExp(r'^[A-Z2-7]+$').hasMatch(value)) {
      throw const FormatException(
        'Usa solo lettere e numeri validi nel codice.',
      );
    }
    final output = <int>[];
    var buffer = 0;
    var bits = 0;
    for (final rune in value.codeUnits) {
      final digit = rune >= 65 && rune <= 90 ? rune - 65 : rune - 24;
      buffer = (buffer << 5) | digit;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        output.add((buffer >> bits) & 0xff);
        buffer &= (1 << bits) - 1;
      }
    }
    if (bits > 0 && buffer != 0) {
      throw const FormatException('Codice alfanumerico non valido.');
    }
    return output;
  }

  List<int> _decodeHex(String value) {
    return List.generate(
      value.length ~/ 2,
      (index) =>
          int.parse(value.substring(index * 2, index * 2 + 2), radix: 16),
    );
  }

  int _readUint24(List<int> bytes, int offset) =>
      (bytes[offset] << 16) | (bytes[offset + 1] << 8) | bytes[offset + 2];

  String _dateFromOrdinal(int ordinal) {
    if (ordinal < 1 || ordinal > 3652059) {
      throw const FormatException('Data nel codice licenza non valida.');
    }
    return DateTime.utc(
      1,
    ).add(Duration(days: ordinal - 1)).toIso8601String().substring(0, 10);
  }
}

class _ParsedLicense {
  const _ParsedLicense({
    required this.hwid,
    required this.issued,
    required this.expires,
    required this.signature,
  });

  final String hwid;
  final String issued;
  final String? expires;
  final List<int> signature;
}
