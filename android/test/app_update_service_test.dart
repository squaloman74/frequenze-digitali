import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frequenze_digitali/app_update_service.dart';

const _apkUrl =
    'https://raw.githubusercontent.com/squaloman74/frequenze-digitali/main/android/Frequenze-Digitali.apk';

void main() {
  test('reads a newer beta release from the public update manifest', () async {
    final service = AppUpdateService(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'version': '26.0.0-beta.8',
            'buildNumber': 8,
            'apkUrl': _apkUrl,
            'sha256': 'a' * 64,
          }),
          HttpStatus.ok,
        ),
      ),
    );
    addTearDown(service.close);

    final release = await service.checkForUpdate(installedBuildNumber: 7);

    expect(release?.version, '26.0.0-beta.8');
    expect(release?.buildNumber, 8);
  });

  test('does not offer an already installed build', () async {
    final service = AppUpdateService(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'version': '26.0.0-beta.7',
            'buildNumber': 7,
            'apkUrl': _apkUrl,
            'sha256': 'a' * 64,
          }),
          HttpStatus.ok,
        ),
      ),
    );
    addTearDown(service.close);

    expect(await service.checkForUpdate(installedBuildNumber: 7), isNull);
  });

  test('rejects manifests that point outside the official APK URL', () async {
    final service = AppUpdateService(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'version': '26.0.0-beta.8',
            'buildNumber': 8,
            'apkUrl': 'https://example.com/app.apk',
            'sha256': 'a' * 64,
          }),
          HttpStatus.ok,
        ),
      ),
    );
    addTearDown(service.close);

    await expectLater(
      service.checkForUpdate(installedBuildNumber: 7),
      throwsFormatException,
    );
  });

  test('downloads only an APK matching the published SHA-256', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'frequenze-update-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));

    final apkBytes = [0x50, 0x4b, 0x03, 0x04, 1, 2, 3];
    final release = AppUpdateRelease(
      version: '26.0.0-beta.8',
      buildNumber: 8,
      apkUrl: Uri.parse(_apkUrl),
      sha256:
          'e8b35476d2bd55232509d060f0e3b56737376d1848289eea711e974396ef2311',
    );
    final service = AppUpdateService(
      temporaryDirectory: temporaryDirectory,
      client: MockClient(
        (_) async => http.Response.bytes(apkBytes, HttpStatus.ok),
      ),
    );
    addTearDown(service.close);

    final file = await service.downloadUpdate(release);

    expect(await file.readAsBytes(), apkBytes);
  });
}
