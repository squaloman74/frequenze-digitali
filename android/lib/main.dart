import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'license_service.dart';
import 'signal_processing.dart';

const _background = Color(0xFF0E0E10);
const _surface = Color(0xFF18181C);
const _line = Color(0xFF292930);
const _signal = Color(0xFF00FFCC);
const _accent = Color(0xFFFFAA00);
const _muted = Color(0xFF92999C);
const _danger = Color(0xFFFF6B57);
const _betaVersionLabel = '26 Beta';
const _anomalyAlertChannel = MethodChannel(
  'it.frequenzedigitali/anomaly_alert',
);

enum _SignalView { frequency, waveform, spectrum }

void main() => runApp(const FrequenzeDigitaliApp());

class FrequenzeDigitaliApp extends StatelessWidget {
  const FrequenzeDigitaliApp({super.key, this.licenseService});

  final LicenseService? licenseService;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Frequenze Digitali',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _background,
        colorScheme: const ColorScheme.dark(
          primary: _signal,
          secondary: _accent,
          surface: _surface,
        ),
        useMaterial3: true,
      ),
      home: TelemetryHomePage(licenseService: licenseService),
    );
  }
}

class TelemetryHomePage extends StatefulWidget {
  const TelemetryHomePage({super.key, this.licenseService});

  final LicenseService? licenseService;

  @override
  State<TelemetryHomePage> createState() => _TelemetryHomePageState();
}

class _TelemetryHomePageState extends State<TelemetryHomePage> {
  late final LicenseService _licenseService;
  final _licenseController = TextEditingController();
  final _recorder = AudioRecorder();
  final _sampleWindow = <double>[];
  final _audioHistory = <double>[];
  final _frequencyHistory = <double>[];
  final _spectrogramHistory = <_SpectrogramFrame>[];
  final _investigationSamples = <_InvestigationSample>[];
  final _events = <_TelemetryEvent>[];
  final _audioPowers = <double>[];
  final _magneticReadings = <double>[];

  StreamSubscription<Uint8List>? _audioSubscription;
  StreamSubscription<MagnetometerEvent>? _magneticSubscription;
  Timer? _clock;
  String _hwid = '';
  String _message = 'Controllo licenza e sensori…';
  String _licenseError = '';
  String _sensorError = '';
  double? _audioDb;
  double? _audioBaseline;
  double? _magnetic;
  double? _magneticBaseline;
  double _frequency = 432;
  double _x = 0.1;
  double _y = 0;
  double _z = 0;
  int _mainsHits = 0;
  int _mainsClearHits = 0;
  int _mainsEpisodes = 0;
  int _completedCalibrations = 0;
  int _samplesUntilSpectrum = 4096;
  bool _mainsDetected = false;
  bool _soundAlertsEnabled = true;
  double _soundAlertVolume = 65;
  bool _licensed = false;
  bool _loading = true;
  bool _recording = false;
  bool _calibrating = false;
  bool _magneticAvailable = false;
  _SignalView _signalView = _SignalView.frequency;
  DateTime? _calibrationStartedAt;
  DateTime? _calibrationCompletedAt;
  DateTime? _lastMagneticAt;
  DateTime? _lastInvestigationSampleAt;
  DateTime? _lastAnomalyAlertAt;

