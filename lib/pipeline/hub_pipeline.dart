import '../models/seismic_models.dart';
import 'association_gate.dart';
import 'seismic_event.dart';

String newEventId(int seedUs, String seedNodeId) => 'ev_${seedUs}_$seedNodeId';

/// The reusable core of stages 3-5 for the hub side: keeps all currently
/// active SeismicEvents in memory, associates each incoming observation
/// (stage 3), feeds it to the matched or newly-seeded event (stages 4-5),
/// and prunes events that have gone quiet.
///
/// Deliberately plain Dart with no isolate/SendPort awareness of its own -
/// hub_isolate_entry.dart wraps this in the message-passing protocol for
/// native platforms, and HubHypocentreService calls it directly (no
/// isolate at all) on web, where dart:isolate spawning genuinely isn't
/// supported. Keeping the actual pipeline logic in exactly one place means
/// the web and native code paths can't silently drift apart.
class HubPipeline {
  final List<SeismicEvent> activeEvents = [];

  /// Feeds one observation through stages 3-5 and returns the resulting
  /// estimate update, or null in the (normally unreachable) case that a
  /// freshly seeded or updated event has no estimate yet.
  EstimateUpdate? ingest(Map<String, dynamic> json) {
    final obs = TriggerObservation.fromJson(json);
    final matched = AssociationGate.findAssociation(obs, activeEvents);

    final bool isNewEvent;
    final SeismicEvent event;
    if (matched != null) {
      matched.ingest(obs);
      event = matched;
      isNewEvent = false;
    } else {
      final id = newEventId(obs.arrivalTimeUs, obs.nodeId);
      event = SeismicEvent.seed(id, obs);
      activeEvents.add(event);
      isNewEvent = true;
    }

    final est = event.latestEstimate;
    if (est == null) return null;
    return EstimateUpdate(estimate: est, isNewEvent: isNewEvent);
  }

  /// Removes events that haven't updated within [maxAgeUs] of [nowUs] and
  /// returns their ids.
  List<String> purgeStale(int nowUs, int maxAgeUs) {
    final stale = activeEvents.where((e) => (nowUs - e.lastUpdatedUs) > maxAgeUs).toList();
    for (final e in stale) {
      activeEvents.remove(e);
    }
    return stale.map((e) => e.id).toList();
  }
}

/// Plain-Dart pairing of an estimate with whether it just seeded a new
/// event - the isolate protocol (EstimateUpdateMsg) and the direct-call
/// web path both derive from this same shape.
class EstimateUpdate {
  final HypocentreEstimate estimate;
  final bool isNewEvent;
  const EstimateUpdate({required this.estimate, required this.isNewEvent});
}
