import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sensors_plus/sensors_plus.dart';

import '../models/seismic_models.dart';
import '../processing/isolate_messages.dart';
import '../processing/node_isolate_entry.dart';
import '../processing/node_processor.dart';

/// Fix #3: "the phones won't be in operation for hours on end, but just in
/// case, drop the polling rate to sustain continuous use for 3 hours."
/// 25 Hz (40 ms) is half the original 50 Hz - still comfortably above the
/// 1-10 Hz dominant-frequency band of the strong ground motion this network
/// is trying to catch (Nyquist at 25 Hz is 12.5 Hz), while meaningfully
/// cutting the platform-channel + isolate-message traffic that dominates
/// battery cost for continuous sensor polling. Override if your test
/// devices show it isn't sustainable, or if it is and you want more margin.
const Duration kDefaultSamplingPeriod = Duration(milliseconds: 40);

/// Owns the sensors_plus streams and the node math isolate for one node.
/// Public stream shape intentionally mirrors the old DisturbanceDetector
/// (onCalibrationProgress / onLiveWave / a trigger stream) so NodeScreen's
/// subscription wiring barely has to change - only what feeds it does.
///
/// On web, dart:isolate spawning isn't supported (Flutter's own docs say
/// plainly: "Dart web platforms, including Flutter web, don't support
/// isolates"), so this runs a NodeProcessor directly on the main isolate
/// instead of spawning a worker - identical STA/LTA + phase-ID logic, just
/// not off the UI thread. Fix #5's partitioning ends up being a
/// native-platform-only benefit as a result; there's no meaningful
/// alternative for continuous polling on web, and a phone browser tab
/// running for 3 hours straight (fix #3) is a marginal use case anyway.
class SensorPollingService {
  final Duration samplingPeriod;
  double hpfAlpha;
  double sensitivityMultiplier;
  double magneticDeclinationDegrees;
  SurfaceType manualSurfaceOverride;

  SensorPollingService({
    required this.hpfAlpha,
    required this.sensitivityMultiplier,
    this.magneticDeclinationDegrees = 0.0,
    this.manualSurfaceOverride = SurfaceType.unknown,
    this.samplingPeriod = kDefaultSamplingPeriod,
  });

  final _calibrationController = StreamController<double>.broadcast();
  Stream<double> get onCalibrationProgress => _calibrationController.stream;

  final _liveWaveController = StreamController<double>.broadcast();
  Stream<double> get onLiveWave => _liveWaveController.stream;

  final _triggerController = StreamController<TriggerDetectedMsg>.broadcast();
  Stream<TriggerDetectedMsg> get onTriggerDetected => _triggerController.stream;

  final _statusController = StreamController<NodeStatusMsg>.broadcast();
  Stream<NodeStatusMsg> get onStatusChanged => _statusController.stream;

  Isolate? _isolate;
  SendPort? _workerSendPort;
  ReceivePort? _mainReceivePort;
  NodeProcessor? _inlineProcessor;

  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<MagnetometerEvent>? _magSub;

  bool _paused = false;

