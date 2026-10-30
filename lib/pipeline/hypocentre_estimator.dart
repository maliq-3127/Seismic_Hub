import 'dart:math' as math;

import '../models/seismic_models.dart';
import 'association_gate.dart';
import 'method_selector.dart';
import 'velocity_model.dart';

/// A local flat-Earth tangent plane centered on the seeding node. Adequate
/// for the local/regional scale (a proof-of-concept network, not hundreds
/// of nodes spanning continents - fix #2) and matches the same simple
/// equirectangular approximation already used elsewhere in this app.
class LocalTangentPlane {
  final double originLat;
  final double originLon;
  static const double metersPerDegreeLat = 111320.0;
  late final double metersPerDegreeLon;

  LocalTangentPlane(this.originLat, this.originLon) {
    metersPerDegreeLon = 111320.0 * math.cos(originLat * math.pi / 180.0);
  }

  EastNorth toEastNorth(double lat, double lon) {
    final denom = metersPerDegreeLon.abs() < 1e-6 ? 1e-6 : metersPerDegreeLon;
    return EastNorth((lon - originLon) * denom, (lat - originLat) * metersPerDegreeLat);
  }

  LatLon toLatLon(double east, double north) {
    final denom = metersPerDegreeLon.abs() < 1e-6 ? 1e-6 : metersPerDegreeLon;
    return LatLon(originLat + north / metersPerDegreeLat, originLon + east / denom);
  }
}

class EastNorth {
  final double east;
  final double north;
  const EastNorth(this.east, this.north);
}

class LatLon {
  final double lat;
  final double lon;
  const LatLon(this.lat, this.lon);
}

class _AssocEntry {
  final TriggerObservation obs;
  final NodeTrust trust;
  final EastNorth en;
  const _AssocEntry(this.obs, this.trust, this.en);
}

class _Candidate {
  final double east;
  final double north;
  final double depth;
  double logWeight = 0.0;
  _Candidate(this.east, this.north, this.depth);
}

double _travelTimeSeconds(double east, double north, double depth, EastNorth nodeEn, WavePhase phase) {
  final dEast = nodeEn.east - east;
  final dNorth = nodeEn.north - north;
  final horizontal = math.sqrt(dEast * dEast + dNorth * dNorth);
  final slant = math.sqrt(horizontal * horizontal + depth * depth);
  return slant / velocityForPhase(phase);
}

/// Bearing (degrees, clockwise from north) from (fromE,fromN) to (toE,toN)
/// in the local tangent plane - used as the predicted backazimuth at a node
/// looking toward a candidate hypocentre.
double _bearingDegrees(double fromEast, double fromNorth, double toEast, double toNorth) {
  final dEast = toEast - fromEast;
  final dNorth = toNorth - fromNorth;
  double deg = math.atan2(dEast, dNorth) * 180.0 / math.pi;
  if (deg < 0) deg += 360.0;
  return deg;
}

double _angularDifferenceDegrees(double a, double b) {
  double diff = a - b;
  while (diff > 180.0) {
    diff -= 360.0;
  }
  while (diff < -180.0) {
    diff += 360.0;
  }
  return diff;
}

/// Common surface both estimator strategies below implement, so
/// SeismicEvent (stage 5) can hold either interchangeably.
abstract class HypocentreStrategy {
  void addObservation(TriggerObservation obs, NodeTrust trust);
  HypocentreEstimate currentEstimate({
    required String eventId,
    required String methodLabel,
    required MethodMaturity maturity,
  });
}

