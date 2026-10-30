import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../models/seismic_models.dart';
import '../sensors/surface_classifier.dart';
import 'seismic_event.dart';
import 'velocity_model.dart';

/// Stage 3 of the pipeline. Two independent bounds must both be satisfied
/// for an incoming trigger to join an existing event:
///
///  - Time bound: nothing legitimate arrives earlier than the fastest
///    plausible phase moving at its fastest plausible velocity would allow
///    from the current hypocentre estimate, or later than the slowest
///    relevant phase's lower-bound velocity would allow. The two constants
///    below are deliberately generous (fast P upper bound / slow
///    surface-wave lower bound) - this bound exists to rule out obvious
///    impossibilities, not to finely discriminate phases (phase ID already
///    does that per node).
///
///  - Amplitude bound: derived *per event* from the amplitude actually
///    observed at the seeding node(s) - never a fixed, pre-computed radius,
///    since a stronger source is detectable farther out. A candidate node
///    is rejected only if the event's implied source strength makes a
///    detection at that node's distance implausible; it is not required to
///    exactly match, since geometric-spreading exponents and site effects
///    are only roughly known for a proof of concept - see ARCHITECTURE.md.
class AssociationGate {
  static const double maxPlausiblePhaseVelocityMps = 8000.0; // fast P upper bound
  static const double minPlausiblePhaseVelocityMps = 1500.0; // slow surface-wave lower bound
  static const double amplitudeSpreadingExponent = 1.0; // simple geometric spreading
  static const double amplitudeFloorToleranceFactor = 3.0;
  static const double amplitudeImplausibilityFactor = 0.1;

  static const Distance _distance = Distance();

  static double metersBetween(double lat1, double lon1, double lat2, double lon2) {
    return _distance.as(LengthUnit.Meter, LatLng(lat1, lon1), LatLng(lat2, lon2));
  }

  static double correctedAmplitude(TriggerObservation obs) {
    return obs.surfaceType == SurfaceType.soft
        ? obs.amplitude * SurfaceClassifier.softSurfaceAmplitudeCorrection
        : obs.amplitude;
  }

  /// Returns the event this observation should join, or null to seed a new
  /// one (multiple concurrent events are supported this way - see
  /// ARCHITECTURE.md's note on simultaneous nearby events). When more than
  /// one active event's bounds both admit this observation, the one whose
  /// phase-aware predicted arrival time is closest to what was actually
  /// observed wins - not whichever happens to be first in the list.
  ///
  /// A node that already contributed to a candidate event is only allowed
  /// to contribute to it *again* when this new observation is explicitly
  /// flagged, by that node's own local phase tracker, as the S-phase
  /// continuation of the trigger already on record (obs.sMinusPSeconds !=
  /// null - see node_processor.dart's P-then-S tracking). Without that
  /// flag, a second trigger from a node already in the event is treated as
  /// unrelated to it, no matter how well it happens to fit the time/
  /// amplitude bounds, and that event is skipped for this observation -
  /// otherwise a node's second, unconnected trigger would get folded into
  /// an event it has no real bearing on, double-counted as if it were
  /// independent corroboration from a whole separate sensor.
  static SeismicEvent? findAssociation(TriggerObservation obs, List<SeismicEvent> activeEvents) {
    SeismicEvent? best;
    double bestResidualSeconds = double.infinity;

    for (final event in activeEvents) {
      final alreadyHasThisNode = event.observations.any((o) => o.nodeId == obs.nodeId);
      if (alreadyHasThisNode && obs.sMinusPSeconds == null) continue;

      final est = event.latestEstimate;
      if (est == null) continue;

      final r = metersBetween(est.latitude, est.longitude, obs.latitude, obs.longitude);
      final earliestUs = est.originTimeUs + (r / maxPlausiblePhaseVelocityMps) * 1e6;
      final latestUs = est.originTimeUs + (r / minPlausiblePhaseVelocityMps) * 1e6;
      if (obs.arrivalTimeUs < earliestUs || obs.arrivalTimeUs > latestUs) continue;

      final predictedAtR = est.sourceAmplitudeScale / math.pow(math.max(r, 1.0), amplitudeSpreadingExponent);
      final minDetectable = obs.noiseFloorAtTrigger * amplitudeFloorToleranceFactor;
      if (predictedAtR < minDetectable * amplitudeImplausibilityFactor) continue;

      // Both bounds passed - score the fit using a real, phase-aware
      // predicted arrival time (same velocity model the estimator itself
      // uses), not just "is it somewhere inside the wide bound".
      final predictedTravelSeconds = r / velocityForPhase(obs.phase);
      final predictedArrivalUs = est.originTimeUs + predictedTravelSeconds * 1e6;
      final residualSeconds = ((obs.arrivalTimeUs - predictedArrivalUs) / 1e6).abs();

      if (residualSeconds < bestResidualSeconds) {
        bestResidualSeconds = residualSeconds;
        best = event;
      }
    }
    return best;
  }

  /// A0 in A(r) = A0 / r^n, derived from the seeding node so later nodes are
  /// judged against what THIS source actually produced, not a fixed radius.
  static double impliedSourceAmplitudeScale(TriggerObservation seedObs, double distanceFromEstimateMeters) {
    final r = math.max(distanceFromEstimateMeters, 1.0);
    return correctedAmplitude(seedObs) * math.pow(r, amplitudeSpreadingExponent);
  }
}
