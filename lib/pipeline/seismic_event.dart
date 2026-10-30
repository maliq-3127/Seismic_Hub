import '../models/seismic_models.dart';
import 'hypocentre_estimator.dart';
import 'method_selector.dart';

/// Stage 5 (feedback loop) made concrete: this class - specifically its
/// [latestEstimate] - is the state that persists between node arrivals for
/// one event. What gets updated on every [ingest] call is exactly:
///  - the observation list (used to recompute the method-selection trust
///    map, since a newly-associated node can shift which decision-table
///    cell applies);
///  - the estimator's internal candidate weights / point estimate;
///  - [latestEstimate] itself, which association_gate.dart reads to bound
///    the *next* incoming trigger's time and amplitude window - closing the
///    loop described in the spec ("the updated hypocentre estimate refines
///    the time/amplitude envelope the association gate uses to judge the
///    next incoming trigger").
class SeismicEvent {
  final String id;
  final List<TriggerObservation> observations = [];
  final HypocentreStrategy estimator;
  int lastUpdatedUs;
  MethodSelection? lastSelection;
  HypocentreEstimate? latestEstimate;

  SeismicEvent._(this.id, this.estimator, this.lastUpdatedUs);

  /// Builds a fresh event from its first observation. [useLighterFallback]
  /// switches the whole event onto RecursiveWeightedLeastSquares instead of
  /// the default Bayesian grid - see hypocentre_estimator.dart for when
  /// that trade-off might be worth it (it isn't, by default, for this POC).
  factory SeismicEvent.seed(String id, TriggerObservation first, {bool useLighterFallback = false}) {
    final selection = MethodSelector.select([first]);
    final trust = selection.trustByNodeId[first.nodeId]!;
    final HypocentreStrategy estimator = useLighterFallback
        ? RecursiveWeightedLeastSquares.seed(first, trust)
        : HypocentreEstimator.seed(first, trust);

    final event = SeismicEvent._(id, estimator, first.arrivalTimeUs);
    event.observations.add(first);
    event.lastSelection = selection;
    event.latestEstimate = estimator.currentEstimate(
      eventId: id,
      methodLabel: selection.methodLabel,
      maturity: selection.maturity,
    );
    return event;
  }

  /// A node's data in this event is a single slot, not a growing list: a
  /// second observation from a node already represented here (its S-phase
  /// follow-up, per association_gate.dart's gating) replaces its earlier
  /// entry instead of being added alongside it, so MethodSelector and the
  /// estimator both see the true count of distinct nodes, never a node
  /// double-counted as if it were independent corroboration.
  void ingest(TriggerObservation obs) {
    observations.removeWhere((o) => o.nodeId == obs.nodeId);
    observations.add(obs);
    final selection = MethodSelector.select(observations);
    lastSelection = selection;
    final trust = selection.trustByNodeId[obs.nodeId]!;
    estimator.addObservation(obs, trust);
    lastUpdatedUs = obs.arrivalTimeUs;
    latestEstimate = estimator.currentEstimate(
      eventId: id,
      methodLabel: selection.methodLabel,
      maturity: selection.maturity,
    );
  }
}