/// Stage 4 (primary strategy): a Bayesian posterior over a warm-started grid
/// of candidate hypocentres, recursively reweighted (never regenerated) as
/// each new node associates. This is the "ideally a Bayesian approach...
/// which handles the multi-modal ambiguity possible at low node counts"
/// option from the spec.
///
/// Rather than a distinct algorithm per decision-table cell, every cell
/// feeds this SAME estimator with a different subset of trusted observation
/// types per node (see method_selector.dart) - what varies is which
/// likelihood terms below get evaluated for a given node, and the
/// confidence/maturity label attached for display, not the underlying math.
/// The "more exotic" methods (single-station 6C, joint inversion) end up as
/// the apparent-velocity and multi-node azimuth-consistency terms below,
/// contributing real information without claiming settled-engineering
/// precision - see ARCHITECTURE.md. The "mature" single-station S-P method
/// is real too, not just a label: a node's S-P interval, when its local
/// phase tracker catches one, becomes a genuine distance constraint below -
/// the classic reason to associate a node's P and S readings together in
/// the first place, rather than treating the second as unrelated.
///
/// The azimuth term is a two-component mixture, not a single Gaussian,
/// whenever a reading's 180-degree ambiguity was NOT resolved (see
/// TriggerObservation.azimuthResolved): plain accelerometer polarization
/// resolves an axis the wave travelled along, not a direction, so the
/// candidate 180 degrees opposite the reported bearing is scored as
/// equally plausible rather than penalised as wrong. When
/// node_processor.dart's 6C sign check DID resolve it - the verified
/// Igel-relation correlation test - the reading is a real direction and
/// scores unimodally. The gate is the actual outcome of that check, not
/// an assumption from channel state.
///
/// Depth is handled the same way: rather than a hard "N nodes required"
/// rule, a gentle shallow-favouring log-prior lets the data override it
/// once enough nodes constrain the vertical dimension, and the depth
/// actually reported (see currentEstimate) is only ever the number the
/// posterior's own spread supports - never a value dressed up as more
/// precise than the data justify.
///
/// Performance note: candidates are never rebuilt or resized after seeding
/// (true warm-start); each update recomputes per-candidate weights against
/// the full accumulated observation set in O(candidates x associated nodes)
/// - not O(candidates x associated^2) - by profiling each candidate's
/// implied origin time exactly once before scoring its observations.
class HypocentreEstimator implements HypocentreStrategy {
  static const double _searchRadiusMeters = 50000.0;
  static const int _gridSize = 30; // 30x30 horizontal cells
  static const int _depthBins = 12;
  static const double _maxDepthMeters = 40000.0;
  static const double _sigmaTimeSeconds = 0.4;
  static const double _defaultAzimuthSigmaDegrees = 30.0;
  static const double _apparentVelocitySigmaLog = 0.5;
  static const double _apparentVelocityDownweight = 0.5; // exotic signal, contributes less
  static const double _amplitudeSigmaLog = 0.8;
  // S-P timing is a more reliable measurement than raw amplitude even
  // through a simplified fixed-velocity model, so this is tighter than
  // _amplitudeSigmaLog - still a placeholder, not a calibrated figure.
  static const double _sMinusPSigmaLog = 0.3;

  late final LocalTangentPlane plane;
  final List<_Candidate> _candidates = [];
  final List<_AssocEntry> _associated = [];
  double _currentA0 = 1.0;

  HypocentreEstimator.seed(TriggerObservation first, NodeTrust firstTrust) {
    plane = LocalTangentPlane(first.latitude, first.longitude);
    _buildGrid();
    _currentA0 = AssociationGate.impliedSourceAmplitudeScale(first, _searchRadiusMeters / 10);
    addObservation(first, firstTrust);
  }

  void _buildGrid() {
    final step = (2 * _searchRadiusMeters) / _gridSize;
    final depthStep = _maxDepthMeters / _depthBins;
    for (int i = 0; i < _gridSize; i++) {
      final east = -_searchRadiusMeters + step * (i + 0.5);
      for (int j = 0; j < _gridSize; j++) {
        final north = -_searchRadiusMeters + step * (j + 0.5);
        for (int k = 0; k < _depthBins; k++) {
          final depth = depthStep * (k + 0.5);
          _candidates.add(_Candidate(east, north, depth));
        }
      }
    }
  }

