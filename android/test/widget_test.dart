import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frequenze_digitali/main.dart';
import 'package:frequenze_digitali/license_service.dart';

class _FakeLicenseService extends LicenseService {
  @override
  Future<String> getHardwareId() async => '0123456789abcdef0123456789abcdef';

  @override
  Future<String?> loadSavedLicense() async => null;

  @override
  Future<bool> verify(String input, String expectedHwid) async => true;

  @override
  Future<void> saveLicense(String code) async {}
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Frequenze Digitali',
      packageName: 'it.frequenzedigitali.frequenze_digitali',
      version: '26.0.0-beta.8',
      buildNumber: '8',
      buildSignature: '',
    );
  });

  testWidgets('opens the device activation screen instead of the placeholder', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      FrequenzeDigitaliApp(licenseService: _FakeLicenseService()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Frequenze Digitali'), findsOneWidget);
    expect(find.text('26 BETA'), findsOneWidget);
    expect(find.text('Attiva il dispositivo'), findsOneWidget);
    expect(find.text('Codice alfanumerico licenza'), findsOneWidget);
    expect(find.text('Il prossimo segnale parte da qui.'), findsNothing);
  });

  testWidgets('opens the telemetry dashboard after license activation', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      FrequenzeDigitaliApp(licenseService: _FakeLicenseService()),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'test-license');
    await tester.tap(find.text('Verifica licenza'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('TELEMETRIA DEL DISPOSITIVO'), findsOneWidget);
    expect(find.text('Avvia microfono'), findsOneWidget);
    expect(find.text('Frequenza nel tempo'), findsOneWidget);
    expect(find.text('Forma d’onda'), findsOneWidget);
    expect(find.text('Spettrogramma'), findsOneWidget);
    expect(find.text('Crea PDF'), findsOneWidget);
    expect(find.text('Bip per anomalie'), findsOneWidget);
    expect(find.text('26 BETA'), findsOneWidget);
    expect(find.text('Registro telemetria'), findsNothing);
    expect(find.text('Report finale indagine'), findsOneWidget);
    expect(find.text('Frequenza nel tempo · modello Lorenz'), findsOneWidget);
    expect(
      find.text('Spettrogramma audio · FFT (frequenza verticale)'),
      findsNothing,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            RegExp(r'^\d{2}:\d{2}:\d{2}$').hasMatch(widget.data ?? ''),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Forma d’onda'));
    await tester.pump();
    expect(
      find.text('Forma d’onda audio · campioni microfono'),
      findsOneWidget,
    );
    expect(
      find.text('Avvia il microfono per visualizzare il segnale audio.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Spettrogramma'));
    await tester.pump();
    expect(find.text('Spettrogramma'), findsOneWidget);
    expect(
      find.text('Spettrogramma audio · FFT (frequenza verticale)'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Picchi verdi: normale. Picchi rossi: anomalia persistente a 50/60 Hz.',
      ),
      findsOneWidget,
    );

    expect(find.text('Il prossimo segnale parte da qui.'), findsNothing);
  });

  testWidgets('beta users can open and cancel the feedback form', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      FrequenzeDigitaliApp(licenseService: _FakeLicenseService()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Informazioni scientifiche'));
    await tester.pumpAndSettle();
    expect(find.text('Informazioni scientifiche · 26 BETA'), findsOneWidget);

    await tester.tap(find.text('Invia feedback'));
    await tester.pumpAndSettle();
    expect(find.text('Feedback 26 BETA'), findsOneWidget);
    expect(find.text('Condividi feedback'), findsOneWidget);
    expect(find.text('Il feedback non include automaticamente'), findsNothing);
    await tester.enterText(
      find.byType(TextField).last,
      'Il selettore si legge bene sul mio telefono.',
    );
    expect(
      find.text('Il selettore si legge bene sul mio telefono.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Annulla'));
    await tester.pumpAndSettle();
    expect(find.text('Feedback 26 BETA'), findsNothing);
  });

  testWidgets('anomaly beeps can be disabled and their volume is adjustable', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      FrequenzeDigitaliApp(licenseService: _FakeLicenseService()),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'test-license');
    await tester.tap(find.text('Verifica licenza'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final alertLabel = find.text('Bip per anomalie');
    await tester.ensureVisible(alertLabel);
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsOneWidget);
    final initialVolume = tester.widget<Slider>(find.byType(Slider)).value;
    expect(initialVolume, 65);
    expect(initialVolume, greaterThanOrEqualTo(10));
    expect(initialVolume, lessThanOrEqualTo(100));
    final sliderRect = tester.getRect(find.byType(Slider));
    await tester.tapAt(Offset(sliderRect.right - 8, sliderRect.center.dy));
    await tester.pump();
    final adjustedVolume = tester.widget<Slider>(find.byType(Slider)).value;
    expect(adjustedVolume, greaterThan(initialVolume));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNothing);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool('anomaly_sound_enabled'), isFalse);
    expect(preferences.getInt('anomaly_sound_settings_version'), 2);
    expect(
      preferences.getDouble('anomaly_sound_volume'),
      closeTo(adjustedVolume, 0.01),
    );
  });

  testWidgets('migrates the previous quiet alert volume to a louder default', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'anomaly_sound_enabled': true,
      'anomaly_sound_volume': 12.0,
    });
    await tester.pumpWidget(
      FrequenzeDigitaliApp(licenseService: _FakeLicenseService()),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'test-license');
    await tester.tap(find.text('Verifica licenza'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.ensureVisible(find.text('Bip per anomalie'));
    await tester.pumpAndSettle();

    expect(tester.widget<Slider>(find.byType(Slider)).value, 65);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getDouble('anomaly_sound_volume'), 65);
    expect(preferences.getInt('anomaly_sound_settings_version'), 2);
  });
}
