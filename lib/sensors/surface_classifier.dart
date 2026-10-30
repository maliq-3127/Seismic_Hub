import '../models/seismic_models.dart';

/// Fix #1: "get around the soft surfaces issue by only using the devices on
/// either hard or soft surfaces."
///
/// Read literally this would mean "only accept nodes that sit on hard OR
/// soft surfaces" - i.e. every surface, which fixes nothing. The
/// interpretation used here (stated explicitly in ARCHITECTURE.md) is: stop
/// treating "surface" as invisible. Classify each node as hard or soft and
/// *account for it* - correct the damped amplitude a soft surface produces
/// and down-weight that node's reliability slightly - rather than silently
/// pooling hard- and soft-surface nodes as if they measured the same thing.
/// Excluding soft-surface nodes outright was rejected: for a small
/// proof-of-concept network, throwing away a working node's data loses
/// more than a documented correction factor does.
///
/// The automatic classifier is a cheap proxy, not a calibrated instrument:
/// a soft surface mechanically low-pass filters ambient vibration relative
/// to a hard one, so the ratio of sample-to-sample ("high-frequency")
/// energy to total energy gathered during calibration should read lower on
/// a soft surface. The cut point below is a placeholder - calibrate it
/// against your own hard/soft test recordings before trusting it blind;
/// the manual override exists precisely because this heuristic is a
/// starting point, not a validated instrument.
class SurfaceClassifier {
  /// 'unknown' means "trust the automatic classifier"; hard/soft here means
  /// the operator has overridden it (e.g. from node_settings/{id}/surface_override).
  SurfaceType manualOverride = SurfaceType.unknown;

  double _sumTotalEnergy = 0.0;
  double _sumHighFreqEnergy = 0.0;
  double _prevMagnitude = 0.0;
  bool _hasPrev = false;
  int _sampleCount = 0;

  /// Placeholder cut point on (high-frequency energy / total energy)
  /// gathered during calibration; ratios above this are classified hard.
  static const double _hardSoftRatioCutoff = 0.35;

  /// Multiplies a soft-surface node's observed amplitude back up before it
  /// is compared against the association gate's amplitude-distance bound,
  /// so damping isn't misread as "this must be a weak/distant source".
  /// A rough placeholder - tune against your own test rig.
  static const double softSurfaceAmplitudeCorrection = 1.6;

  /// Relative trust given to a soft-surface node's amplitude/trigger data
  /// in the recursive estimator, reflecting the extra uncertainty a
  /// mechanical damping correction can't fully remove.
  static const double softSurfaceReliabilityWeight = 0.6;

  void accumulate(double magnitude) {
    _sumTotalEnergy += magnitude * magnitude;
    if (_hasPrev) {
      final delta = magnitude - _prevMagnitude;
      _sumHighFreqEnergy += delta * delta;
    }
    _prevMagnitude = magnitude;
    _hasPrev = true;
    _sampleCount++;
  }

  void reset() {
    _sumTotalEnergy = 0.0;
    _sumHighFreqEnergy = 0.0;
    _prevMagnitude = 0.0;
    _hasPrev = false;
    _sampleCount = 0;
  }

  SurfaceType classify() {
    if (manualOverride != SurfaceType.unknown) return manualOverride;
    if (_sampleCount < 10 || _sumTotalEnergy < 1e-9) return SurfaceType.unknown;
    final ratio = _sumHighFreqEnergy / _sumTotalEnergy;
    return ratio > _hardSoftRatioCutoff ? SurfaceType.hard : SurfaceType.soft;
  }
}