  @override
  void addObservation(TriggerObservation obs, NodeTrust trust) {
    final en = plane.toEastNorth(obs.latitude, obs.longitude);
    _refreshAmplitudeScale();
    _associated.removeWhere((a) => a.obs.nodeId == obs.nodeId);
    _associated.add(_AssocEntry(obs, trust, en));
    _recomputeWeights();
  }

  ({double east, double north, double depth}) _weightedPointEstimate() {
    if (_candidates.isEmpty) return (east: 0.0, north: 0.0, depth: 10000.0);
    final maxLogW = _candidates.map((c) => c.logWeight).reduce(math.max);
    double sumW = 0, sumE = 0, sumN = 0, sumD = 0;
    for (final c in _candidates) {
      final w = math.exp(c.logWeight - maxLogW);
      sumW += w;
      sumE += w * c.east;
      sumN += w * c.north;
      sumD += w * c.depth;
    }
    if (sumW <= 0) return (east: 0.0, north: 0.0, depth: 10000.0);
    return (east: sumE / sumW, north: sumN / sumW, depth: sumD / sumW);
  }

  void _refreshAmplitudeScale() {
    if (_associated.isEmpty) return;
    final point = _weightedPointEstimate();
    double sumW = 0, sumWA0 = 0;
    for (final a in _associated) {
      if (!a.trust.useAmplitude) continue;
      final dEast = a.en.east - point.east;
      final dNorth = a.en.north - point.north;
      final horizontal = math.sqrt(dEast * dEast + dNorth * dNorth);
      final slant = math.sqrt(horizontal * horizontal + point.depth * point.depth);
      final impliedA0 =
          AssociationGate.correctedAmplitude(a.obs) * math.pow(math.max(slant, 1.0), AssociationGate.amplitudeSpreadingExponent);
      final w = a.trust.reliabilityWeight;
      sumW += w;
      sumWA0 += w * impliedA0;
    }
    if (sumW > 0) _currentA0 = sumWA0 / sumW;
  }

  double _profiledOriginTimeSecondsForCandidate(_Candidate c) {
    double sumW = 0, sumWT = 0;
    for (final a in _associated) {
      final travel = _travelTimeSeconds(c.east, c.north, c.depth, a.en, a.obs.phase);
      final impliedT0 = (a.obs.arrivalTimeUs / 1e6) - travel;
      final w = a.trust.reliabilityWeight;
      sumW += w;
      sumWT += w * impliedT0;
    }
    return sumW > 0 ? sumWT / sumW : 0.0;
  }

  double _depthLogPrior(double depthMeters) => -(depthMeters / 1000.0) / 40.0;

