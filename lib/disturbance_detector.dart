import 'dart:async';
import 'dart:math' as math;

enum DetectorState { calibrating, active }

class DisturbanceResult {
  final double angleDegrees;
  final double estimatedSpeedMps;
  final Duration resetTime;
  final int preciseTimestampUs;

  DisturbanceResult({
    required this.angleDegrees,
    required this.estimatedSpeedMps,
    required this.resetTime,
    required this.preciseTimestampUs,
  });
}

class DisturbanceDetector {
  double sensitivityMultiplier = 1.0;
  DetectorState state = DetectorState.calibrating;

  // Streams
  final _calibrationController = StreamController<double>.broadcast();
  Stream<double> get onCalibrationProgress => _calibrationController.stream;

  final _waveController = StreamController<double>.broadcast();
  Stream<double> get onLiveWave => _waveController.stream;

  final _disturbanceController = StreamController<DisturbanceResult>.broadcast();
  Stream<DisturbanceResult> get onDisturbanceDetected => _disturbanceController.stream;

  // High-Pass Filter (HPF) State Variables
  double _prevX = 0.0;
  double _prevY = 0.0;
  double _filteredX = 0.0;
  double _filteredY = 0.0;
  // Alpha for High-Pass (removes gradual device tilting/drift) - Changed to mutable for Hub configuration
  double hpfAlpha = 0.9; 

  // STA/LTA (Short-Term / Long-Term Average) State
  double _staEnergy = 0.0;
  double _ltaEnergy = 0.0;
  
  // Tuned EMA Constants for a ~50Hz sampling rate
  final double _staAlpha = 0.077; // Responds to changes over ~0.5 seconds
  final double _ltaAlpha = 0.004; // Tracks ambient room noise over ~10 seconds
  
  // The baseline spike ratio required to trigger a seismic event
  final double _baseTriggerRatio = 4.0; 

  // Calibration Tracking
  int _sampleCount = 0;
  final int _calibrationSamplesRequired = 250; // 5 seconds at 50Hz

  // Cooldown timer to prevent Firebase spamming during a long vibration
  int _lastTriggerTimeMs = 0;
  final int _cooldownMs = 3000;

  // Accumulation State Variables
  int _accumulationCount = 0;
  double _accX = 0.0;
  double _accY = 0.0;
  bool _isAccumulating = false;

  void processGyroscopeData(double x, double y) {
    // 1. High-Pass Filter (O(1) operation)
    // Isolates sudden jolts by subtracting the slow-moving difference
    _filteredX = hpfAlpha * (_filteredX + x - _prevX);
    _filteredY = hpfAlpha * (_filteredY + y - _prevY);
    _prevX = x;
    _prevY = y;

    // 2. Kinetic Energy Calculation
    // We use squared values to heavily penalize large spikes and ignore micro-vibrations
    double currentEnergy = (_filteredX * _filteredX) + (_filteredY * _filteredY);
    double magnitude = math.sqrt(currentEnergy);

    // Send the raw filtered wave out to the Hub UI
    _waveController.add(magnitude);

    // 3. Update STA/LTA (O(1) operation)
    // No arrays, loops, or buffer shifting required
    _staEnergy = _staAlpha * currentEnergy + (1.0 - _staAlpha) * _staEnergy;
    _ltaEnergy = _ltaAlpha * currentEnergy + (1.0 - _ltaAlpha) * _ltaEnergy;

    // 4. Handle Calibration
    if (state == DetectorState.calibrating) {
      _sampleCount++;
      _calibrationController.add(_sampleCount / _calibrationSamplesRequired);
      
      if (_sampleCount >= _calibrationSamplesRequired) {
        state = DetectorState.active;
        _calibrationController.add(1.0);
      }
      return; 
    }

    // 5. Trigger Logic
    // Prevent division-by-zero if phone is perfectly motionless
    double safeLta = math.max(_ltaEnergy, 0.00001);
    double energyRatio = _staEnergy / safeLta;

    // Apply the remote sensitivity multiplier controlled from the Hub
    double effectiveThreshold = _baseTriggerRatio / math.max(sensitivityMultiplier, 0.1);

    if (energyRatio > effectiveThreshold || _isAccumulating) {
      if (!_isAccumulating) {
        _isAccumulating = true;
        _accumulationCount = 0;
        _accX = 0.0;
        _accY = 0.0;
      }

      // Sum up vectors for 5 frames (~100ms) to stabilize the direction
      _accX += _filteredX;
      _accY += _filteredY;
      _accumulationCount++;

      if (_accumulationCount >= 5) {
        _isAccumulating = false; // Reset for next event
        int now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastTriggerTimeMs > _cooldownMs) {
          _lastTriggerTimeMs = now;
          _triggerDisturbance(_accX / 5, _accY / 5, magnitude);
        }
      }
    }
  }

  void _triggerDisturbance(double fx, double fy, double mag) {
    // Determine vector angle of the shockwave
    double angleRad = math.atan2(fy, fx);
    double angleDeg = angleRad * (180.0 / math.pi);
    if (angleDeg < 0) angleDeg += 360.0;

    // Estimate propagation speed multiplier based on sheer kinetic force
    // (Used by the Hub's spatial matching equation)
    double speed = 2500.0 + (mag * 350.0); 

    _disturbanceController.add(
      DisturbanceResult(
        angleDegrees: angleDeg,
        estimatedSpeedMps: speed,
        resetTime: Duration(milliseconds: _cooldownMs),
        preciseTimestampUs: DateTime.now().microsecondsSinceEpoch,
      )
    );
  }

  void forceRecalibration() {
    state = DetectorState.calibrating;
    _sampleCount = 0;
    _staEnergy = 0.0;
    _ltaEnergy = 0.0;
    _calibrationController.add(0.0);
  }

  void dispose() {
    _calibrationController.close();
    _waveController.close();
    _disturbanceController.close();
  }
}