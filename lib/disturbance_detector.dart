import 'dart:async';
import 'dart:math' as math;

enum DetectorState { calibrating, active }

class DisturbanceResult {
  final double angleDegrees;
  final double estimatedSpeedMps;
  final Duration resetTime;
  final int preciseTimestampUs;
  final bool used3Axis;

  DisturbanceResult({
    required this.angleDegrees,
    required this.estimatedSpeedMps,
    required this.resetTime,
    required this.preciseTimestampUs,
    required this.used3Axis,
  });
}

class DisturbanceDetector {
  double sensitivityMultiplier = 1.0;
  bool enable3Axis = false; 
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
  double _prevZ = 0.0;
  double _filteredX = 0.0;
  double _filteredY = 0.0;
  double _filteredZ = 0.0;
  double hpfAlpha = 0.9; 

  // STA/LTA State
  double _staEnergy = 0.0;
  double _ltaEnergy = 0.0;
  
  final double _staAlpha = 0.077; 
  final double _ltaAlpha = 0.004; 
  final double _baseTriggerRatio = 4.0; 

  // Calibration Tracking
  int _sampleCount = 0;
  final int _calibrationSamplesRequired = 250; 

  // Cooldown timer
  int _lastTriggerTimeMs = 0;
  final int _cooldownMs = 3000;

  // Accumulation State Variables
  int _accumulationCount = 0;
  double _accX = 0.0;
  double _accY = 0.0;
  double _accZ = 0.0;
  bool _isAccumulating = false;

  void processAccelerometerData(double x, double y, double z) {
    // 1. High-Pass Filter (O(1) operation)
    _filteredX = hpfAlpha * (_filteredX + x - _prevX);
    _filteredY = hpfAlpha * (_filteredY + y - _prevY);
    _filteredZ = hpfAlpha * (_filteredZ + z - _prevZ);
    _prevX = x;
    _prevY = y;
    _prevZ = z;

    // 2. Kinetic Energy Calculation
    double currentEnergy = (_filteredX * _filteredX) + (_filteredY * _filteredY);
    if (enable3Axis) {
       currentEnergy += (_filteredZ * _filteredZ);
    }
    double magnitude = math.sqrt(currentEnergy);

    _waveController.add(magnitude);

    // 3. Update STA/LTA
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
    double safeLta = math.max(_ltaEnergy, 0.00001);
    double energyRatio = _staEnergy / safeLta;
    double effectiveThreshold = _baseTriggerRatio / math.max(sensitivityMultiplier, 0.1);

    if (energyRatio > effectiveThreshold || _isAccumulating) {
      if (!_isAccumulating) {
        _isAccumulating = true;
        _accumulationCount = 0;
        _accX = 0.0;
        _accY = 0.0;
        _accZ = 0.0;
      }

      _accX += _filteredX;
      _accY += _filteredY;
      _accZ += _filteredZ;
      _accumulationCount++;

      if (_accumulationCount >= 5) {
        _isAccumulating = false; 
        int now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastTriggerTimeMs > _cooldownMs) {
          _lastTriggerTimeMs = now;
          _triggerDisturbance(_accX / 5, _accY / 5, _accZ / 5, magnitude);
        }
      }
    }
  }

  void _triggerDisturbance(double fx, double fy, double fz, double mag) {
    double angleRad = math.atan2(fx, fy);
    double angleDeg = angleRad * (180.0 / math.pi);

    // Apply Polarization Logic if 3-Axis is active
    if (enable3Axis) {
      // If initial motion is a compressional upward thrust (+Z), the wave is pushing outward.
      // Therefore, the vector (fx, fy) points AWAY from the epicenter. We flip it 180°.
      if (fz > 0) {
        angleDeg += 180.0;
      }
    }

    // Normalize angle
    angleDeg = angleDeg % 360.0;
    if (angleDeg < 0) angleDeg += 360.0;

    double speed = 2500.0 + (mag * 350.0); 

    _disturbanceController.add(
      DisturbanceResult(
        angleDegrees: angleDeg,
        estimatedSpeedMps: speed,
        resetTime: Duration(milliseconds: _cooldownMs),
        preciseTimestampUs: DateTime.now().microsecondsSinceEpoch,
        used3Axis: enable3Axis,
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