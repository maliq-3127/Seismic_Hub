// Shared, pure-Dart types for the hypocentre pipeline.
//
// Nothing in this file touches Flutter, sensors_plus, or firebase_database,
// so it is safe to import from either isolate (main-isolate UI code, the
// per-node math isolate, or the hub math isolate) without pulling in any
// platform-channel machinery.

/// What surface a node is resting on. Soft surfaces (couches, carpet,
/// bedding) mechanically damp and low-pass ambient vibration relative to a
/// hard surface (desk, floor, table), which would otherwise be misread as
/// "weak/distant source" by the association gate's amplitude bound. See
/// SurfaceClassifier and fix #1 in ARCHITECTURE.md.
enum SurfaceType { hard, soft, unknown }

/// Which channel(s) a node's data can be trusted from right now, per the
/// decision table in ARCHITECTURE.md. This is the *pre-override* state -
/// method_selector.dart applies the accelerometer-saturation override on
/// top of it per node.
enum ChannelDominanceState { accelerometerDominant, bothChannelsUsable }

/// The seismic phase a single-node trigger is believed to represent, from
/// stage 2 (phase ID): P arrives with negligible rotation; S/surface waves
/// excite the gyroscope too. See ARCHITECTURE.md for why these two are
/// lumped together rather than split into S vs Love/Rayleigh.
enum WavePhase { p, sOrSurface, unknown }

/// Mature (arrival-time / S-P, standard seismological practice) vs the more
/// exotic single-station-6C / rotation-augmented / joint-inversion methods
/// the spec explicitly asks to be flagged as active-research-level rather
/// than settled engineering.
enum MethodMaturity { mature, exotic }

/// One node's contribution to an event - everything stage 3 (association
/// gate) and stage 4 (recursive estimator) need. Produced on-device by
/// stage 1 (trigger) + stage 2 (phase ID), enriched with the node's static
/// config (id/location), then published to Firebase and consumed by the hub.
class TriggerObservation {
  final String nodeId;
  final double latitude;
  final double longitude;
  final double elevationMeters;

  /// Clock-sync-corrected microseconds since epoch (see ClockSyncService).
  final int arrivalTimeUs;

  final WavePhase phase;

  /// Peak filtered magnitude at trigger, in the sensor's native units
  /// (m/s^2 for the accelerometer channel), after any surface correction
  /// has already been noted (the *raw* value is kept here; association_gate
  /// applies the surface correction itself so the raw value stays available
  /// for diagnostics).
  final double amplitude;

  /// True-north-referenced compass bearing the disturbance arrived from,
  /// 0-360 clockwise from north. Null if no magnetometer lock yet.
  final double? azimuthDegrees;
  final double? azimuthUncertaintyDegrees;

  /// Whether the 6C sign check resolved the 180-degree polarization
  /// ambiguity. When false, [azimuthDegrees] names an axis the wave
  /// travelled along - the source could be at that bearing OR its
  /// opposite - and the estimator scores both sides accordingly.
  final bool azimuthResolved;

  /// Local apparent velocity from the 6C rotation/translation ratio. Only
  /// present when [channelState] is bothChannelsUsable (or the
  /// accelerometer-saturated override applies) and the ratio was numerically
  /// sane.
  final double? apparentVelocityMps;

  /// Seconds between this node's P-onset and its S/surface-onset, when the
  /// per-node phase tracker caught both. Null otherwise (the common case).
  final double? sMinusPSeconds;

  final ChannelDominanceState channelState;
  final bool accelerometerSaturated;
  final SurfaceType surfaceType;

  /// The accelerometer noise floor estimate at the moment of trigger, used
  /// by the association gate's amplitude bound.
  final double noiseFloorAtTrigger;

  const TriggerObservation({
    required this.nodeId,
    required this.latitude,
    required this.longitude,
    this.elevationMeters = 0.0,
    required this.arrivalTimeUs,
    required this.phase,
    required this.amplitude,
    this.azimuthDegrees,
    this.azimuthUncertaintyDegrees,
    this.azimuthResolved = false,
    this.apparentVelocityMps,
    this.sMinusPSeconds,
    required this.channelState,
    required this.accelerometerSaturated,
    required this.surfaceType,
    required this.noiseFloorAtTrigger,
  });

