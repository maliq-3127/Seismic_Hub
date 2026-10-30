import 'dart:math' as math;

import '../models/seismic_models.dart';
import '../sensors/compass_orientation.dart';
import '../sensors/noise_floor_tracker.dart';
import '../sensors/surface_classifier.dart';
import 'isolate_messages.dart';

enum _NodeState { calibrating, active }

/// Stage 1 (Trigger) + Stage 2 (Phase ID) of the per-node pipeline, plus the
/// supporting systems the fixes call for: noise-floor management (#8),
/// surface classification (#1), and true-north/east azimuth (#7). Runs
/// entirely inside the node math isolate (see node_isolate_entry.dart) -
/// this class never touches a sensor plugin, a Firebase reference, or
/// anything else that only exists on the main isolate. Raw samples are
/// pushed in via the on...Sample methods; results come back out through the
/// constructor callbacks.
///
/// ARCHITECTURE.md documents the full design; the summary:
///  - Triggering is driven by the accelerometer's STA/LTA ratio (fast
///    magnitude average vs. a slow, floor-tracking average) exactly as
///    before, except the slow average now *freezes* while a trigger is in
///    progress (see NoiseFloorTracker) so a strong, sustained disturbance
///    can't drag its own reference level upward mid-event.
///  - When a trigger fires, the gyroscope's own noise floor decides phase ID
///    / channel-dominance: if the gyroscope is above its floor (or the
///    accelerometer is saturated - see below), this is a "both channels
///    usable" observation; otherwise "accelerometer-dominant".
///  - The 5-sample-averaged horizontal disturbance vector is rotated from
///    device-frame into true-north-referenced East/North via
///    CompassOrientation before the azimuth is reported.
///  - If both channels are usable, an integrated velocity estimate over the
///    same averaging window and the gyroscope's excess-over-floor magnitude
///    give an apparent-velocity *proxy* (translational / rotational rate) -
///    proportional to, not equal to, the physical apparent velocity in the
///    spec's background physics (the constant of proportionality depends on
///    wave type and isn't asserted here).
///  - A node that fires an accelerometer-dominant trigger starts watching
///    for a later both-channels trigger at the same node (the presumed
///    S/surface arrival) so the mature S-P interval can be attached to it;
///    if none arrives within the timeout, nothing is lost - single-phase
///    detections are the common case.
class NodeProcessor {
  double hpfAlpha;
  double sensitivityMultiplier;
  final double samplingPeriodSeconds;
  double magneticDeclinationDegrees;

  final void Function(double progress) onCalibrationProgress;
  final void Function(double magnitude) onLiveWave;
  final void Function(TriggerDetectedMsg trigger) onTrigger;
  final void Function(NodeStatusMsg status) onStatusChanged;

  final CompassOrientation _compass = CompassOrientation();
  final SurfaceClassifier _surface = SurfaceClassifier();
  late final NoiseFloorTracker _accelFloor;
  late final NoiseFloorTracker _gyroFloor;
  late final double _staAlpha;
  late final int _accumulationSamplesTarget;

  _NodeState _state = _NodeState.calibrating;
  int _calibrationSampleCount = 0;
  static const int _calibrationSamplesRequired = 250;

  // Accelerometer HPF state (the disturbance signal, gravity/DC removed).
  double _prevX = 0.0, _prevY = 0.0, _prevZ = 0.0;
  double _filteredX = 0.0, _filteredY = 0.0, _filteredZ = 0.0;
  double _staMagnitude = 0.0;
  static const double _baseTriggerRatio = 4.0;

  // Saturation (clipping) detection on the raw, unfiltered accelerometer.
  static const double _accelSaturationThresholdMps2 = 78.0; // ~8g; tune per device
  double? _prevRawMagnitude;
  int _repeatedExtremeCount = 0;
  bool _recentlySaturated = false;
  int _lastSaturatedSampleUs = 0;
  static const int _saturationRecentWindowUs = 500000;

  // Trigger accumulation (mirrors the original 5-sample averaging window,
  // now expressed as a duration so it stays meaningful at any sampling rate).
  bool _isAccumulating = false;
  int _accumulationCount = 0;
  double _accX = 0.0, _accY = 0.0, _accZ = 0.0;
  double _velX = 0.0, _velY = 0.0, _velZ = 0.0;
  double _gyroPeakDuringAccumulation = 0.0;