  void _recomputeWeights() {
    for (final c in _candidates) {
      final t0 = _profiledOriginTimeSecondsForCandidate(c);
      double logL = _depthLogPrior(c.depth);

      for (final a in _associated) {
        final travel = _travelTimeSeconds(c.east, c.north, c.depth, a.en, a.obs.phase);
        final predictedSeconds = t0 + travel;
        final residualSeconds = predictedSeconds - (a.obs.arrivalTimeUs / 1e6);
        logL += -0.5 * math.pow(residualSeconds / _sigmaTimeSeconds, 2) * a.trust.reliabilityWeight;

        if (a.trust.useAzimuth && a.obs.azimuthDegrees != null) {
          final predictedBackAzimuth = _bearingDegrees(a.en.east, a.en.north, c.east, c.north);
          final sigma = a.obs.azimuthUncertaintyDegrees ?? _defaultAzimuthSigmaDegrees;
          final diffPrimary = _angularDifferenceDegrees(a.obs.azimuthDegrees!, predictedBackAzimuth);
          final logLPrimary = -0.5 * math.pow(diffPrimary / sigma, 2);

          if (!a.obs.azimuthResolved) {
            // The 6C sign check either wasn't possible or declined to
            // guess, so this bearing names an *axis* the wave travelled
            // along, not a direction - "the source is this way" and "the
            // source is the exact opposite way" are equally consistent
            // with it. Score both sides via a two-component mixture
            // (equal prior weight, same sigma), combined in log-space
            // with the standard log-sum-exp so near-zero-probability
            // candidates don't underflow. Scoring only the reported side
            // would collapse a single-node posterior onto the wrong side
            // of what is genuinely a coin flip.
            final diffOpposite = _angularDifferenceDegrees(a.obs.azimuthDegrees! + 180.0, predictedBackAzimuth);
            final logLOpposite = -0.5 * math.pow(diffOpposite / sigma, 2);
            final m = math.max(logLPrimary, logLOpposite);
            final mixtureLogL = m + math.log(0.5 * math.exp(logLPrimary - m) + 0.5 * math.exp(logLOpposite - m));
            logL += mixtureLogL * a.trust.reliabilityWeight;
          } else {
            // 6C sign check positively resolved which side the source is
            // on (see node_processor.dart's _resolve180Ambiguity), so
            // this is a real direction and scores unimodally.
            logL += logLPrimary * a.trust.reliabilityWeight;
          }
        }

        if (a.trust.useApparentVelocity && a.obs.apparentVelocityMps != null) {
          final dEast = a.en.east - c.east;
          final dNorth = a.en.north - c.north;
          final horizontal = math.sqrt(dEast * dEast + dNorth * dNorth);
          final slant = math.sqrt(horizontal * horizontal + c.depth * c.depth);
          final phaseVelocity = velocityForPhase(a.obs.phase);
          final predictedApparent = horizontal > 1.0 ? phaseVelocity * slant / horizontal : 1.0e9;
          final logResidual =
              math.log(math.max(a.obs.apparentVelocityMps!, 1.0)) - math.log(math.max(predictedApparent, 1.0));
          logL += -0.5 *
              math.pow(logResidual / _apparentVelocitySigmaLog, 2) *
              a.trust.reliabilityWeight *
              _apparentVelocityDownweight;
        }

        if (a.trust.useAmplitude) {
          final dEast = a.en.east - c.east;
          final dNorth = a.en.north - c.north;
          final horizontal = math.sqrt(dEast * dEast + dNorth * dNorth);
          final slant = math.sqrt(horizontal * horizontal + c.depth * c.depth);
          final predictedAmplitude = _currentA0 / math.pow(math.max(slant, 1.0), AssociationGate.amplitudeSpreadingExponent);
          final observedAmplitude = AssociationGate.correctedAmplitude(a.obs);
          final logResidual = math.log(math.max(observedAmplitude, 1e-6)) - math.log(math.max(predictedAmplitude, 1e-6));
          logL += -0.5 * math.pow(logResidual / _amplitudeSigmaLog, 2) * a.trust.reliabilityWeight;
        }

        if (a.trust.useSMinusP && a.obs.sMinusPSeconds != null) {
          // The classic single-station distance formula: this is the whole
          // reason node_processor.dart tracks a node's P-then-S pair rather
          // than treating the S arrival as unrelated - without this term,
          // linking them bought nothing over just keeping the P reading.
          final dEast = a.en.east - c.east;
          final dNorth = a.en.north - c.north;
          final horizontal = math.sqrt(dEast * dEast + dNorth * dNorth);
          final actualDistance = math.sqrt(horizontal * horizontal + c.depth * c.depth);
          final impliedDistance = sMinusPDistanceConstantMps * a.obs.sMinusPSeconds!;
          final logResidual = math.log(math.max(actualDistance, 1.0)) - math.log(math.max(impliedDistance, 1.0));
          logL += -0.5 * math.pow(logResidual / _sMinusPSigmaLog, 2) * a.trust.reliabilityWeight;
        }
      }
      c.logWeight = logL;
    }
  }