  Map<String, dynamic> toJson() => {
        'node_id': nodeId,
        'event_type': 'disturbance',
        'lat': latitude,
        'lng': longitude,
        'elevation_m': elevationMeters,
        'timestamp_us': arrivalTimeUs,
        'phase': phase.name,
        'amplitude': amplitude,
        'azimuth_true_deg': azimuthDegrees,
        'azimuth_uncertainty_deg': azimuthUncertaintyDegrees,
        'azimuth_resolved': azimuthResolved,
        'apparent_velocity_mps': apparentVelocityMps,
        's_minus_p_seconds': sMinusPSeconds,
        'channel_state': channelState.name,
        'accel_saturated': accelerometerSaturated,
        'surface_type': surfaceType.name,
        'noise_floor': noiseFloorAtTrigger,
      };

  static double? _numD(dynamic v) {
    if (v is num) return v.toDouble();
    return null;
  }

  factory TriggerObservation.fromJson(Map<dynamic, dynamic> json) {
    return TriggerObservation(
      nodeId: json['node_id']?.toString() ?? 'unknown',
      latitude: (json['lat'] as num?)?.toDouble() ?? 0.0,
      longitude: (json['lng'] as num?)?.toDouble() ?? 0.0,
      elevationMeters: (json['elevation_m'] as num?)?.toDouble() ?? 0.0,
      arrivalTimeUs: (json['timestamp_us'] as num?)?.toInt() ?? 0,
      phase: WavePhase.values.firstWhere(
        (p) => p.name == json['phase'],
        orElse: () => WavePhase.unknown,
      ),
      amplitude: (json['amplitude'] as num?)?.toDouble() ?? 0.0,
      azimuthDegrees: _numD(json['azimuth_true_deg']),
      azimuthUncertaintyDegrees: _numD(json['azimuth_uncertainty_deg']),
      azimuthResolved: json['azimuth_resolved'] == true,
      apparentVelocityMps: _numD(json['apparent_velocity_mps']),
      sMinusPSeconds: _numD(json['s_minus_p_seconds']),
      channelState: ChannelDominanceState.values.firstWhere(
        (c) => c.name == json['channel_state'],
        orElse: () => ChannelDominanceState.accelerometerDominant,
      ),
      accelerometerSaturated: json['accel_saturated'] == true,
      surfaceType: SurfaceType.values.firstWhere(
        (s) => s.name == json['surface_type'],
        orElse: () => SurfaceType.unknown,
      ),
      noiseFloorAtTrigger: (json['noise_floor'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

/// A recursive point-estimate + uncertainty for one event's hypocentre,
/// re-derived (never rebuilt from scratch) each time a new node associates.
class HypocentreEstimate {
  final String eventId;
  final double latitude;
  final double longitude;

  /// Null when depth genuinely isn't resolvable yet at this node count -
  /// the UI should show "unresolved", never a fabricated number.
  final double? depthMeters;
  final double depthUncertaintyMeters;

  final double originTimeUs;
  final double horizontalUncertaintyMeters;

  /// Implied source amplitude scale (A0 in A(r) = A0 / r^n), used by the
  /// association gate's amplitude-distance bound. Not physically calibrated
  /// (no absolute magnitude scale) - only meaningful relative to itself.
  final double sourceAmplitudeScale;

  final List<String> associatedNodeIds;
  final String methodLabel;
  final MethodMaturity maturity;

  const HypocentreEstimate({
    required this.eventId,
    required this.latitude,
    required this.longitude,
    this.depthMeters,
    required this.depthUncertaintyMeters,
    required this.originTimeUs,
    required this.horizontalUncertaintyMeters,
    required this.sourceAmplitudeScale,
    required this.associatedNodeIds,
    required this.methodLabel,
    required this.maturity,
  });
}
