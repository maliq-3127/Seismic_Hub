import 'dart:async';
import 'dart:math' as math;

enum DetectorState { calibrating, idle, measuring, settling }

class DisturbanceResult {
  final double angleDegrees; // 0 to 360
  final Duration resetTime;
  final double estimatedSpeedMps;
  final int preciseTimestampUs;

  DisturbanceResult({
    required this.angleDegrees,
    required this.resetTime,
    required this.estimatedSpeedMps,
    required this.preciseTimestampUs,
  });
}

class DisturbanceDetector {
  DetectorState _state = DetectorState.calibrating;
  DetectorState get state => _state;

  // 4. Manual Overrides
  double sensitivityMultiplier = 1.0; 
  double speedMultiplier = 1.0;       

  double _triggerThreshold = 0.5;
  double _resetThreshold = 0.05;
  double get triggerThreshold => _triggerThreshold * (1.0 / sensitivityMultiplier);

  final int _calibrationDurationMs = 3000;
  final List<double> _calibrationSamples = [];
  DateTime? _calibrationStartTime;

  double _filteredX = 0.0;
  double _filteredY = 0.0;
  final double _lpfAlpha = 0.3; 

  final Stopwatch _stopwatch = Stopwatch();
  double _peakMagnitude = 0.0;
  double _lockedAngle = 0.0;
  Timer? _settlingTimer;
  int _preciseTriggerTimeUs = 0;

  // Streams
  final _resultController = StreamController<DisturbanceResult>.broadcast();
  Stream<DisturbanceResult> get onDisturbanceDetected => _resultController.stream;

  final _calibrationController = StreamController<double>.broadcast();
  Stream<double> get onCalibrationProgress => _calibrationController.stream;

  // 3. Real-Time Wave Stream for instant UI feedback
  final _waveController = StreamController<double>.broadcast();
  Stream<double> get onLiveWave => _waveController.stream;

  void processGyroscopeData(double rawX, double rawY) {
    _filteredX = (_lpfAlpha * rawX) + ((1.0 - _lpfAlpha) * _filteredX);
    _filteredY = (_lpfAlpha * rawY) + ((1.0 - _lpfAlpha) * _filteredY);

    // 1. Calculate 360-degree magnitude (Pythagorean)
    double magnitude = math.sqrt((_filteredX * _filteredX) + (_filteredY * _filteredY));
    
    // Broadcast live wave for real-time graphs
    _waveController.add(magnitude);

    final now = DateTime.now();
    final timestampUs = now.microsecondsSinceEpoch;
    double currentThreshold = _triggerThreshold * (1.0 / sensitivityMultiplier);

    switch (_state) {
      case DetectorState.calibrating:
        _handleCalibration(magnitude, now);
        break;

      case DetectorState.idle:
        if (magnitude > currentThreshold) {
          _state = DetectorState.measuring;
          _preciseTriggerTimeUs = timestampUs;
          _peakMagnitude = magnitude;
          
          // Calculate 360-degree vector of the impact
          _lockedAngle = math.atan2(_filteredY, _filteredX) * (180 / math.pi);
          if (_lockedAngle < 0) _lockedAngle += 360;

          _stopwatch.reset();
          _stopwatch.start();
        }
        break;

      case DetectorState.measuring:
      case DetectorState.settling:
        if (magnitude > _peakMagnitude) {
          _peakMagnitude = magnitude;
        }

        if (magnitude < _resetThreshold) {
          if (_state != DetectorState.settling) {
            _state = DetectorState.settling;
            _settlingTimer = Timer(const Duration(milliseconds: 150), _finalizeMeasurement);
          }
        } else {
          _state = DetectorState.measuring;
          _settlingTimer?.cancel();
          _settlingTimer = null;
        }
        break;
    }
  }

  void _handleCalibration(double magnitude, DateTime now) {
    _calibrationStartTime ??= now;
    _calibrationSamples.add(magnitude);

    final elapsed = now.difference(_calibrationStartTime!).inMilliseconds;
    _calibrationController.add((elapsed / _calibrationDurationMs).clamp(0.0, 1.0));

    if (elapsed >= _calibrationDurationMs) {
      double mean = _calibrationSamples.reduce((a, b) => a + b) / _calibrationSamples.length;
      double varianceSum = _calibrationSamples
          .map((v) => math.pow(v - mean, 2))
          .reduce((a, b) => a + b)
          .toDouble();
      double stdDev = math.sqrt(varianceSum / _calibrationSamples.length);

      _triggerThreshold = math.max(0.3, mean + (5.0 * stdDev));
      _resetThreshold = math.max(0.05, mean + (1.5 * stdDev));

      _state = DetectorState.idle;
      _calibrationStartTime = null;
      _calibrationSamples.clear();
    }
  }

  void _finalizeMeasurement() {
    _stopwatch.stop();
    _settlingTimer?.cancel();
    _settlingTimer = null;

    int totalMs = _stopwatch.elapsedMilliseconds - 150;
    Duration trueResetTime = Duration(milliseconds: math.max(0, totalMs));

    double tSeconds = trueResetTime.inMilliseconds / 1000.0;
    double estimatedSpeed = 0.05 * math.exp(3.5 * tSeconds) * speedMultiplier;

    _resultController.add(DisturbanceResult(
      angleDegrees: _lockedAngle,
      resetTime: trueResetTime,
      estimatedSpeedMps: estimatedSpeed.clamp(0.1, 50.0),
      preciseTimestampUs: _preciseTriggerTimeUs,
    ));

    _state = DetectorState.idle;
    _peakMagnitude = 0.0;
  }

  void forceRecalibration() => _state = DetectorState.calibrating;

  void dispose() {
    _settlingTimer?.cancel();
    _resultController.close();
    _calibrationController.close();
    _waveController.close();
  }
}