  @override
  void initState() {
    super.initState();
    _licenseService = widget.licenseService ?? LicenseService();
    unawaited(_loadAlertSettings());
    _clock = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!_licensed) return;
      _advanceLorenzModel();
      _captureInvestigationSample(DateTime.now());
      if (_calibrating && _calibrationStartedAt != null) {
        final elapsed = DateTime.now().difference(_calibrationStartedAt!);
        if (elapsed >= const Duration(seconds: 10)) _finishCalibration();
      }
      if (_magneticAvailable &&
          _lastMagneticAt != null &&
          DateTime.now().difference(_lastMagneticAt!) >
              const Duration(seconds: 3)) {
        _magneticAvailable = false;
      }
      if (mounted) setState(() {});
    });
    unawaited(_initialize());
  }

  Future<void> _loadAlertSettings() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final settingsVersion = preferences.getInt(
        'anomaly_sound_settings_version',
      );
      final savedVolume = preferences.getDouble('anomaly_sound_volume');
      final volume = settingsVersion == 2
          ? (savedVolume ?? 65).clamp(10, 100).toDouble()
          : 65.0;
      if (settingsVersion != 2) {
        await preferences.setDouble('anomaly_sound_volume', volume);
        await preferences.setInt('anomaly_sound_settings_version', 2);
      }
      if (!mounted) return;
      setState(() {
        _soundAlertsEnabled =
            preferences.getBool('anomaly_sound_enabled') ?? true;
        _soundAlertVolume = volume;
      });
    } catch (error) {
      _showMessage('Impostazioni avvisi non disponibili: $error', error: true);
    }
  }

  Future<void> _initialize() async {
    try {
      _hwid = await _licenseService.getHardwareId();
      final saved = await _licenseService.loadSavedLicense();
      if (saved != null && await _licenseService.verify(saved, _hwid)) {
        _licensed = true;
        _message = 'Licenza verificata';
        _startMagnetometer();
      } else {
        _message = 'Attivazione richiesta per questo dispositivo.';
      }
    } catch (error) {
      _message = error.toString().replaceFirst('Bad state: ', '');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _clock?.cancel();
    unawaited(_audioSubscription?.cancel());
    unawaited(_magneticSubscription?.cancel());
    unawaited(_recorder.dispose());
    _licenseController.dispose();
    super.dispose();
  }

  void _advanceLorenzModel() {
    const sigma = 10.0;
    const rho = 28.0;
    const beta = 8.0 / 3.0;
    const dt = 0.002;
    for (var step = 0; step < 25; step++) {
      final dx = sigma * (_y - _x);
      final dy = _x * (rho - _z) - _y;
      final dz = _x * _y - beta * _z;
      _x += dx * dt;
      _y += dy * dt;
      _z += dz * dt;
    }
    _frequency = (150 + (_x + 20) / 40 * 450).clamp(150, 600).toDouble();
    _frequencyHistory.add(_frequency);
    if (_frequencyHistory.length > 600) _frequencyHistory.removeAt(0);
  }

  void _startMagnetometer() {
    _magneticSubscription?.cancel();
    _magneticSubscription =
        magnetometerEventStream(
          samplingPeriod: SensorInterval.normalInterval,
        ).listen(
          (event) {
            final value = math.sqrt(
              event.x * event.x + event.y * event.y + event.z * event.z,
            );
            if (!value.isFinite) return;
            _magnetic = value;
            _magneticAvailable = true;
            _lastMagneticAt = DateTime.now();
            if (_calibrating) _magneticReadings.add(value);
            if (mounted) setState(() {});
          },
          onError: (Object error) {
            _magneticAvailable = false;
            _magnetic = null;
            _sensorError =
                'Magnetometro non disponibile su questo dispositivo.';
            if (mounted) setState(() {});
          },
        );
  }

  Future<void> _toggleMicrophone() async {
    if (_recording) {
      await _audioSubscription?.cancel();
      _audioSubscription = null;
      await _recorder.stop();
      if (mounted) setState(() => _recording = false);
      return;
    }
    try {
      if (!await _recorder.hasPermission()) {
        throw StateError('Permesso microfono negato.');
      }
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 44100,
          numChannels: 1,
          autoGain: false,
          echoCancel: false,
          noiseSuppress: false,
          streamBufferSize: 8192,
        ),
      );
      _sampleWindow.clear();
      _spectrogramHistory.clear();
      _samplesUntilSpectrum = 4096;
      _audioSubscription = stream.listen(
        _processAudio,
        onError: (Object error) {
          _sensorError = 'Lettura microfono interrotta: $error';
          if (mounted) setState(() => _recording = false);
        },
      );
      if (mounted) {
        setState(() {
          _recording = true;
          _sensorError = '';
        });
      }
      _addEvent('Microfono attivo; i dati audio restano sul dispositivo.');
    } catch (error) {
      _showMessage('Microfono non disponibile: $error', error: true);
    }
  }

  void _processAudio(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    var sumSquares = 0.0;
    final pendingSpectra = <List<double>>[];
    final count = bytes.length ~/ 2;
    if (count == 0) return;
    for (var i = 0; i < count; i++) {
      final sample = data.getInt16(i * 2, Endian.little) / 32768.0;
      sumSquares += sample * sample;
      _sampleWindow.add(sample);
      _samplesUntilSpectrum--;
      if (_sampleWindow.length >= 1024 && _samplesUntilSpectrum <= 0) {
        pendingSpectra.add(calculateSpectrum(_sampleWindow));
        _samplesUntilSpectrum += 4096;
      }
    }
    final rms = math.sqrt(sumSquares / count);
    final db = 20 * math.log(math.max(rms, 1e-9)) / math.ln10;
    _audioDb = db.clamp(-180, 0).toDouble();
    _audioHistory.add(_audioDb!);
    if (_audioHistory.length > 150) _audioHistory.removeAt(0);
    if (_calibrating) _audioPowers.add(math.pow(10, _audioDb! / 10).toDouble());
    if (_sampleWindow.length > 8192) {
      _sampleWindow.removeRange(0, _sampleWindow.length - 8192);
    }
    _updateMainsDetection();
    for (final spectrum in pendingSpectra) {
      _spectrogramHistory.add(
        _SpectrogramFrame(spectrum, anomaly: _mainsDetected),
      );
    }
    if (_spectrogramHistory.length > 100) {
      _spectrogramHistory.removeRange(0, _spectrogramHistory.length - 100);
    }
    if (mounted) setState(() {});
  }

  void _updateMainsDetection() {
    if (_sampleWindow.length < 4096) return;
    final detected = [50.0, 60.0].any(_hasProminentTone);
    if (_mainsDetected) {
      _mainsClearHits = detected ? 0 : _mainsClearHits + 1;
      if (_mainsClearHits >= 8) {
        _mainsDetected = false;
        _mainsHits = 0;
        _mainsClearHits = 0;
      }
      return;
    }

    _mainsHits = detected ? _mainsHits + 1 : 0;
    if (_mainsHits < 3) return;
    _mainsDetected = true;
    _mainsEpisodes++;
    _addEvent('Componente a 50/60 Hz rilevata.');
    unawaited(_playAnomalyAlert());
  }

  Future<void> _playAnomalyAlert() async {
    if (!_soundAlertsEnabled || _soundAlertVolume <= 0) return;
    final now = DateTime.now();
    if (_lastAnomalyAlertAt != null &&
        now.difference(_lastAnomalyAlertAt!) < const Duration(seconds: 4)) {
      return;
    }
    _lastAnomalyAlertAt = now;
    try {
      await _anomalyAlertChannel.invokeMethod<void>('playBeep', {
        'volume': _soundAlertVolume.round(),
      });
    } on PlatformException catch (error) {
      _showMessage(
        'Avviso sonoro non disponibile: ${error.message}',
        error: true,
      );
    } on MissingPluginException {
      _showMessage('Avviso sonoro disponibile solo sulla versione Android.');
    }
  }

  Future<void> _setSoundAlertsEnabled(bool enabled) async {
    setState(() => _soundAlertsEnabled = enabled);
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool('anomaly_sound_enabled', enabled);
    } catch (error) {
      _showMessage(
        'Impossibile salvare l’impostazione audio: $error',
        error: true,
      );
    }
  }

  Future<void> _saveSoundAlertVolume(double volume) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setDouble('anomaly_sound_volume', volume);
      await preferences.setInt('anomaly_sound_settings_version', 2);
    } catch (error) {
      _showMessage(
        'Impossibile salvare il volume degli avvisi: $error',
        error: true,
      );
    }
  }

  void _captureInvestigationSample(DateTime timestamp) {
    if (_lastInvestigationSampleAt != null &&
        timestamp.difference(_lastInvestigationSampleAt!) <
            const Duration(seconds: 1)) {
      return;
    }
    _investigationSamples.add(
      _InvestigationSample(
        timestamp: timestamp,
        frequency: _frequency,
        microphone: _audioDb,
        magnetic: _magnetic,
      ),
    );
    if (_investigationSamples.length > 21600) {
      _investigationSamples.removeAt(0);
    }
    _lastInvestigationSampleAt = timestamp;
  }

  bool _hasProminentTone(double base) {
    final sampleRate = 44100.0;
    for (var harmonic = 1; harmonic <= 5; harmonic++) {
      final target = base * harmonic;
      if (target >= sampleRate / 2) continue;
      final power = _goertzelPower(target, sampleRate);
      final lower = _goertzelPower(math.max(1, target - 7), sampleRate);
      final upper = _goertzelPower(target + 7, sampleRate);
      if (power > (lower + upper) * 8) return true;
    }
    return false;
  }

  double _goertzelPower(double target, double sampleRate) {
    final coefficient = 2 * math.cos(2 * math.pi * target / sampleRate);
    var previous = 0.0;
    var previousPrevious = 0.0;
    for (final sample in _sampleWindow) {
      final current = sample + coefficient * previous - previousPrevious;
      previousPrevious = previous;
      previous = current;
    }
    return previous * previous +
        previousPrevious * previousPrevious -
        coefficient * previous * previousPrevious;
  }

  void _beginCalibration() {
    if (!_recording || _audioDb == null) {
      _showMessage(
        'Avvia il microfono prima di calibrare l’ambiente.',
        error: true,
      );
      return;
    }
    _audioPowers.clear();
    _magneticReadings.clear();
    _calibrationStartedAt = DateTime.now();
    _calibrationCompletedAt = null;
    setState(() => _calibrating = true);
    _addEvent('Calibrazione ambientale avviata (10 secondi).');
  }

  void _finishCalibration() {
    if (_audioPowers.isEmpty) {
      _calibrating = false;
      _calibrationStartedAt = null;
      _showMessage(
        'Calibrazione fallita: nessuna lettura audio valida.',
        error: true,
      );
      _addEvent('Calibrazione fallita: nessuna lettura audio valida.');
      return;
    }
    final meanPower =
        _audioPowers.reduce((a, b) => a + b) / _audioPowers.length;
    _audioBaseline = 10 * math.log(math.max(meanPower, 1e-24)) / math.ln10;
    _magneticBaseline = _magneticReadings.isEmpty
        ? null
        : _magneticReadings.reduce((a, b) => a + b) / _magneticReadings.length;
    _calibrating = false;
    _calibrationCompletedAt = DateTime.now();
    _completedCalibrations++;
    _addEvent(
      'Calibrazione completata: baseline audio ${_audioBaseline!.toStringAsFixed(1)} dBFS; '
      'baseline magnetica ${_magneticBaseline?.toStringAsFixed(1) ?? 'non disponibile'} µT.',
    );
    if (mounted) setState(() {});
  }

  double? get _correctedAudio =>
      calculateCorrectedAudioDb(_audioDb, _audioBaseline);

  double? get _correctedMagnetic =>
      _magnetic == null ? null : _magnetic! - (_magneticBaseline ?? 0);

  Future<void> _activateLicense() async {
    if (_hwid.isEmpty) {
      _showMessage('ID dispositivo non disponibile.', error: true);
      return;
    }
    try {
      final code = _licenseController.text.trim();
      await _licenseService.verify(code, _hwid);
      await _licenseService.saveLicense(code);
      if (!mounted) return;
      setState(() {
        _licensed = true;
        _licenseError = '';
        _message = 'Licenza verificata.';
      });
      _startMagnetometer();
    } catch (error) {
      setState(
        () => _licenseError = error.toString().replaceFirst(
          'FormatException: ',
          '',
        ),
      );
    }
  }

  Future<void> _copyHwid() async {
    await Clipboard.setData(ClipboardData(text: _hwid));
    _showMessage('ID dispositivo copiato.');
  }

  Future<void> _showFeedbackForm() async {
    var draft = '';
    try {
      final feedback = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: _surface,
          title: const Text(
            'Feedback beta 26',
            style: TextStyle(color: _signal),
          ),
          content: TextField(
            autofocus: true,
            minLines: 4,
            maxLines: 8,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (value) => draft = value,
            decoration: const InputDecoration(
              hintText: 'Descrivi un problema o suggerisci un miglioramento',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Annulla'),
            ),
            FilledButton.icon(
              onPressed: () {
                final message = draft.trim();
                if (message.isNotEmpty) Navigator.pop(dialogContext, message);
              },
              icon: const Icon(Icons.share),
              label: const Text('Condividi feedback'),
            ),
          ],
        ),
      );
      if (feedback == null || feedback.isEmpty || !mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          title: 'Feedback Frequenze Digitali',
          subject: 'Feedback Frequenze Digitali - $_betaVersionLabel',
          text:
              'Feedback per Frequenze Digitali $_betaVersionLabel:\n\n'
              '$feedback\n\n'
              'Il feedback non include automaticamente dati dei sensori o '
              'report delle sessioni.',
        ),
      );
    } catch (error) {
      _showMessage('Impossibile condividere il feedback: $error', error: true);
    }
  }

  Future<void> _exportInvestigationPdf() async {
    if (_investigationSamples.isEmpty && _events.isEmpty) {
      _showMessage('Non ci sono ancora dati da inserire nel report.');
      return;
    }

    try {
      final samples = List<_InvestigationSample>.of(_investigationSamples);
      final events = List<_TelemetryEvent>.of(_events);
      String statistics(
        String label,
        Iterable<double?> measurements,
        String unit,
      ) {
        final values = measurements.whereType<double>().toList();
        if (values.isEmpty) return '$label: nessun dato disponibile';
        final average = values.reduce((a, b) => a + b) / values.length;
        final minimum = values.reduce(math.min);
        final maximum = values.reduce(math.max);
        return '$label: media ${average.toStringAsFixed(2)} $unit; '
            'min ${minimum.toStringAsFixed(2)} $unit; '
            'max ${maximum.toStringAsFixed(2)} $unit '
            '(n=${values.length})';
      }

      final pdf = pw.Document();
      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          build: (context) => [
            pw.Text(
              'Frequenze Digitali - Report indagine',
              style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 8),
            pw.Text('Generato: ${DateTime.now().toLocal()}'),
            pw.Text('Campioni raccolti in questa sessione: ${samples.length}'),
            if (samples.isNotEmpty)
              pw.Text(
                'Intervallo: ${samples.first.timestamp.toLocal()} - '
                '${samples.last.timestamp.toLocal()}',
              ),
            pw.SizedBox(height: 14),
            pw.Text(
              'Statistiche dei sensori',
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 6),
            pw.Text(
              statistics(
                'Frequenza derivata da Lorenz',
                samples.map((sample) => sample.frequency),
                'Hz',
              ),
            ),
            pw.Text(
              statistics(
                'Livello microfono',
                samples.map((sample) => sample.microphone),
                'dBFS',
              ),
            ),
            pw.Text(
              statistics(
                'Campo magnetico',
                samples.map((sample) => sample.magnetic),
                'uT',
              ),
            ),
            pw.SizedBox(height: 14),
            pw.Text(
              'Riepilogo indagine',
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            ),
            pw.Text('Eventi registrati: ${events.length}'),
            pw.Text('Calibrazioni completate: $_completedCalibrations'),
            pw.Text(
              'Episodi con componente a 50/60 Hz rilevata: $_mainsEpisodes',
            ),
            pw.SizedBox(height: 14),
            pw.Text(
              'Registro eventi recenti',
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 6),
            if (events.isEmpty)
              pw.Text('Nessun evento registrato.')
            else
              ...events
                  .take(30)
                  .map(
                    (event) => pw.Padding(
                      padding: const pw.EdgeInsets.only(bottom: 4),
                      child: pw.Text(
                        '${event.timestamp.toLocal()}  ${event.message}',
                        style: const pw.TextStyle(fontSize: 9),
                      ),
                    ),
                  ),
            pw.SizedBox(height: 14),
            pw.Text(
              'Nota: la frequenza e derivata dal modello matematico di Lorenz. '
              'Il report riassume le letture disponibili sul dispositivo e '
              'non costituisce una diagnosi o una perizia. I campioni sono '
              'conservati in memoria solo per la sessione corrente.',
              style: const pw.TextStyle(fontSize: 9),
            ),
          ],
        ),
      );
      await SharePlus.instance.share(
        ShareParams(
          title: 'Report statistiche indagine',
          files: [
            XFile.fromData(await pdf.save(), mimeType: 'application/pdf'),
          ],
          fileNameOverrides: ['frequenze-digitali-report-indagine.pdf'],
        ),
      );
    } catch (error) {
      _showMessage(
        'Creazione del report PDF non riuscita: $error',
        error: true,
      );
    }
  }

  void _addEvent(String message) {
    _events.insert(
      0,
      _TelemetryEvent(timestamp: DateTime.now(), message: message),
    );
    if (_events.length > 500) _events.removeLast();
  }

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? _danger : _surface,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: _licensed && !_loading
          ? _buildSignalNavigation()
          : null,
      appBar: AppBar(
        backgroundColor: _background,
        titleSpacing: 16,
        title: Row(
          children: [
            Image.asset('assets/lorenz-circle.png', width: 38, height: 38),
            const SizedBox(width: 10),
            const Flexible(
              child: Text(
                'Frequenze Digitali',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _signal,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: _signal),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Text(
                  '26 BETA',
                  style: TextStyle(
                    color: _signal,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Center(
              child: Text(
                _formatClock(DateTime.now()),
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Informazioni scientifiche',
            icon: const Icon(Icons.info_outline),
            onPressed: _showScientificInfo,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _signal))
          : _licensed
          ? _buildDashboard()
          : _buildLicenseGate(),
    );
  }

  String _formatClock(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}';

  Widget _buildLicenseGate() {
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: _Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'ATTIVAZIONE',
                    style: TextStyle(color: _accent, letterSpacing: 1.5),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Attiva il dispositivo',
                    style: TextStyle(color: _signal, fontSize: 23),
                  ),
                  const SizedBox(height: 8),
                  Text(_message, style: const TextStyle(color: _muted)),
                  const SizedBox(height: 20),
                  const Text(
                    'ID DEL DISPOSITIVO',
                    style: TextStyle(color: _muted, fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          _hwid.isEmpty ? 'Non disponibile' : _hwid,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            color: _signal,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: _hwid.isEmpty ? null : _copyHwid,
                        icon: const Icon(Icons.copy),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _licenseController,
                    minLines: 3,
                    maxLines: 5,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Codice alfanumerico licenza',
                      hintText: 'Incolla il codice generato da keydigitale',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (_licenseError.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(_licenseError, style: const TextStyle(color: _danger)),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _hwid.isEmpty ? null : _activateLicense,
                      icon: const Icon(Icons.verified_outlined),
                      label: const Text('Verifica licenza'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Apri keydigitale sul PC, inserisci l’ID qui sopra, genera il codice e trasferiscilo su questo telefono.',
                    style: TextStyle(color: _muted, height: 1.5),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSignalPlot() {
    if (_signalView == _SignalView.frequency) {
      return CustomPaint(
        painter: _LineChartPainter(_frequencyHistory, color: _signal),
        child: const SizedBox.expand(),
      );
    }

    if (!_recording) {
      return const _PlotMessage(
        'Avvia il microfono per visualizzare il segnale audio.',
      );
    }

    if (_audioDb == null || _audioDb! <= -120) {
      return const _PlotMessage(
        'Microfono attivo, ma non arrivano campioni audio utili. '
        'Controlla l’ingresso del simulatore o prova su un telefono.',
      );
    }

    if (_signalView == _SignalView.waveform) {
      if (_sampleWindow.length < 2) {
        return const _PlotMessage('In attesa dei campioni audio…');
      }
      return CustomPaint(
        painter: _WaveformPainter(_sampleWindow),
        child: const SizedBox.expand(),
      );
    }

    if (_spectrogramHistory.isEmpty) {
      return const _PlotMessage('In attesa dei campioni audio…');
    }
    return CustomPaint(
      painter: _SpectrogramPainter(_spectrogramHistory),
      child: const SizedBox.expand(),
    );
  }

  Widget _signalViewButton(_SignalView view, String label) {
    final selected = _signalView == view;
    return OutlinedButton(
      onPressed: () => setState(() => _signalView = view),
      style: OutlinedButton.styleFrom(
        foregroundColor: selected ? _background : _muted,
        backgroundColor: selected ? _signal : Colors.transparent,
        side: BorderSide(color: selected ? _signal : _line),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        minimumSize: const Size(0, 44),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        textStyle: const TextStyle(fontSize: 10),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      ),
      child: Text(label, textAlign: TextAlign.center, maxLines: 2),
    );
  }

  Widget _buildSignalNavigation() => SafeArea(
    top: false,
    child: Container(
      decoration: const BoxDecoration(
        color: _surface,
        border: Border(top: BorderSide(color: _line)),
      ),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Row(
        children: [
          for (final entry in const [
            (_SignalView.frequency, 'Frequenza nel tempo'),
            (_SignalView.waveform, 'Forma d’onda'),
            (_SignalView.spectrum, 'Spettrogramma'),
          ])
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: _signalViewButton(entry.$1, entry.$2),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _buildDashboard() {
    final size = MediaQuery.sizeOf(context);
    final columns = size.width > 700 ? 3 : 2;
    final correctedAudio = _correctedAudio;
    final correctedMagnetic = _correctedMagnetic;
    final magneticDisplay = correctedMagnetic == null
        ? '--'
        : (correctedMagnetic.abs() < 0.05 ? 0 : correctedMagnetic)
              .toStringAsFixed(1);
    final calibrationText = _calibrating
        ? 'Calibrazione: ${math.max(0, 10 - DateTime.now().difference(_calibrationStartedAt!).inSeconds)} s'
        : _calibrationCompletedAt == null
        ? 'Calibrazione non eseguita'
        : 'Calibrata ${_calibrationCompletedAt!.toLocal().toString().substring(11, 19)}';
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.sensors, color: _signal, size: 18),
                    const SizedBox(width: 8),
                    const Text(
                      'TELEMETRIA DEL DISPOSITIVO',
                      style: TextStyle(color: _signal, letterSpacing: 1),
                    ),
                    const Spacer(),
                    Text(
                      _recording ? 'MICROFONO ATTIVO' : 'IN ATTESA',
                      style: TextStyle(
                        color: _recording ? _signal : _muted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Modello Lorenz · frequenza derivata',
                        style: TextStyle(color: _muted),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            _frequency.toStringAsFixed(1),
                            style: const TextStyle(
                              color: _signal,
                              fontSize: 42,
                              fontWeight: FontWeight.w700,
                              height: 1,
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.only(left: 7, bottom: 4),
                            child: Text('Hz', style: TextStyle(color: _muted)),
                          ),
                          const Spacer(),
                          Text(
                            'X ${_x.toStringAsFixed(1)}\nY ${_y.toStringAsFixed(1)}\nZ ${_z.toStringAsFixed(1)}',
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              color: _muted,
                              fontFamily: 'monospace',
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'Monitor segnale',
                        style: TextStyle(
                          color: _signal,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(switch (_signalView) {
                        _SignalView.frequency =>
                          'Frequenza nel tempo · modello Lorenz',
                        _SignalView.waveform =>
                          'Forma d’onda audio · campioni microfono',
                        _SignalView.spectrum =>
                          'Spettrogramma audio · FFT (frequenza verticale)',
                      }, style: const TextStyle(color: _muted, fontSize: 10)),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: _signalView == _SignalView.spectrum ? 190 : 120,
                        child: _buildSignalPlot(),
                      ),
                      if (_signalView != _SignalView.spectrum)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _signalView == _SignalView.waveform
                                    ? '0 s'
                                    : '30 s fa',
                                style: const TextStyle(
                                  color: _muted,
                                  fontSize: 10,
                                ),
                              ),
                              Text(
                                _signalView == _SignalView.waveform
                                    ? '23 ms'
                                    : 'Adesso · ${_formatClock(DateTime.now())}',
                                style: const TextStyle(
                                  color: _muted,
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ),
                        ),
                      Text(switch (_signalView) {
                        _SignalView.frequency =>
                          'Valore matematico del modello; non è una frequenza ambientale misurata.',
                        _SignalView.waveform =>
                          'Campioni audio acquisiti dal microfono in una finestra di circa 23 ms.',
                        _SignalView.spectrum =>
                          'Picchi verdi: normale. Picchi rossi: anomalia persistente a 50/60 Hz.',
                      }, style: const TextStyle(color: _muted, fontSize: 11)),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                GridView.count(
                  crossAxisCount: columns,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  childAspectRatio: size.width > 420 ? 1.35 : 1.1,
                  children: [
                    _MetricCard(
                      title: 'Microfono RMS',
                      value: correctedAudio?.toStringAsFixed(1) ?? '--',
                      unit: _audioBaseline == null
                          ? 'dBFS · grezzo'
                          : 'dBFS · corretto',
                      origin: _audioDb == null
                          ? 'Non disponibile'
                          : _audioBaseline != null && correctedAudio == null
                          ? 'Sotto baseline'
                          : 'Misurato',
                      icon: Icons.mic_none,
                    ),
                    _MetricCard(
                      title: 'Campo magnetico',
                      value: magneticDisplay,
                      unit: 'µT',
                      origin: _magneticAvailable
                          ? 'Misurato'
                          : 'Sensore non disponibile',
                      icon: Icons.explore_outlined,
                    ),
                    _MetricCard(
                      title: 'Baseline audio',
                      value: _audioBaseline?.toStringAsFixed(1) ?? '--',
                      unit: 'dBFS · 10 s',
                      origin: _audioBaseline == null
                          ? 'Non calibrato'
                          : 'Calibrato',
                      icon: Icons.tune,
                    ),
                    _MetricCard(
                      title: 'Baseline magnetica',
                      value: _magneticBaseline?.toStringAsFixed(1) ?? '--',
                      unit: 'µT',
                      origin: _magneticBaseline == null
                          ? 'Non disponibile'
                          : 'Calibrato',
                      icon: Icons.waves,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Segnale microfono',
                              style: TextStyle(
                                color: _signal,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Text(
                            _audioDb == null
                                ? '-- dBFS'
                                : '${_audioDb!.toStringAsFixed(1)} dBFS',
                            style: const TextStyle(color: _muted),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 80,
                        child: CustomPaint(
                          painter: _LineChartPainter(
                            _audioHistory,
                            color: _accent,
                          ),
                          child: const SizedBox.expand(),
                        ),
                      ),
                      if (_mainsDetected) ...[
                        const SizedBox(height: 10),
                        const Text(
                          'Componente a 50/60 Hz rilevata; verifica la misura.',
                          style: TextStyle(color: _muted),
                        ),
                      ],
                      if (_sensorError.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          _sensorError,
                          style: const TextStyle(color: _accent, fontSize: 12),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _toggleMicrophone,
                            icon: Icon(_recording ? Icons.stop : Icons.mic),
                            label: Text(
                              _recording
                                  ? 'Ferma microfono'
                                  : 'Avvia microfono',
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: _recording && !_calibrating
                                ? _beginCalibration
                                : null,
                            icon: const Icon(Icons.balance),
                            label: const Text('Calibra · 10 s'),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Bip per anomalie',
                                  style: TextStyle(color: _muted, fontSize: 13),
                                ),
                                Text(
                                  'Bip per interferenze persistenti a 50/60 Hz',
                                  style: TextStyle(color: _muted, fontSize: 10),
                                ),
                              ],
                            ),
                          ),
                          Switch.adaptive(
                            value: _soundAlertsEnabled,
                            onChanged: _setSoundAlertsEnabled,
                          ),
                        ],
                      ),
                      if (_soundAlertsEnabled)
                        Row(
                          children: [
                            const Icon(
                              Icons.volume_down,
                              color: _muted,
                              size: 20,
                            ),
                            Expanded(
                              child: Slider(
                                min: 10,
                                max: 100,
                                divisions: 18,
                                value: _soundAlertVolume.clamp(10, 100),
                                label: '${_soundAlertVolume.round()}%',
                                onChanged: (value) =>
                                    setState(() => _soundAlertVolume = value),
                                onChangeEnd: _saveSoundAlertVolume,
                              ),
                            ),
                            Text(
                              '${_soundAlertVolume.round()}%',
                              style: const TextStyle(
                                color: _muted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      if (!_recording)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text(
                            'Avvia il microfono per abilitare la calibrazione e le viste audio.',
                            style: TextStyle(color: _muted, fontSize: 11),
                          ),
                        ),
                      if (_calibrating) ...[
                        const SizedBox(height: 10),
                        LinearProgressIndicator(
                          value:
                              (DateTime.now()
                                          .difference(_calibrationStartedAt!)
                                          .inMilliseconds /
                                      10000)
                                  .clamp(0, 1),
                          color: _signal,
                          backgroundColor: _line,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          calibrationText,
                          style: const TextStyle(color: _accent, fontSize: 12),
                        ),
                      ] else
                        Padding(
                          padding: const EdgeInsets.only(top: 9),
                          child: Text(
                            calibrationText,
                            style: const TextStyle(color: _muted, fontSize: 12),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Report finale indagine',
                              style: TextStyle(
                                color: _signal,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          FilledButton.icon(
                            onPressed: _exportInvestigationPdf,
                            icon: const Icon(Icons.picture_as_pdf, size: 18),
                            label: const Text('Crea PDF'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Il report raccoglie le statistiche della sessione e '
                        'gli eventuali eventi rilevati. I dati restano in '
                        'memoria fino alla chiusura dell’app.',
                        style: TextStyle(color: _muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Frequenza e attrattore sono derivati dal modello di Lorenz. Microfono e magnetometro sono letture fisiche solo quando il rispettivo sensore è disponibile.',
                  style: TextStyle(color: _muted, fontSize: 11, height: 1.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showScientificInfo() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _surface,
        title: const Text(
          'Informazioni scientifiche · $_betaVersionLabel',
          style: TextStyle(color: _signal),
        ),
        content: const SingleChildScrollView(
          child: Text(
            'Frequenze Digitali è uno strumento di telemetria e analisi. Il microfono e il magnetometro forniscono misure dirette quando l’hardware è disponibile. Frequenza e attrattore sono derivati dal modello matematico di Lorenz, non sono frequenze ambientali. La calibrazione audio stima il livello medio su 10 secondi. L’esportazione usa un hash SHA-256 per controllare l’integrità: non è una firma digitale.',
            style: TextStyle(color: _muted, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              unawaited(_showFeedbackForm());
            },
            child: const Text('Invia feedback'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Chiudi'),
          ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: _surface,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(16),
    ),
    child: child,
  );
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.title,
    required this.value,
    required this.unit,
    required this.origin,
    required this.icon,
  });

  final String title;
  final String value;
  final String unit;
  final String origin;
  final IconData icon;

  @override
  Widget build(BuildContext context) => _Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: _accent, size: 19),
        const SizedBox(height: 7),
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: _muted, fontSize: 11),
        ),
        const Spacer(),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: _signal,
            fontSize: 25,
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(
          unit,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: _muted, fontSize: 10),
        ),
        const SizedBox(height: 3),
        Text(
          origin,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: _accent, fontSize: 9),
        ),
      ],
    ),
  );
}

class _PlotMessage extends StatelessWidget {
  const _PlotMessage(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: _background,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: _muted, fontSize: 12),
        ),
      ),
    ),
  );
}

class _LineChartPainter extends CustomPainter {
  const _LineChartPainter(this.values, {required this.color});

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = _line
      ..strokeWidth = 1;
    for (var row = 1; row < 4; row++) {
      final y = size.height * row / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (values.length < 2) return;
    final minimum = values.reduce(math.min);
    final maximum = values.reduce(math.max);
    final range = math.max(maximum - minimum, 1e-6);
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final point = Offset(
        size.width * i / (values.length - 1),
        size.height -
            ((values[i] - minimum) / range) * size.height * 0.85 -
            size.height * 0.075,
      );
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter oldDelegate) => true;
}

class _WaveformPainter extends CustomPainter {
  const _WaveformPainter(this.samples);

  final List<double> samples;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = _line
      ..strokeWidth = 1;
    final center = size.height / 2;
    canvas.drawLine(Offset(0, center), Offset(size.width, center), grid);
    canvas.drawLine(
      Offset(0, size.height * 0.1),
      Offset(size.width, size.height * 0.1),
      grid,
    );
    canvas.drawLine(
      Offset(0, size.height * 0.9),
      Offset(size.width, size.height * 0.9),
      grid,
    );
    if (samples.length < 2) return;

    const visibleSamples = 1024;
    final start = math.max(0, samples.length - visibleSamples);
    final count = samples.length - start;
    final path = Path();
    for (var i = 0; i < count; i++) {
      final point = Offset(
        size.width * i / (count - 1),
        center - samples[start + i].clamp(-1, 1) * size.height * 0.45,
      );
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = _signal
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) => true;
}

class _SpectrogramPainter extends CustomPainter {
  const _SpectrogramPainter(this.columns);

  final List<_SpectrogramFrame> columns;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = Offset.zero & size;
    final framePaint = Paint()..color = const Color(0xFF0A101B);
    canvas.drawRRect(
      RRect.fromRectAndRadius(frame, const Radius.circular(8)),
      framePaint,
    );
    if (columns.isEmpty || size.width < 80 || size.height < 80) return;

    const left = 43.0;
    const right = 8.0;
    const top = 23.0;
    const bottom = 23.0;
    final plot = Rect.fromLTRB(
      left,
      top,
      size.width - right,
      size.height - bottom,
    );
    if (plot.width <= 0 || plot.height <= 0) return;

    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(frame, const Radius.circular(8)));
    canvas.drawRect(plot, Paint()..color = const Color(0xFF101827));

    final binCount = columns.last.values.length;
    if (binCount == 0) {
      canvas.restore();
      return;
    }
    final columnWidth = plot.width / columns.length;
    final binHeight = plot.height / binCount;
    final paint = Paint();
    for (var column = 0; column < columns.length; column++) {
      final frame = columns[column];
      final values = frame.values;
      for (var bin = 0; bin < values.length; bin++) {
        final intensity = values[bin].clamp(0, 1).toDouble();
        paint.color = frame.anomaly && _isSpectralPeak(values, bin)
            ? const Color(0xFFFF3B45)
            : _spectrogramColor(intensity);
        final row = values.length - bin - 1;
        canvas.drawRect(
          Rect.fromLTWH(
            plot.left + column * columnWidth,
            plot.top + row * binHeight,
            columnWidth + 0.4,
            binHeight + 0.4,
          ),
          paint,
        );
      }
    }

    final grid = Paint()
      ..color = const Color(0x663D5068)
      ..strokeWidth = 0.7;
    const frequencyLabels = ['22 kHz', '16.5 kHz', '11 kHz', '5.5 kHz', '0'];
    for (var tick = 0; tick < frequencyLabels.length; tick++) {
      final fraction = tick / (frequencyLabels.length - 1);
      final y = plot.top + plot.height * fraction;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      _drawSpectrogramLabel(
        canvas,
        frequencyLabels[tick],
        Offset(4, y - 5),
        width: left - 9,
        align: TextAlign.right,
      );
    }

    final durationSeconds = columns.length * 4096 / 44100;
    for (var tick = 0; tick <= 3; tick++) {
      final fraction = tick / 3;
      final x = plot.left + plot.width * fraction;
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), grid);
      final elapsed = durationSeconds * (1 - fraction);
      final label = tick == 3 ? 'ora' : '-${elapsed.toStringAsFixed(1)} s';
      _drawSpectrogramLabel(
        canvas,
        label,
        Offset(
          tick == 0
              ? x
              : tick == 3
              ? x - 42
              : x - 24,
          plot.bottom + 5,
        ),
        width: tick == 0
            ? 48
            : tick == 3
            ? 42
            : 48,
        align: tick == 0
            ? TextAlign.left
            : tick == 3
            ? TextAlign.right
            : TextAlign.center,
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(plot, const Radius.circular(2)),
      Paint()
        ..color = const Color(0x806A7B91)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8,
    );
    canvas.restore();

    _drawSpectrogramLabel(
      canvas,
      'dBFS',
      Offset(left, 4),
      width: 34,
      fontSize: 8,
      color: _muted,
    );
    final legendWidth = math.min(52.0, size.width * 0.17);
    final legendLeft = size.width - right - legendWidth - 56;
    _drawSpectrogramLabel(
      canvas,
      '-90',
      Offset(legendLeft, 4),
      width: 22,
      fontSize: 8,
      color: _muted,
    );
    final legend = Rect.fromLTWH(legendLeft + 24, 6, legendWidth, 6);
    for (var i = 0; i < 24; i++) {
      final fraction = i / 23;
      canvas.drawRect(
        Rect.fromLTWH(
          legend.left + legend.width * i / 24,
          legend.top,
          legend.width / 24 + 0.3,
          legend.height,
        ),
        Paint()..color = _spectrogramColor(fraction),
      );
    }
    _drawSpectrogramLabel(
      canvas,
      '0',
      Offset(legend.right + 3, 4),
      width: 12,
      fontSize: 8,
      color: _muted,
    );
  }

  Color _spectrogramColor(double value) {
    const stops = [
      Color(0xFF101827),
      Color(0xFF164B3A),
      Color(0xFF00A85A),
      Color(0xFF7CFF6B),
    ];
    final scaled = value.clamp(0, 1) * (stops.length - 1);
    final lower = scaled.floor();
    if (lower >= stops.length - 1) return stops.last;
    return Color.lerp(
      stops[lower],
      stops[lower + 1],
      scaled - lower.toDouble(),
    )!;
  }

  bool _isSpectralPeak(List<double> values, int index) {
    final value = values[index];
    if (value < 0.25) return false;
    final left = index == 0 ? -1.0 : values[index - 1];
    final right = index == values.length - 1 ? -1.0 : values[index + 1];
    return value >= left && value >= right && (value > left || value > right);
  }

  void _drawSpectrogramLabel(
    Canvas canvas,
    String text,
    Offset offset, {
    required double width,
    TextAlign align = TextAlign.left,
    double fontSize = 9,
    Color color = _muted,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: align,
      maxLines: 1,
    )..layout(maxWidth: width);
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _SpectrogramPainter oldDelegate) => true;
}

class _SpectrogramFrame {
  const _SpectrogramFrame(this.values, {required this.anomaly});

  final List<double> values;
  final bool anomaly;
}

class _InvestigationSample {
  const _InvestigationSample({
    required this.timestamp,
    required this.frequency,
    required this.microphone,
    required this.magnetic,
  });

  final DateTime timestamp;
  final double frequency;
  final double? microphone;
  final double? magnetic;
}

class _TelemetryEvent {
  const _TelemetryEvent({required this.timestamp, required this.message});

  final DateTime timestamp;
  final String message;
}