  int _lastTriggerTimeUs = 0;
  static const int _cooldownUs = 3000000;

  // P -> S/surface phase tracking (see class doc).
  bool _awaitingSecondPhase = false;
  int _firstPhaseArrivalUs = 0;
  static const int _secondPhaseTimeoutUs = 90 * 1000000;

  NodeProcessor({
    required this.hpfAlpha,
    required this.sensitivityMultiplier,
    required this.samplingPeriodSeconds,
    required this.magneticDeclinationDegrees,
    required this.onCalibrationProgress,
    required this.onLiveWave,
    required this.onTrigger,
    required this.onStatusChanged,
  }) {
    // Time-constant-derived alphas so behaviour stays consistent if the
    // configured sampling period changes (fix #3 deliberately lowers it).
    _staAlpha = _alphaForTimeConstant(0.3);
    _accelFloor = NoiseFloorTracker(alpha: _alphaForTimeConstant(5.0));
    _gyroFloor = NoiseFloorTracker(alpha: _alphaForTimeConstant(5.0));
    _accumulationSamplesTarget = math.max(1, (0.1 / samplingPeriodSeconds).round());
  }

  double _alphaForTimeConstant(double tauSeconds) {
    return 1.0 - math.exp(-samplingPeriodSeconds / tauSeconds);
  }

  void setManualSurfaceOverride(SurfaceType type) {
    _surface.manualOverride = type;
  }

  void forceRecalibration() {
    _state = _NodeState.calibrating;
    _calibrationSampleCount = 0;
    _surface.reset();
    _awaitingSecondPhase = false;
    onCalibrationProgress(0.0);
  }

  void onMagnetometerSample(int timestampUs, double x, double y, double z) {
    _compass.updateMagnetometer(x, y, z);
  }

  void onGyroscopeSample(int timestampUs, double x, double y, double z) {
    final magnitude = math.sqrt(x * x + y * y + z * z);
    _gyroFloor.update(magnitude);
    if (_isAccumulating && magnitude > _gyroPeakDuringAccumulation) {
      _gyroPeakDuringAccumulation = magnitude;
    }
  }

  void onAccelerometerSample(int timestampUs, double x, double y, double z) {
    _compass.updateAccelerometer(x, y, z);
    _checkSaturation(timestampUs, math.sqrt(x * x + y * y + z * z));

    _filteredX = hpfAlpha * (_filteredX + x - _prevX);
    _filteredY = hpfAlpha * (_filteredY + y - _prevY);
    _filteredZ = hpfAlpha * (_filteredZ + z - _prevZ);
    _prevX = x;
    _prevY = y;
    _prevZ = z;

    final filteredMag = math.sqrt(_filteredX * _filteredX + _filteredY * _filteredY + _filteredZ * _filteredZ);
    onLiveWave(filteredMag);
    _accelFloor.update(filteredMag);
    _staMagnitude += _staAlpha * (filteredMag - _staMagnitude);

    if (_state == _NodeState.calibrating) {
      _surface.accumulate(filteredMag);
      _calibrationSampleCount++;
      onCalibrationProgress(_calibrationSampleCount / _calibrationSamplesRequired);
      if (_calibrationSampleCount >= _calibrationSamplesRequired) {
        _state = _NodeState.active;
        onCalibrationProgress(1.0);
        onStatusChanged(NodeStatusMsg(_surface.classify(), null));
      }
      return;
    }

    final safeFloor = math.max(_accelFloor.floor, 1e-6);
    final ratio = _staMagnitude / safeFloor;
    final effectiveThreshold = _baseTriggerRatio / math.max(sensitivityMultiplier, 0.1);

    if (ratio > effectiveThreshold || _isAccumulating) {
      if (!_isAccumulating) {
        _isAccumulating = true;
        _accelFloor.frozen = true;
        _gyroFloor.frozen = true;
        _accumulationCount = 0;
        _accX = 0.0;
        _accY = 0.0;
        _accZ = 0.0;
        _velX = 0.0;
        _velY = 0.0;
        _velZ = 0.0;
        _gyroPeakDuringAccumulation = 0.0;
      }

      _accX += _filteredX;
      _accY += _filteredY;
      _accZ += _filteredZ;
      _velX += _filteredX * samplingPeriodSeconds;
      _velY += _filteredY * samplingPeriodSeconds;
      _velZ += _filteredZ * samplingPeriodSeconds;
      _accumulationCount++;

      if (_accumulationCount >= _accumulationSamplesTarget) {
        _isAccumulating = false;
        _accelFloor.frozen = false;
        _gyroFloor.frozen = false;
        if (timestampUs - _lastTriggerTimeUs > _cooldownUs) {
          _lastTriggerTimeUs = timestampUs;
          _emitTrigger(timestampUs);
        }
      }
    }
  }