  Future<void> start() async {
    if (kIsWeb) {
      _inlineProcessor = NodeProcessor(
        hpfAlpha: hpfAlpha,
        sensitivityMultiplier: sensitivityMultiplier,
        samplingPeriodSeconds: samplingPeriod.inMicroseconds / 1e6,
        magneticDeclinationDegrees: magneticDeclinationDegrees,
        onCalibrationProgress: (p) {
          if (!_calibrationController.isClosed) _calibrationController.add(p);
        },
        onLiveWave: (m) {
          if (!_liveWaveController.isClosed) _liveWaveController.add(m);
        },
        onTrigger: (t) {
          if (!_triggerController.isClosed) _triggerController.add(t);
        },
        onStatusChanged: (s) {
          if (!_statusController.isClosed) _statusController.add(s);
        },
      )..setManualSurfaceOverride(manualSurfaceOverride);
    } else {
      _mainReceivePort = ReceivePort();
      _isolate = await Isolate.spawn(nodeIsolateEntry, _mainReceivePort!.sendPort);

      final handshakeCompleter = Completer<void>();
      _mainReceivePort!.listen((dynamic message) {
        if (message is SendPort) {
          if (!handshakeCompleter.isCompleted) {
            _workerSendPort = message;
            handshakeCompleter.complete();
          }
          return;
        }
        _handleWorkerMessage(message);
      });
      await handshakeCompleter.future;
      _sendConfig();
    }

    // Raw accelerometer (gravity included) - not userAccelerometerEventStream
    // - because the compass fusion needs the true gravity vector as its
    // "up" reference; the disturbance signal is still isolated in-app via
    // NodeProcessor's own high-pass filter, exactly as before.
    _accelSub = accelerometerEventStream(samplingPeriod: samplingPeriod).listen((event) {
      final t = DateTime.now().microsecondsSinceEpoch;
      final processor = _inlineProcessor;
      if (processor != null) {
        processor.onAccelerometerSample(t, event.x, event.y, event.z);
      } else {
        _workerSendPort?.send(AccelSampleMsg(t, event.x, event.y, event.z));
      }
    });
    _gyroSub = gyroscopeEventStream(samplingPeriod: samplingPeriod).listen((event) {
      final t = DateTime.now().microsecondsSinceEpoch;
      final processor = _inlineProcessor;
      if (processor != null) {
        processor.onGyroscopeSample(t, event.x, event.y, event.z);
      } else {
        _workerSendPort?.send(GyroSampleMsg(t, event.x, event.y, event.z));
      }
    });
    _magSub = magnetometerEventStream(samplingPeriod: samplingPeriod).listen((event) {
      final t = DateTime.now().microsecondsSinceEpoch;
      final processor = _inlineProcessor;
      if (processor != null) {
        processor.onMagnetometerSample(t, event.x, event.y, event.z);
      } else {
        _workerSendPort?.send(MagSampleMsg(t, event.x, event.y, event.z));
      }
    });
  }

  void _handleWorkerMessage(dynamic message) {
    if (message is CalibrationProgressMsg) {
      if (!_calibrationController.isClosed) _calibrationController.add(message.progress);
    } else if (message is LiveWaveMsg) {
      if (!_liveWaveController.isClosed) _liveWaveController.add(message.magnitude);
    } else if (message is TriggerDetectedMsg) {
      if (!_triggerController.isClosed) _triggerController.add(message);
    } else if (message is NodeStatusMsg) {
      if (!_statusController.isClosed) _statusController.add(message);
    }
  }

  void _sendConfig() {
    _workerSendPort?.send(NodeConfigMsg(
      hpfAlpha: hpfAlpha,
      sensitivityMultiplier: sensitivityMultiplier,
      samplingPeriodSeconds: samplingPeriod.inMicroseconds / 1e6,
      manualSurfaceOverride: manualSurfaceOverride.name,
      magneticDeclinationDegrees: magneticDeclinationDegrees,
    ));
  }

  void updateHpfAlpha(double value) {
    hpfAlpha = value;
    final processor = _inlineProcessor;
    if (processor != null) {
      processor.hpfAlpha = value;
      return;
    }
    _sendConfig();
  }

  void updateSensitivity(double value) {
    sensitivityMultiplier = value;
    final processor = _inlineProcessor;
    if (processor != null) {
      processor.sensitivityMultiplier = value;
      return;
    }
    _sendConfig();
  }

  void updateDeclination(double degrees) {
    magneticDeclinationDegrees = degrees;
    final processor = _inlineProcessor;
    if (processor != null) {
      processor.magneticDeclinationDegrees = degrees;
      return;
    }
    _sendConfig();
  }

  void updateManualSurfaceOverride(SurfaceType type) {
    manualSurfaceOverride = type;
    final processor = _inlineProcessor;
    if (processor != null) {
      processor.setManualSurfaceOverride(type);
      return;
    }
    _sendConfig();
  }

  void forceRecalibration() {
    final processor = _inlineProcessor;
    if (processor != null) {
      processor.forceRecalibration();
      return;
    }
    _workerSendPort?.send(const ForceRecalibrateMsg());
  }

  void pause() {
    if (_paused) return;
    _paused = true;
    _accelSub?.pause();
    _gyroSub?.pause();
    _magSub?.pause();
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    _accelSub?.resume();
    _gyroSub?.resume();
    _magSub?.resume();
  }

  void dispose() {
    _accelSub?.cancel();
    _gyroSub?.cancel();
    _magSub?.cancel();
    if (_inlineProcessor == null) {
      _workerSendPort?.send(const ShutdownMsg());
      _mainReceivePort?.close();
      _isolate?.kill(priority: Isolate.immediate);
    }
    _calibrationController.close();
    _liveWaveController.close();
    _triggerController.close();
    _statusController.close();
  }
}
