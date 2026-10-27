import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class AppUpdateRelease {
  const AppUpdateRelease({
    required this.version,
    required this.buildNumber,
    required this.apkUrl,
    required this.sha256,
  });

  final String version;
  final int buildNumber;
  final Uri apkUrl;
  final String sha256;
}

class AppUpdateService {
  AppUpdateService({http.Client? client, this.temporaryDirectory})
    : _client = client ?? http.Client();

  static final _manifestUrl = Uri.https(
    'raw.githubusercontent.com',
    '/squaloman74/frequenze-digitali/main/android/update.json',
  );
  static final _apkUrl = Uri.https(
    'raw.githubusercontent.com',
    '/squaloman74/frequenze-digitali/main/android/Frequenze-Digitali.apk',
  );

  final http.Client _client;
  final Directory? temporaryDirectory;

  Future<AppUpdateRelease?> checkForUpdate({
    required int installedBuildNumber,
  }) async {
    final response = await _client
        .get(_manifestUrl)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Il server beta ha risposto con HTTP ${response.statusCode}. '
        'Verifica che il repository GitHub sia pubblico.',
        uri: _manifestUrl,
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException catch (error) {
      throw FormatException('Manifest aggiornamenti non valido: $error');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Manifest aggiornamenti non valido.');
    }

    final version = decoded['version'];
    final buildNumber = decoded['buildNumber'];
    final apkUrlText = decoded['apkUrl'];
    final sha256 = decoded['sha256'];
    if (version is! String ||
        !RegExp(r'^26\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$').hasMatch(version) ||
        buildNumber is! int ||
        buildNumber <= 0 ||
        apkUrlText != _apkUrl.toString() ||
        sha256 is! String ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256)) {
      throw const FormatException(
        'Manifest beta non valido: controlla versione, APK e SHA-256.',
      );
    }

    if (buildNumber <= installedBuildNumber) return null;

    return AppUpdateRelease(
      version: version,
      buildNumber: buildNumber,
      apkUrl: _apkUrl,
      sha256: sha256.toLowerCase(),
    );
  }

  Future<File> downloadUpdate(AppUpdateRelease release) async {
    final directory = temporaryDirectory ?? await getTemporaryDirectory();
    final updateDirectory = Directory('${directory.path}/updates');
    await updateDirectory.create(recursive: true);
    final file = File(
      '${updateDirectory.path}/frequenze-digitali-${release.buildNumber}.apk',
    );
    if (await file.exists()) await file.delete();

    final request = http.Request('GET', release.apkUrl);
    final response = await _client
        .send(request)
        .timeout(const Duration(minutes: 5));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Download APK non riuscito: HTTP ${response.statusCode}.',
        uri: release.apkUrl,
      );
    }
    if (response.contentLength != null &&
        response.contentLength! > 150 * 1024 * 1024) {
      throw const FormatException('Il file APK supera la dimensione prevista.');
    }

    final sink = Sha256().newHashSink();
    final output = file.openWrite();
    var receivedBytes = 0;
    var outputClosed = false;
    final firstBytes = <int>[];
    try {
      await for (final chunk in response.stream) {
        receivedBytes += chunk.length;
        if (receivedBytes > 150 * 1024 * 1024) {
          throw const FormatException(
            'Il file APK supera la dimensione prevista.',
          );
        }
        for (final byte in chunk) {
          if (firstBytes.length == 4) break;
          firstBytes.add(byte);
        }
        sink.add(chunk);
        output.add(chunk);
      }
      await output.flush();
      await output.close();
      outputClosed = true;
      sink.close();
      final digest = await sink.hash();
      final actualSha256 = digest.bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      if (receivedBytes < 4 ||
          firstBytes[0] != 0x50 ||
          firstBytes[1] != 0x4b ||
          actualSha256 != release.sha256) {
        throw const FormatException(
          'APK incompleta o non verificata: SHA-256 diverso dal manifest.',
        );
      }
      return file;
    } catch (_) {
      if (!outputClosed) await output.close();
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  void close() => _client.close();
}
