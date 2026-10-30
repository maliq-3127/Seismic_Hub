// Fix #5: "heavily partition the continuous sensor polling and mathematical
// model." Continuous, platform-channel-bound sensor polling (and all
// Firebase/UI work) stays on the main isolate; all CPU-bound math (STA/LTA,
// phase ID, the recursive hypocentre estimator) runs on a dedicated worker
// isolate spawned once and kept alive for the app's session, rather than a
// new isolate per sample (as Flutter's one-shot `compute()` would do) or the
// math running inline on the UI/platform-channel isolate.
//
// Every class below is a plain data holder (numbers, strings, enums, lists
// of the same) so it can cross the isolate boundary by Dart's normal message
// copy - nothing here holds a Stream, a plugin handle, or any other
// isolate-bound resource.

import '../models/seismic_models.dart';

// ---------------------------------------------------------------------
// Main isolate -> node math isolate
// ---------------------------------------------------------------------

class NodeConfigMsg {
  final double hpfAlpha;
  final double sensitivityMultiplier;
  final double samplingPeriodSeconds;
  final String manualSurfaceOverride; // SurfaceType.name; 'unknown' = auto
  final double magneticDeclinationDegrees;
  const NodeConfigMsg({
    required this.hpfAlpha,
    required this.sensitivityMultiplier,
    required this.samplingPeriodSeconds,
    required this.manualSurfaceOverride,
    required this.magneticDeclinationDegrees,
  });
}

class AccelSampleMsg {
  final int timestampUs;
  final double x, y, z;
  const AccelSampleMsg(this.timestampUs, this.x, this.y, this.z);
}

class GyroSampleMsg {
  final int timestampUs;
  final double x, y, z;
  const GyroSampleMsg(this.timestampUs, this.x, this.y, this.z);
}

class MagSampleMsg {
  final int timestampUs;
  final double x, y, z;
  const MagSampleMsg(this.timestampUs, this.x, this.y, this.z);
}

class ForceRecalibrateMsg {
  const ForceRecalibrateMsg();
}

class ShutdownMsg {
  const ShutdownMsg();
}

// ---------------------------------------------------------------------
// Node math isolate -> main isolate
// ---------------------------------------------------------------------

class CalibrationProgressMsg {
  final double progress;
  const CalibrationProgressMsg(this.progress);
}

class LiveWaveMsg {
  final double magnitude;
  const LiveWaveMsg(this.magnitude);
}

/// Everything stage 1+2 produced for one trigger, minus the node's static
/// identity/location (nodeId/lat/lng) - those live in the main isolate and
/// are attached right before publishing to Firebase, see
/// sensor_polling_service.dart.
class TriggerDetectedMsg {
  final int deviceLocalArrivalTimeUs;
  final WavePhase phase;
  final double amplitude;
  final double? azimuthDegrees;
  final double? azimuthUncertaintyDegrees;
  final double? apparentVelocityMps;
  final double? sMinusPSeconds;
  final ChannelDominanceState channelState;
  final bool accelerometerSaturated;
  final SurfaceType surfaceType;
  final double noiseFloorAtTrigger;

  const TriggerDetectedMsg({
    required this.deviceLocalArrivalTimeUs,
    required this.phase,
    required this.amplitude,
    this.azimuthDegrees,
    this.azimuthUncertaintyDegrees,
    this.apparentVelocityMps,
    this.sMinusPSeconds,
    required this.channelState,
    required this.accelerometerSaturated,
    required this.surfaceType,
    required this.noiseFloorAtTrigger,
  });
}

/// Lightweight, frequent-ish status snapshot for the node's own UI (surface
/// type once classified, most recent channel-dominance state) - distinct
/// from a full trigger so the UI can show live diagnostics even between
/// disturbances.
class NodeStatusMsg {
  final SurfaceType surfaceType;
  final ChannelDominanceState? lastChannelState;
  const NodeStatusMsg(this.surfaceType, this.lastChannelState);
}

// ---------------------------------------------------------------------
// Main isolate -> hub math isolate
// ---------------------------------------------------------------------

class ObservationMsg {
  final Map<String, dynamic> json; // TriggerObservation.toJson()
  const ObservationMsg(this.json);
}

class PurgeStaleEventsMsg {
  final int nowUs;
  final int maxAgeUs;
  const PurgeStaleEventsMsg(this.nowUs, this.maxAgeUs);
}

// ---------------------------------------------------------------------
// Hub math isolate -> main isolate
// ---------------------------------------------------------------------

class EstimateUpdateMsg {
  final String eventId;
  final double latitude;
  final double longitude;
  final double? depthMeters;
  final double depthUncertaintyMeters;
  final double originTimeUs;
  final double horizontalUncertaintyMeters;
  final List<String> associatedNodeIds;
  final String methodLabel;
  final MethodMaturity maturity;
  final bool isNewEvent;

  const EstimateUpdateMsg({
    required this.eventId,
    required this.latitude,
    required this.longitude,
    this.depthMeters,
    required this.depthUncertaintyMeters,
    required this.originTimeUs,
    required this.horizontalUncertaintyMeters,
    required this.associatedNodeIds,
    required this.methodLabel,
    required this.maturity,
    required this.isNewEvent,
  });

  HypocentreEstimate toEstimate() => HypocentreEstimate(
        eventId: eventId,
        latitude: latitude,
        longitude: longitude,
        depthMeters: depthMeters,
        depthUncertaintyMeters: depthUncertaintyMeters,
        originTimeUs: originTimeUs,
        horizontalUncertaintyMeters: horizontalUncertaintyMeters,
        sourceAmplitudeScale: 0.0,
        associatedNodeIds: associatedNodeIds,
        methodLabel: methodLabel,
        maturity: maturity,
      );
}

class EventExpiredMsg {
  final String eventId;
  const EventExpiredMsg(this.eventId);
}
