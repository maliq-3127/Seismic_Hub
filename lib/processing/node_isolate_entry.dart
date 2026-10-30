import 'dart:isolate';

import '../models/seismic_models.dart';
import 'isolate_messages.dart';
import 'node_processor.dart';

SurfaceType _surfaceFromName(String name) {
  return SurfaceType.values.firstWhere((s) => s.name == name, orElse: () => SurfaceType.unknown);
}

/// Entry point passed to Isolate.spawn. [mainSendPort] is the main isolate's
/// inbox - the very first thing this isolate does is hand back its own
/// inbox through it (the standard two-way isolate handshake), after which
/// all further traffic uses the two established ports.
void nodeIsolateEntry(SendPort mainSendPort) {
  final workerReceivePort = ReceivePort();
  mainSendPort.send(workerReceivePort.sendPort);

  NodeProcessor? processor;

  workerReceivePort.listen((dynamic message) {
    if (message is NodeConfigMsg) {
      if (processor == null) {
        processor = NodeProcessor(
          hpfAlpha: message.hpfAlpha,
          sensitivityMultiplier: message.sensitivityMultiplier,
          samplingPeriodSeconds: message.samplingPeriodSeconds,
          magneticDeclinationDegrees: message.magneticDeclinationDegrees,
          onCalibrationProgress: (p) => mainSendPort.send(CalibrationProgressMsg(p)),
          onLiveWave: (m) => mainSendPort.send(LiveWaveMsg(m)),
          onTrigger: (t) => mainSendPort.send(t),
          onStatusChanged: (s) => mainSendPort.send(s),
        )..setManualSurfaceOverride(_surfaceFromName(message.manualSurfaceOverride));
      } else {
        final p = processor!;
        p.hpfAlpha = message.hpfAlpha;
        p.sensitivityMultiplier = message.sensitivityMultiplier;
        p.magneticDeclinationDegrees = message.magneticDeclinationDegrees;
        p.setManualSurfaceOverride(_surfaceFromName(message.manualSurfaceOverride));
      }
    } else if (message is AccelSampleMsg) {
      processor?.onAccelerometerSample(message.timestampUs, message.x, message.y, message.z);
    } else if (message is GyroSampleMsg) {
      processor?.onGyroscopeSample(message.timestampUs, message.x, message.y, message.z);
    } else if (message is MagSampleMsg) {
      processor?.onMagnetometerSample(message.timestampUs, message.x, message.y, message.z);
    } else if (message is ForceRecalibrateMsg) {
      processor?.forceRecalibration();
    } else if (message is ShutdownMsg) {
      workerReceivePort.close();
    }
  });
}