  @override
  HypocentreEstimate currentEstimate({
    required String eventId,
    required String methodLabel,
    required MethodMaturity maturity,
  }) {
    final maxLogW = _candidates.map((c) => c.logWeight).reduce(math.max);
    double sumW = 0, sumE = 0, sumN = 0, sumD = 0;
    for (final c in _candidates) {
      final w = math.exp(c.logWeight - maxLogW);
      sumW += w;
      sumE += w * c.east;
      sumN += w * c.north;
      sumD += w * c.depth;
    }
    final meanEast = sumW > 0 ? sumE / sumW : 0.0;
    final meanNorth = sumW > 0 ? sumN / sumW : 0.0;
    final meanDepth = sumW > 0 ? sumD / sumW : _maxDepthMeters / 2;

    double varEast = 0, varNorth = 0, varDepth = 0;
    for (final c in _candidates) {
      final w = (sumW > 0 ? math.exp(c.logWeight - maxLogW) / sumW : 0.0);
      varEast += w * math.pow(c.east - meanEast, 2);
      varNorth += w * math.pow(c.north - meanNorth, 2);
      varDepth += w * math.pow(c.depth - meanDepth, 2);
    }
    final horizontalUncertainty = math.sqrt(varEast + varNorth);
    final depthUncertainty = math.sqrt(varDepth);

    final latLon = plane.toLatLon(meanEast, meanNorth);

    // Only report a depth once the posterior's own spread meaningfully
    // narrows it, rather than always reporting the mean regardless of how
    // flat/uninformative the posterior over depth actually is.
    final depthResolved = depthUncertainty < (_maxDepthMeters * 0.3);

    return HypocentreEstimate(
      eventId: eventId,
      latitude: latLon.lat,
      longitude: latLon.lon,
      depthMeters: depthResolved ? meanDepth : null,
      depthUncertaintyMeters: depthUncertainty,
      originTimeUs: _associated.isNotEmpty
          ? _profiledOriginTimeSecondsForCandidate(_Candidate(meanEast, meanNorth, meanDepth)) * 1e6
          : 0.0,
      horizontalUncertaintyMeters: horizontalUncertainty,
      sourceAmplitudeScale: _currentA0,
      associatedNodeIds: _associated.map((a) => a.obs.nodeId).toList(),
      methodLabel: methodLabel,
      maturity: maturity,
    );
  }
}

/// Stage 4 (lighter fallback): a single Gauss-Newton correction per new
/// observation (numerically-differentiated Jacobian, symmetric 3x3 normal
/// equations solved in closed form) rather than the full grid posterior -
/// "a lighter fallback is recursive weighted least-squares, warm-started
/// from the prior estimate". Origin time is profiled analytically the same
/// way as the grid estimator. Deliberately simpler than
/// [HypocentreEstimator]: arrival-time only (no azimuth/apparent-velocity
/// terms), and it reports a coarse fixed depth-uncertainty placeholder
/// rather than a real posterior spread, since it carries no covariance
/// estimate of its own. Available as an alternative strategy; the pipeline
/// defaults to [HypocentreEstimator] because the spec marks the Bayesian
/// approach as the preferred one.
class RecursiveWeightedLeastSquares implements HypocentreStrategy {
  late final LocalTangentPlane plane;
  double east = 0.0;
  double north = 0.0;
  double depth = 10000.0;
  final List<_AssocEntry> _associated = [];
  double _currentA0 = 1.0;

  static const double _finiteDifferenceStepMeters = 50.0;
  static const double _stepDamping = 0.5;
  static const double _maxDepthMeters = 60000.0;

  RecursiveWeightedLeastSquares.seed(TriggerObservation first, NodeTrust firstTrust) {
    plane = LocalTangentPlane(first.latitude, first.longitude);
    _currentA0 = AssociationGate.impliedSourceAmplitudeScale(first, 5000.0);
    addObservation(first, firstTrust);
  }

  @override
  void addObservation(TriggerObservation obs, NodeTrust trust) {
    final en = plane.toEastNorth(obs.latitude, obs.longitude);
    _associated.removeWhere((a) => a.obs.nodeId == obs.nodeId);
    _associated.add(_AssocEntry(obs, trust, en));
    _gaussNewtonStep();
  }

