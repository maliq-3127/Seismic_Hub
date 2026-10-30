import 'dart:math' as math;

/// Fix #8: "add a system to manage noise floors."
///
/// Tracks a slowly-adapting background level for one channel's magnitude
/// (accelerometer or gyroscope), used two ways elsewhere in the pipeline:
///  - phase ID asks "is the gyroscope showing anything above ITS OWN floor
///    right now" instead of a hand-tuned fixed threshold - see
///    node_processor.dart;
///  - the association gate's amplitude bound needs each node's own floor to
///    know what "still detectable" means at that node - see
///    association_gate.dart.
///
/// [freeze]/[unfreeze] must be called by the owner around any active
/// trigger/accumulation window: the previous single-channel STA/LTA in
/// disturbance_detector.dart updated its long-term average unconditionally,
/// which lets a strong, sustained disturbance drag its own reference level
/// upward mid-event and blunt the ratio that is supposed to be detecting it.
/// Freezing during the trigger avoids that self-contamination.
class NoiseFloorTracker {
  final double alpha;
  double _floor;
  double _floorVariance;
  bool _seeded = false;
  bool frozen = false;

  NoiseFloorTracker({this.alpha = 0.01, double initialFloor = 1e-6})
      : _floor = initialFloor,
        _floorVariance = initialFloor * initialFloor;

  void update(double magnitude) {
    if (!_seeded) {
      _floor = magnitude;
      _floorVariance = (magnitude * 0.1) * (magnitude * 0.1);
      _seeded = true;
      return;
    }
    if (frozen) return;
    final delta = magnitude - _floor;
    _floor += alpha * delta;
    _floorVariance += alpha * (delta * delta - _floorVariance);
  }

  double get floor => _floor;

  double get floorStdDev => math.sqrt(math.max(_floorVariance, 0.0));

  /// True if [magnitude] sits at least [multiple] standard deviations above
  /// the tracked floor - a floor-relative test rather than a raw constant,
  /// so it self-calibrates per node/per channel/per environment.
  bool isAboveFloor(double magnitude, {double multiple = 5.0}) {
    return magnitude > _floor + multiple * floorStdDev;
  }
}
