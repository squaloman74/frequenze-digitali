import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:frequenze_digitali/signal_processing.dart';

void main() {
  test('corrected microphone level is unavailable below its baseline', () {
    expect(calculateCorrectedAudioDb(-77.5, -53.5), isNull);
    expect(calculateCorrectedAudioDb(-53.5, -53.5), isNull);
  });

  test(
    'corrected microphone level remains a finite dBFS value above baseline',
    () {
      final corrected = calculateCorrectedAudioDb(-35, -40);

      expect(corrected, isNotNull);
      expect(corrected!.isFinite, isTrue);
      expect(corrected, lessThanOrEqualTo(0));
      expect(corrected, greaterThanOrEqualTo(-120));
    },
  );

  test('calculates a visible peak for a known tone', () {
    final samples = List<double>.generate(
      1024,
      (index) => 0.5 * math.sin(2 * math.pi * 32 * index / 1024),
    );

    final spectrum = calculateSpectrum(samples);

    expect(spectrum, hasLength(64));
    expect(spectrum[4], greaterThan(0.5));
    expect(spectrum.every((value) => value >= 0 && value <= 1), isTrue);
  });

  test('renders digital silence at the spectrum floor', () {
    final spectrum = calculateSpectrum(List<double>.filled(1024, 0));

    expect(spectrum, everyElement(0));
  });

  test('rejects sample windows shorter than one FFT frame', () {
    expect(
      () => calculateSpectrum(List<double>.filled(512, 0)),
      throwsArgumentError,
    );
  });
}