  double _profiledOriginTimeSeconds(double e, double n, double d) {
    double sumW = 0, sumWT = 0;
    for (final a in _associated) {
      final travel = _travelTimeSeconds(e, n, d, a.en, a.obs.phase);
      final impliedT0 = (a.obs.arrivalTimeUs / 1e6) - travel;
      sumW += a.trust.reliabilityWeight;
      sumWT += a.trust.reliabilityWeight * impliedT0;
    }
    return sumW > 0 ? sumWT / sumW : 0.0;
  }

  double _predictedSecondsAt(double e, double n, double d, _AssocEntry a) {
    return _profiledOriginTimeSeconds(e, n, d) + _travelTimeSeconds(e, n, d, a.en, a.obs.phase);
  }

  void _gaussNewtonStep() {
    if (_associated.length < 2) return;
    const h = _finiteDifferenceStepMeters;

    double a00 = 0, a01 = 0, a02 = 0, a11 = 0, a12 = 0, a22 = 0, b0 = 0, b1 = 0, b2 = 0;

    for (final a in _associated) {
      final observedSeconds = a.obs.arrivalTimeUs / 1e6;
      final base = _predictedSecondsAt(east, north, depth, a);
      final residual = base - observedSeconds;
      final w = a.trust.reliabilityWeight;

      final jEast = (_predictedSecondsAt(east + h, north, depth, a) - base) / h;
      final jNorth = (_predictedSecondsAt(east, north + h, depth, a) - base) / h;
      final jDepth = (_predictedSecondsAt(east, north, depth + h, a) - base) / h;

      a00 += w * jEast * jEast;
      a01 += w * jEast * jNorth;
      a02 += w * jEast * jDepth;
      a11 += w * jNorth * jNorth;
      a12 += w * jNorth * jDepth;
      a22 += w * jDepth * jDepth;
      b0 += -w * jEast * residual;
      b1 += -w * jNorth * residual;
      b2 += -w * jDepth * residual;
    }

    final a10 = a01, a20 = a02, a21 = a12;
    final det = a00 * (a11 * a22 - a12 * a21) - a01 * (a10 * a22 - a12 * a20) + a02 * (a10 * a21 - a11 * a20);
    if (det.abs() < 1e-12) return; // ill-conditioned (e.g. near-collinear nodes) - skip this step

    final dEast = (b0 * (a11 * a22 - a12 * a21) - a01 * (b1 * a22 - a12 * b2) + a02 * (b1 * a21 - a11 * b2)) / det;
    final dNorth = (a00 * (b1 * a22 - a12 * b2) - b0 * (a10 * a22 - a12 * a20) + a02 * (a10 * b2 - b1 * a20)) / det;
    final dDepth = (a00 * (a11 * b2 - b1 * a21) - a01 * (a10 * b2 - b1 * a20) + b0 * (a10 * a21 - a11 * a20)) / det;

    east += _stepDamping * dEast;
    north += _stepDamping * dNorth;
    depth = (depth + _stepDamping * dDepth).clamp(0.0, _maxDepthMeters);
  }

  @override
  HypocentreEstimate currentEstimate({
    required String eventId,
    required String methodLabel,
    required MethodMaturity maturity,
  }) {
    final latLon = plane.toLatLon(east, north);
    final originTimeUs = _profiledOriginTimeSeconds(east, north, depth) * 1e6;
    return HypocentreEstimate(
      eventId: eventId,
      latitude: latLon.lat,
      longitude: latLon.lon,
      depthMeters: _associated.length >= 4 ? depth : null,
      // No real covariance is tracked here - report a wide placeholder
      // rather than a misleadingly precise (and un-earned) small number.
      depthUncertaintyMeters: 20000.0,
      originTimeUs: originTimeUs,
      horizontalUncertaintyMeters: 20000.0,
      sourceAmplitudeScale: _currentA0,
      associatedNodeIds: _associated.map((a) => a.obs.nodeId).toList(),
      methodLabel: methodLabel,
      maturity: maturity,
    );
  }
}
