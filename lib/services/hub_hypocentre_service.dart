import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../pipeline/hub_isolate_entry.dart';
import '../pipeline/hub_pipeline.dart';
import '../processing/isolate_messages.dart';

/// Owns the hub math isolate (association gate + method selector +
/// recursive estimator + per-event feedback state - stages 3 through 5).
/// The hub doesn't do continuous sensor polling itself, but running its
/// (occasionally non-trivial - grid re-weighting) computation off the UI
/// isolate keeps the map/telemetry UI from ever stuttering while an
/// estimate refines, in the same spirit as fix #5's node-side isolate.
///
/// On web, dart:isolate spawning isn't supported at all (Flutter's own
/// docs say plainly: "Dart web platforms, including Flutter web, don't
/// support isolates"), so this falls back to running the exact same
/// HubPipeline logic directly on the main isolate instead of spawning a
/// worker. It's the same computation either way - the only thing web
/// loses is the off-UI-thread partitioning fix #5 asks for, which doesn't
/// have a meaningful native alternative on that platform anyway.
class HubHypocentreService {
  Isolate? _isolate;
  SendPort? _workerSendPort;
  ReceivePort? _mainReceivePort;
  HubPipeline? _inlinePipeline;

  final _estimateController = StreamController<EstimateUpdateMsg>.broadcast();
  Stream<EstimateUpdateMsg> get onEstimateUpdate => _estimateController.stream;

  final _expiredController = StreamController<String>.broadcast();
  Stream<String> get onEventExpired => _expiredController.stream;

  Future<void> start() async {
    if (kIsWeb) {
      _inlinePipeline = HubPipeline();
      return;
    }

    _mainReceivePort = ReceivePort();
    _isolate = await Isolate.spawn(hubIsolateEntry, _mainReceivePort!.sendPort);

    final handshakeCompleter = Completer<void>();
    _mainReceivePort!.listen((dynamic message) {
      if (message is SendPort) {
        if (!handshakeCompleter.isCompleted) {
          _workerSendPort = message;
          handshakeCompleter.complete();
        }
        return;
      }
      if (message is EstimateUpdateMsg) {
        if (!_estimateController.isClosed) _estimateController.add(message);
      } else if (message is EventExpiredMsg) {
        if (!_expiredController.isClosed) _expiredController.add(message.eventId);
      }
    });
    await handshakeCompleter.future;
  }

  void ingestObservation(Map<String, dynamic> json) {
    final pipeline = _inlinePipeline;
    if (pipeline != null) {
      final update = pipeline.ingest(json);
      if (update != null && !_estimateController.isClosed) {
        final est = update.estimate;
        _estimateController.add(EstimateUpdateMsg(
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
      return;
    }
    _workerSendPort?.send(ObservationMsg(json));
  }

  void purgeStaleEvents({Duration maxAge = const Duration(minutes: 10)}) {
    final pipeline = _inlinePipeline;
    if (pipeline != null) {
      final nowUs = DateTime.now().microsecondsSinceEpoch;
      final expiredIds = pipeline.purgeStale(nowUs, maxAge.inMicroseconds);
      for (final id in expiredIds) {
        if (!_expiredController.isClosed) _expiredController.add(id);
      }
      return;
    }
    _workerSendPort?.send(PurgeStaleEventsMsg(
      DateTime.now().microsecondsSinceEpoch,
      maxAge.inMicroseconds,
    ));
  }

  void dispose() {
    if (_inlinePipeline == null) {
      _workerSendPort?.send(const ShutdownMsg());
      _mainReceivePort?.close();
      _isolate?.kill(priority: Isolate.immediate);
    }
    _estimateController.close();
    _expiredController.close();
  }
}
