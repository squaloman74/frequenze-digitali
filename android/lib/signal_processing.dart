import 'dart:math' as math;

double? calculateCorrectedAudioDb(double? measuredDb, double? baselineDb) {
  if (measuredDb == null || !measuredDb.isFinite) return null;
  if (baselineDb == null) return measuredDb;
  if (!baselineDb.isFinite) return null;

  final measuredPower = math.pow(10, measuredDb / 10).toDouble();
  final baselinePower = math.pow(10, baselineDb / 10).toDouble();
  final signalPower = measuredPower - baselinePower;
  if (signalPower <= 1e-12) return null;

  final correctedDb = 10 * math.log(signalPower) / math.ln10;
  if (correctedDb < -120) return null;
  return correctedDb.clamp(-120, 0).toDouble();
}

List<double> calculateSpectrum(List<double> samples) {
  const size = 1024;
  const outputBins = 64;
  if (samples.length < size) {
    throw ArgumentError.value(
      samples.length,
      'samples',
      'At least 1024 required',
    );
  }

  final real = List<double>.filled(size, 0);
  final imaginary = List<double>.filled(size, 0);
  final start = samples.length - size;

  for (var i = 0; i < size; i++) {
    final window = 0.5 * (1 - math.cos(2 * math.pi * i / (size - 1)));
    real[i] = samples[start + i] * window;
  }

  var reversed = 0;
  for (var i = 1; i < size; i++) {
    var bit = size >> 1;
    while ((reversed & bit) != 0) {
      reversed ^= bit;
      bit >>= 1;
    }
    reversed ^= bit;
    if (i < reversed) {
      final realValue = real[i];
      real[i] = real[reversed];
      real[reversed] = realValue;
      final imaginaryValue = imaginary[i];
      imaginary[i] = imaginary[reversed];
      imaginary[reversed] = imaginaryValue;
    }
  }

  for (var length = 2; length <= size; length <<= 1) {
    final angle = -2 * math.pi / length;
    final stepReal = math.cos(angle);
    final stepImaginary = math.sin(angle);
    for (var offset = 0; offset < size; offset += length) {
      var factorReal = 1.0;
      var factorImaginary = 0.0;
      for (var j = 0; j < length ~/ 2; j++) {
        final even = offset + j;
        final odd = even + length ~/ 2;
        final oddReal =
            factorReal * real[odd] - factorImaginary * imaginary[odd];
        final oddImaginary =
            factorReal * imaginary[odd] + factorImaginary * real[odd];
        real[odd] = real[even] - oddReal;
        imaginary[odd] = imaginary[even] - oddImaginary;
        real[even] += oddReal;
        imaginary[even] += oddImaginary;
        final nextFactorReal =
            factorReal * stepReal - factorImaginary * stepImaginary;
        factorImaginary =
            factorReal * stepImaginary + factorImaginary * stepReal;
        factorReal = nextFactorReal;
      }
    }
  }

  return List<double>.generate(outputBins, (index) {
    final firstBin = 1 + index * (size ~/ 2 - 1) ~/ outputBins;
    final endBin = 1 + (index + 1) * (size ~/ 2 - 1) ~/ outputBins;
    var power = 0.0;
    for (var bin = firstBin; bin < endBin; bin++) {
      power += real[bin] * real[bin] + imaginary[bin] * imaginary[bin];
    }
    final magnitude = math.sqrt(power / math.max(1, endBin - firstBin));
    final decibels =
        20 * math.log(math.max(magnitude / size, 1e-6)) / math.ln10;
    return ((decibels + 90) / 90).clamp(0, 1).toDouble();
  });
}
