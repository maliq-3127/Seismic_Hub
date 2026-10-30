import 'dart:async';

import 'package:firebase_database/firebase_database.dart';

/// Addresses the "network/clock desync between nodes" edge case named in
/// the spec: phones' system clocks aren't guaranteed to agree, and the
/// association gate's time bound and the estimator's arrival-time
/// likelihood both assume arrival timestamps are on a common clock.
///
/// Standard NTP-style round trip: write ServerValue.timestamp (a sentinel
/// the Realtime Database replaces with its own clock on write), read back
/// what was actually stored, and assume the server wrote it roughly at the
/// midpoint of the round trip. Repeated periodically (device clocks can
/// drift slowly over a multi-hour session) and averaged a little so one
/// unlucky slow request doesn't swing the correction.
class ClockSyncService {
  final DatabaseReference _syncRef;
  double _offsetMs = 0.0;
  bool _hasSynced = false;
  Timer? _timer;

  ClockSyncService(String nodeId) : _syncRef = FirebaseDatabase.instance.ref('clock_sync/$nodeId');

  double get offsetMs => _offsetMs;
  bool get hasSynced => _hasSynced;

  Future<void> start({Duration interval = const Duration(minutes: 5)}) async {
    await _sync();
    _timer = Timer.periodic(interval, (_) => _sync());
  }

  Future<void> _sync() async {
    try {
      final sendLocalMs = DateTime.now().millisecondsSinceEpoch;
      await _syncRef.set(ServerValue.timestamp);
      final snapshot = await _syncRef.get();
      final receiveLocalMs = DateTime.now().millisecondsSinceEpoch;

      final serverMs = (snapshot.value as num?)?.toInt();
      if (serverMs == null) return;

      final roundTripMs = receiveLocalMs - sendLocalMs;
      final estimatedLocalAtServerWrite = sendLocalMs + roundTripMs / 2.0;
      final newOffset = serverMs - estimatedLocalAtServerWrite;

      // Light smoothing across sync attempts rather than snapping straight
      // to the latest one-off measurement.
      _offsetMs = _hasSynced ? (_offsetMs * 0.5 + newOffset * 0.5) : newOffset;
      _hasSynced = true;
    } catch (_) {
      // Transient network/permission failure - keep the previous estimate
      // (a slightly stale correction is better than discarding it).
    }
  }

  int correctedMicros(int localMicros) {
    return localMicros + (_offsetMs * 1000).round();
  }

  void dispose() {
    _timer?.cancel();
  }
}