  void _checkSaturation(int timestampUs, double rawMagnitude) {
    bool looksSaturated = rawMagnitude > _accelSaturationThresholdMps2;
    if (!looksSaturated && _prevRawMagnitude != null) {
      // Repeated near-identical extreme samples is a classic clipping
      // signature and doesn't require knowing the device's real sensor
      // range, unlike the fixed threshold above.
      if (rawMagnitude > 40.0 && (rawMagnitude - _prevRawMagnitude!).abs() < 0.01) {
        _repeatedExtremeCount++;
        if (_repeatedExtremeCount >= 3) looksSaturated = true;
      } else {
        _repeatedExtremeCount = 0;
      }
    }
    _prevRawMagnitude = rawMagnitude;

    if (looksSaturated) {
      _recentlySaturated = true;
      _lastSaturatedSampleUs = timestampUs;
    } else if (timestampUs - _lastSaturatedSampleUs > _saturationRecentWindowUs) {
      _recentlySaturated = false;
    }
  }

  void _emitTrigger(int timestampUs) {
    final avgX = _accX / _accumulationCount;
    final avgY = _accY / _accumulationCount;
    final avgZ = _accZ / _accumulationCount;

    double? azimuth;
    double? azimuthUncertainty;
    final enu = _compass.projectToEnu(avgX, avgY, avgZ);
    if (enu != null && enu.horizontalMagnitude > 1e-6) {
      azimuth = applyDeclination(enu.azimuthDegrees, magneticDeclinationDegrees);
      // Single-station polarisation/6C azimuth uncertainty is a genuine
      // unknown without field validation - see ARCHITECTURE.md. This is a
      // starting placeholder, not a measured value.
      azimuthUncertainty = 25.0;
    }

    final gyroAboveFloor = _gyroFloor.isAboveFloor(_gyroPeakDuringAccumulation);
    final effectiveBothChannels = _recentlySaturated || gyroAboveFloor;
    final channelState =
        effectiveBothChannels ? ChannelDominanceState.bothChannelsUsable : ChannelDominanceState.accelerometerDominant;

    double? apparentVelocity;
    if (effectiveBothChannels) {
      final velocityMagnitude = math.sqrt(_velX * _velX + _velY * _velY + _velZ * _velZ);
      final rotationRateExcess = math.max(_gyroPeakDuringAccumulation - _gyroFloor.floor, 1e-4);
      if (velocityMagnitude > 1e-4) {
        final candidate = velocityMagnitude / rotationRateExcess;
        // Sanity bounds - reject non-physical outliers rather than report
        // them with false confidence.
        if (candidate.isFinite && candidate > 100 && candidate < 20000) {
          apparentVelocity = candidate;
        }
      }
    }

    double? sMinusPSeconds;
    if (effectiveBothChannels) {
      if (_awaitingSecondPhase && (timestampUs - _firstPhaseArrivalUs) <= _secondPhaseTimeoutUs) {
        sMinusPSeconds = (timestampUs - _firstPhaseArrivalUs) / 1e6;
      }
      _awaitingSecondPhase = false;
    } else {
      _awaitingSecondPhase = true;
      _firstPhaseArrivalUs = timestampUs;
    }

    final surfaceType = _surface.classify();
    onStatusChanged(NodeStatusMsg(surfaceType, channelState));

    onTrigger(TriggerDetectedMsg(
      deviceLocalArrivalTimeUs: timestampUs,
      phase: effectiveBothChannels ? WavePhase.sOrSurface : WavePhase.p,
      amplitude: math.sqrt(avgX * avgX + avgY * avgY + avgZ * avgZ),
      azimuthDegrees: azimuth,
      azimuthUncertaintyDegrees: azimuthUncertainty,
      apparentVelocityMps: apparentVelocity,
      sMinusPSeconds: sMinusPSeconds,
      channelState: channelState,
      accelerometerSaturated: _recentlySaturated,
      surfaceType: surfaceType,
      noiseFloorAtTrigger: _accelFloor.floor,
    ));
  }
}
