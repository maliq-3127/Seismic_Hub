import 'dart:isolate';

import 'hub_pipeline.dart';
import '../processing/isolate_messages.dart';

/// Entry point for the hub's math isolate (native platforms only - see
/// services/hub_hypocentre_service.dart for the web fallback, since
/// dart:isolate spawning isn't supported on Flutter web). All the actual
/// association/estimation logic lives in HubPipeline; this function is
/// just the SendPort/ReceivePort plumbing around it.
///
/// Design choice worth being explicit about (see ARCHITECTURE.md): this
/// runs independently per Hub app instance, computing purely from the same
/// raw per-node observation stream every Hub subscribes to. Nothing here
/// coordinates between multiple simultaneous Hub viewers through Firebase -
/// for the single-viewer proof-of-concept this app is built for, that
/// coordination would add real complexity (shared mutable event state,
/// transactions, conflict resolution) for a problem that doesn't exist yet.
void hubIsolateEntry(SendPort mainSendPort) {
  final workerReceivePort = ReceivePort();
  mainSendPort.send(workerReceivePort.sendPort);

  final pipeline = HubPipeline();

  workerReceivePort.listen((dynamic message) {
    if (message is ObservationMsg) {
      final update = pipeline.ingest(message.json);
      if (update != null) {
        final est = update.estimate;
        mainSendPort.send(EstimateUpdateMsg(
          eventId: est.eventId,
          latitude: est.latitude,
          longitude: est.longitude,
          depthMeters: est.depthMeters,
          depthUncertaintyMeters: est.depthUncertaintyMeters,
          originTimeUs: est.originTimeUs,
          horizontalUncertaintyMeters: est.horizontalUncertaintyMeters,
          associatedNodeIds: est.associatedNodeIds,
          methodLabel: est.methodLabel,
          maturity: est.maturity,
          isNewEvent: update.isNewEvent,
        ));
      }
    } else if (message is PurgeStaleEventsMsg) {
      final expiredIds = pipeline.purgeStale(message.nowUs, message.maxAgeUs);
      for (final id in expiredIds) {
        mainSendPort.send(EventExpiredMsg(id));
      }
    } else if (message is ShutdownMsg) {
      workerReceivePort.close();
    }
  });
}
