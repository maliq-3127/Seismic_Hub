import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; 
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart'; 
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:geolocator/geolocator.dart';
import 'dart:math' as math;
import 'dart:async';
import 'firebase_options.dart';
import 'models/seismic_models.dart';
import 'processing/isolate_messages.dart';
import 'sensors/sensor_polling_service.dart';
import 'services/clock_sync_service.dart';
import 'services/throttle_mitigation_service.dart';
import 'services/hub_hypocentre_service.dart';
import 'services/alert_service.dart';
import 'ui/design_system.dart';
import 'ui/instruments.dart';

// ----------------------------------------------------------------------
// HIGH EFFICIENCY BACKGROUND ISOLATE WORKERS
// ----------------------------------------------------------------------

class TectonicLineData {
  final List<List<double>> points; 
  final int colorValue;
  final double minLat;
  final double maxLat;
  final double minLng;
  final double maxLng;

  final Map<double, Polyline> cachedPolylines = {};

  TectonicLineData(
    this.points, 
    this.colorValue, 
    this.minLat, 
    this.maxLat, 
    this.minLng, 
    this.maxLng
  );

  bool isVisible(LatLngBounds viewBounds, double lngOffset) {
    double shiftedMinLng = minLng + lngOffset;
    double shiftedMaxLng = maxLng + lngOffset;

    if (minLat > viewBounds.north || maxLat < viewBounds.south) return false;
    if (shiftedMinLng > viewBounds.east || shiftedMaxLng < viewBounds.west) return false;
    
    return true;
  }
}

const Map<String, int> _stepClassColors = {
  'sub': 0xFFFF5252, 'ccb': 0xFFFFAB40, 'ctf': 0xFF69F0AE, 
  'crb': 0xFF7C4DFF, 'osr': 0xFF448AFF, 'otf': 0xFFB2FF59, 'ocr': 0xFFFF4081
};

int _getStepClassColorValue(String stepClass) {
  return _stepClassColors[stepClass.toLowerCase()] ?? 0xFF9E9E9E;
}

List<TectonicLineData> parseTectonicJsonInBackground(String jsonStr) {
  final decoded = jsonDecode(jsonStr);
  final List<TectonicLineData> result = [];

  if (decoded is Map && decoded['type'] == 'FeatureCollection' && decoded['features'] is List) {
    for (var feature in decoded['features']) {
      if (feature is Map) {
        String stepClass = 'UNKNOWN';
        if (feature['properties'] is Map) {
          stepClass = feature['properties']['STEPCLASS']?.toString() ?? 'UNKNOWN';
        }
        
        int colorVal = _getStepClassColorValue(stepClass);
        double minLat = 90.0, maxLat = -90.0, minLng = 180.0, maxLng = -180.0;
        bool hasBbox = false;

        if (feature['bbox'] is List && feature['bbox'].length >= 4) {
           minLng = (feature['bbox'][0] as num).toDouble();
           minLat = (feature['bbox'][1] as num).toDouble();
           maxLng = (feature['bbox'][2] as num).toDouble();
           maxLat = (feature['bbox'][3] as num).toDouble();
           hasBbox = true;
        }

        if (feature['geometry'] is Map) {
          var geom = feature['geometry'];
          if (geom['type'] == 'LineString' && geom['coordinates'] is List) {
            List<List<double>> points = [];
            for (var pt in geom['coordinates']) {
              if (pt is List && pt.length >= 2) {
                double lng = (pt[0] as num).toDouble();
                double lat = (pt[1] as num).toDouble();
    
                if (!hasBbox) {
                  if (lat < minLat) minLat = lat;
                  if (lat > maxLat) maxLat = lat;
                  if (lng < minLng) minLng = lng;
                  if (lng > maxLng) maxLng = lng;
                }
                points.add([lat, lng]);
              }
            }
            if (points.isNotEmpty) {
              result.add(TectonicLineData(points, colorVal, minLat, maxLat, minLng, maxLng));
            }
          } 
          else if (geom['type'] == 'MultiLineString' && geom['coordinates'] is List) {
            for (var line in geom['coordinates']) {
              if (line is List) {
                List<List<double>> points = [];
                for (var pt in line) {
                  if (pt is List && pt.length >= 2) {
                    double lng = (pt[0] as num).toDouble();
                    double lat = (pt[1] as num).toDouble();
                    
                    if (!hasBbox) {
                      if (lat < minLat) minLat = lat;
                      if (lat > maxLat) maxLat = lat;
                      if (lng < minLng) minLng = lng;
                      if (lng > maxLng) maxLng = lng;
                    }
                    points.add([lat, lng]);
                  }
                }
                if (points.isNotEmpty) {
                  result.add(TectonicLineData(points, colorVal, minLat, maxLat, minLng, maxLng));
                }
              }
            }
          }
        }
      }
    }
  }
  return result;
}

// ----------------------------------------------------------------------
// The single-shot TDOA calculator (fixed 3500 m/s for every phase, required
// readings.length >= 3 globally before doing anything, recomputed from
// scratch and discarded its buffer every time) used to live here. Removed:
// it couldn't produce any estimate below 3 nodes (the spec's 1- and 2-node
// methods need to work too), ignored the P/S phase and azimuth/6C data the
// new node schema provides, and never refined an existing estimate as more
// nodes reported the same event. See pipeline/hypocentre_estimator.dart,
// pipeline/association_gate.dart and pipeline/seismic_event.dart, run
// inside the hub math isolate (pipeline/hub_isolate_entry.dart) and driven
// from HubScreen via services/hub_hypocentre_service.dart.
// ----------------------------------------------------------------------
// REACTIVE TELEMETRY STATE (DECOUPLED FROM UI)
// ----------------------------------------------------------------------
class TelemetryState {
  final List<double> networkPeakWaveform = List.filled(60, 0.0);
  final Map<String, List<double>> nodeWaveforms = {};
  int headIndex = 0;

  void updateWaves(Map<String, double> liveData, double peakMagnitude, Set<String> activeIds) {
    networkPeakWaveform[headIndex] = peakMagnitude;

    for (String id in activeIds) {
      if (!nodeWaveforms.containsKey(id)) {
        nodeWaveforms[id] = List.filled(60, 0.0);
      }
      nodeWaveforms[id]![headIndex] = liveData[id] ?? 0.0;
    }
    
    nodeWaveforms.removeWhere((key, _) => !activeIds.contains(key));
    headIndex = (headIndex + 1) % 60; 
  }
}

// ----------------------------------------------------------------------
// MAIN APP ENTRY POINT
// ----------------------------------------------------------------------
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    if (Firebase.apps.isEmpty) {
      FirebaseOptions options;
      if (kIsWeb) {
        options = DefaultFirebaseOptions.web;
      } else if (defaultTargetPlatform == TargetPlatform.android) {
        options = DefaultFirebaseOptions.android;
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        options = DefaultFirebaseOptions.ios;
      } else if (defaultTargetPlatform == TargetPlatform.windows) {
        options = DefaultFirebaseOptions.windows;
      } else {
        options = DefaultFirebaseOptions.web; 
      }
      await Firebase.initializeApp(options: options);
    }
  } catch (e) {
    debugPrint("Firebase init failed: $e");
  }
  runApp(const SeismicApp());
}

class SeismicApp extends StatelessWidget {
  const SeismicApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'GyroHub',
      theme: Ds.theme(),
      home: const RoleSelectionScreen(),
    );
  }
}

// ----------------------------------------------------------------------
// 1. ROLE SELECTION
// ----------------------------------------------------------------------
class RoleSelectionScreen extends StatelessWidget {
  const RoleSelectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Ds.s6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const StatusDot(Ds.trace, size: 9),
                    const SizedBox(width: Ds.s3),
                    Text('GyroHub', style: Ds.headline),
                  ],
                ),
                const SizedBox(height: Ds.s2),
                Text(
                  'A distributed seismic network built from phone sensors. '
                  'Run this device as a sensing node, or open the console to watch the network.',
                  style: Ds.bodyDim,
                ),
                const SizedBox(height: Ds.s6),
                _RoleCard(
                  icon: Icons.sensors,
                  title: 'Run as a node',
                  body: 'Uses this device\'s accelerometer, gyroscope and compass to watch for ground '
                      'movement and report what it detects.',
                  accent: Ds.trace,
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NodeScreen())),
                ),
                const SizedBox(height: Ds.s3),
                _RoleCard(
                  icon: Icons.desktop_windows_outlined,
                  title: 'Open the console',
                  body: 'Live map, active events and node health across the whole network. Sign-in required.',
                  accent: Ds.nominal,
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HubLoginScreen())),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoleCard extends StatefulWidget {
  final IconData icon;
  final String title;
  final String body;
  final Color accent;
  final VoidCallback onTap;
  const _RoleCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.accent,
    required this.onTap,
  });

  @override
  State<_RoleCard> createState() => _RoleCardState();
}

class _RoleCardState extends State<_RoleCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.all(Ds.s4),
          decoration: BoxDecoration(
            color: _hover ? Ds.panelRaised : Ds.panel,
            border: Border.all(color: _hover ? widget.accent.withValues(alpha: 0.6) : Ds.hairline),
            borderRadius: BorderRadius.circular(Ds.rPanel),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: widget.accent.withValues(alpha: 0.12),
                  border: Border.all(color: widget.accent.withValues(alpha: 0.4)),
                  borderRadius: BorderRadius.circular(Ds.rPanel),
                ),
                child: Icon(widget.icon, color: widget.accent, size: 19),
              ),
              const SizedBox(width: Ds.s4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.title, style: Ds.title),
                    const SizedBox(height: Ds.s1),
                    Text(widget.body, style: Ds.bodyDim),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------
// 2. AUTHENTICATION SYSTEM
// ----------------------------------------------------------------------
class HubLoginScreen extends StatefulWidget {
  const HubLoginScreen({super.key});
  @override
  State<HubLoginScreen> createState() => _HubLoginScreenState();
}

class _HubLoginScreenState extends State<HubLoginScreen> {
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _isLoading = false;

  Future<void> _authenticate({required bool isLogin}) async {
    if (_emailCtrl.text.isEmpty || _passCtrl.text.isEmpty) return;
    
    setState(() => _isLoading = true);
    try {
      if (isLogin) {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: _emailCtrl.text.trim(), 
          password: _passCtrl.text
        );
      } else {
        await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: _emailCtrl.text.trim(), 
          password: _passCtrl.text
        );
      }
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const HubScreen()));
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.message ?? 'Sign-in failed. Check the email and password.', style: Ds.body),
          backgroundColor: Ds.panelRaised,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: Ds.alert),
            borderRadius: BorderRadius.circular(Ds.rPanel),
          ),
        ));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Ds.s5),
            child: InstrumentPanel(
              label: 'Console sign-in',
              padding: const EdgeInsets.all(Ds.s5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Sign in to watch the network', style: Ds.title),
                  const SizedBox(height: Ds.s1),
                  Text('Nodes report anonymously; the console needs an account.', style: Ds.bodyDim),
                  const SizedBox(height: Ds.s5),
                  TextField(
                    controller: _emailCtrl,
                    decoration: const InputDecoration(labelText: 'Email'),
                    keyboardType: TextInputType.emailAddress,
                    style: Ds.body,
                  ),
                  const SizedBox(height: Ds.s3),
                  TextField(
                    controller: _passCtrl,
                    decoration: const InputDecoration(labelText: 'Password'),
                    obscureText: true,
                    style: Ds.body,
                    onSubmitted: (_) => _isLoading ? null : _authenticate(isLogin: true),
                  ),
                  const SizedBox(height: Ds.s5),
                  if (_isLoading)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: Ds.s2),
                        child: SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Ds.nominal),
                        ),
                      ),
                    )
                  else
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () => _authenticate(isLogin: true),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Ds.nominal.withValues(alpha: 0.16),
                              foregroundColor: Ds.nominal,
                            ),
                            child: const Text('Sign in'),
                          ),
                        ),
                        const SizedBox(width: Ds.s3),
                        TextButton(
                          onPressed: () => _authenticate(isLogin: false),
                          child: const Text('Create account'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------
// 3. NODE SCREEN
// ----------------------------------------------------------------------
class NodeScreen extends StatefulWidget {
  const NodeScreen({super.key});
  @override
  State<NodeScreen> createState() => _NodeScreenState();
}

class _NodeScreenState extends State<NodeScreen> with WidgetsBindingObserver {
  late final String nodeID;
  late DatabaseReference _database;
  bool _isStreaming = false;
  bool _isDisabled = false;
  late final SensorPollingService _pollingService;
  late final ClockSyncService _clockSync;
  double _calibrationProgress = 0.0;
  bool _isCalibrating = true;

  LatLng _currentLocation = const LatLng(17.9846, -76.9714);
  Timer? _liveWaveTimer;
  double _currentWaveMagnitude = 0.0;

  SurfaceType _surfaceType = SurfaceType.unknown;
  ChannelDominanceState? _lastChannelState;
  bool _showThrottleBanner = false;

  // Local ring buffer so the node can draw its own live trace instead of
  // only shipping magnitudes off to the console. Fixed length + rolling
  // head so there is no per-frame list allocation.
  static const int _localTraceLength = 120;
  final List<double> _localTrace = List.filled(_localTraceLength, 0.0);
  int _localTraceHead = 0;
  DateTime? _lastTriggerAt;
  int _triggerCount = 0;

  StreamSubscription? _calibSub;
  StreamSubscription? _waveSub;
  StreamSubscription? _triggerSub;
  StreamSubscription? _nodeStatusSub;
  StreamSubscription<Position>? _positionSub;
  StreamSubscription? _sensitivitySub;
  StreamSubscription? _hpfSub;
  StreamSubscription? _statusSub;
  StreamSubscription? _surfaceOverrideSub;
  StreamSubscription? _declinationSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    nodeID = 'node_${math.Random().nextInt(999999)}';
    _database = FirebaseDatabase.instance.ref('sensor_network/$nodeID');
    _clockSync = ClockSyncService(nodeID);
    _pollingService = SensorPollingService(hpfAlpha: 0.9, sensitivityMultiplier: 1.0);

    FirebaseDatabase.instance.ref('nodes_presence/$nodeID').onDisconnect().remove();

    Future.microtask(() async {
      try {
        await FirebaseAuth.instance.signInAnonymously();
        if (mounted) _registerPresence();
      } catch (error) {
        debugPrint("Node Auth Failed: $error");
      }
      await _pollingService.start();
      unawaited(_clockSync.start());
      if (mounted) _maybePromptThrottleMitigation();
    });

    if (kIsWeb || defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) {
      _initGPS();
    }

    _sensitivitySub = FirebaseDatabase.instance.ref('node_settings/$nodeID/sensitivity').onValue.listen((event) {
      if (event.snapshot.value != null && mounted) {
        _pollingService.updateSensitivity((event.snapshot.value as num).toDouble());
        setState(() {});
      }
    });

    _statusSub = FirebaseDatabase.instance.ref('node_settings/$nodeID/is_disabled').onValue.listen((event) {
      if (mounted) {
        setState(() {
          _isDisabled = (event.snapshot.value == true);
          if (_isDisabled && _isStreaming) {
            _toggleStreaming(false);
          }
        });
      }
    });

    _hpfSub = FirebaseDatabase.instance.ref('global_settings/hpf_alpha').onValue.listen((event) {
      if (event.snapshot.value != null && mounted) {
        _pollingService.updateHpfAlpha((event.snapshot.value as num).toDouble());
      }
    });

    // Fix #1: lets a hub operator correct the automatic hard/soft surface
    // classifier for this node ('unknown' = trust the automatic heuristic).
    _surfaceOverrideSub =
        FirebaseDatabase.instance.ref('node_settings/$nodeID/surface_override').onValue.listen((event) {
      if (mounted) {
        final raw = event.snapshot.value?.toString() ?? 'unknown';
        final type = SurfaceType.values.firstWhere((s) => s.name == raw, orElse: () => SurfaceType.unknown);
        _pollingService.updateManualSurfaceOverride(type);
      }
    });

    // A single region-wide declination constant, not a per-node World
    // Magnetic Model - see CompassOrientation / ARCHITECTURE.md.
    _declinationSub =
        FirebaseDatabase.instance.ref('global_settings/magnetic_declination_deg').onValue.listen((event) {
      if (event.snapshot.value != null && mounted) {
        _pollingService.updateDeclination((event.snapshot.value as num).toDouble());
      }
    });

    _calibSub = _pollingService.onCalibrationProgress.listen((progress) {
      if (mounted) {
        setState(() {
          _calibrationProgress = progress;
          _isCalibrating = progress < 1.0;
        });
      }
    });

    _waveSub = _pollingService.onLiveWave.listen((mag) {
      if (mounted) _currentWaveMagnitude = mag;
    });

    _nodeStatusSub = _pollingService.onStatusChanged.listen((NodeStatusMsg status) {
      if (mounted) {
        setState(() {
          _surfaceType = status.surfaceType;
          if (status.lastChannelState != null) _lastChannelState = status.lastChannelState;
        });
      }
    });

    _triggerSub = _pollingService.onTriggerDetected.listen((TriggerDetectedMsg trigger) {
      if (_isStreaming && !_isDisabled && mounted) {
        final correctedUs = _clockSync.correctedMicros(trigger.deviceLocalArrivalTimeUs);
        final observation = TriggerObservation(
          nodeId: nodeID,
          latitude: _currentLocation.latitude,
          longitude: _currentLocation.longitude,
          arrivalTimeUs: correctedUs,
          phase: trigger.phase,
          amplitude: trigger.amplitude,
          azimuthDegrees: trigger.azimuthDegrees,
          azimuthUncertaintyDegrees: trigger.azimuthUncertaintyDegrees,
          azimuthResolved: trigger.azimuthResolved,
          apparentVelocityMps: trigger.apparentVelocityMps,
          sMinusPSeconds: trigger.sMinusPSeconds,
          channelState: trigger.channelState,
          accelerometerSaturated: trigger.accelerometerSaturated,
          surfaceType: trigger.surfaceType,
          noiseFloorAtTrigger: trigger.noiseFloorAtTrigger,
        );

        setState(() {
          _lastChannelState = trigger.channelState;
          _surfaceType = trigger.surfaceType;
          _lastTriggerAt = DateTime.now();
          _triggerCount++;
        });

        _database.set(observation.toJson());
        FirebaseDatabase.instance.ref('telemetry_history').push().set({
          ...observation.toJson(),
          'date_string': DateTime.now().toIso8601String(),
        });
      }
    });
  }

  Future<void> _maybePromptThrottleMitigation() async {
    final likely = await ThrottleMitigationService.isLikelyThrottled();
    if (mounted) setState(() => _showThrottleBanner = likely);
  }

  void _registerPresence() {
    if (!mounted) return;
    final presenceRef = FirebaseDatabase.instance.ref('nodes_presence/$nodeID');
    presenceRef.set({
      'lat': _currentLocation.latitude,
      'lng': _currentLocation.longitude,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _pollingService.pause();
      _liveWaveTimer?.cancel();
    } else if (state == AppLifecycleState.resumed) {
      _pollingService.resume();
      if (_isStreaming && !_isDisabled) {
        _startLiveWaveTimer();
      }
    }
  }

  Future<void> _initGPS() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return;
      }

      _positionSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 2)
      ).listen((Position position) {
        if (mounted) {
          setState(() {
            _currentLocation = LatLng(position.latitude, position.longitude);
          });
          _registerPresence(); 
        }
      },
      onError: (Object error) => debugPrint("Node GPS Stream Error Absorbed: $error"),
      cancelOnError: false,
      );
    } catch (e) {
      debugPrint("GPS Retrieval Error: $e");
    }
  }

  void _startLiveWaveTimer() {
    _liveWaveTimer?.cancel();
    final liveRef = FirebaseDatabase.instance.ref('live_waves/$nodeID');
    try {
      liveRef.onDisconnect().remove();
    } catch (_) {}

    _liveWaveTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (mounted) {
        liveRef.set({
          'mag': _currentWaveMagnitude,
          'ts': DateTime.now().millisecondsSinceEpoch,
        });
        setState(() {
          _localTrace[_localTraceHead] = _currentWaveMagnitude;
          _localTraceHead = (_localTraceHead + 1) % _localTraceLength;
        });
      }
    });
  }

  void _toggleStreaming(bool val) {
    if (_isDisabled && val) return;
    if (!mounted) return;

    setState(() {
      _isStreaming = val;
      final liveRef = FirebaseDatabase.instance.ref('live_waves/$nodeID');
      
      if (_isStreaming) {
        _pollingService.forceRecalibration();
        _isCalibrating = true;
        _startLiveWaveTimer();
        _registerPresence();
      } else {
        _liveWaveTimer?.cancel();
        try {
          liveRef.onDisconnect().cancel();
        } catch (_) {}
        liveRef.remove();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    
    _positionSub?.cancel();
    _sensitivitySub?.cancel();
    _hpfSub?.cancel();
    _statusSub?.cancel();
    _surfaceOverrideSub?.cancel();
    _declinationSub?.cancel();
    _calibSub?.cancel();
    _waveSub?.cancel();
    _triggerSub?.cancel();
    _nodeStatusSub?.cancel();
    _liveWaveTimer?.cancel();

    _positionSub = null;
    _sensitivitySub = null;
    _hpfSub = null;
    _statusSub = null;
    _surfaceOverrideSub = null;
    _declinationSub = null;
    _calibSub = null;
    _waveSub = null;
    _triggerSub = null;
    _nodeStatusSub = null;
    _liveWaveTimer = null;

    FirebaseDatabase.instance.ref('nodes_presence/$nodeID').remove();
    final liveRef = FirebaseDatabase.instance.ref('live_waves/$nodeID');
    try {
      liveRef.onDisconnect().cancel();
    } catch (_) {}
    liveRef.remove();

    _clockSync.dispose();
    _pollingService.dispose();
    super.dispose();
  }

  // -- Node UI ---------------------------------------------------------

  Color get _stateColor {
    if (_isDisabled) return Ds.alert;
    if (!_isStreaming) return Ds.inert;
    if (_isCalibrating) return Ds.caution;
    return Ds.nominal;
  }

  String get _stateLabel {
    if (_isDisabled) return 'Disabled from console';
    if (!_isStreaming) return 'Standby';
    if (_isCalibrating) return 'Calibrating';
    return 'Watching';
  }

  String get _stateExplanation {
    if (_isDisabled) return 'An operator turned this node off. It will not report until re-enabled.';
    if (!_isStreaming) return 'Sensors are idle. Start reporting to join the network.';
    if (_isCalibrating) return 'Learning the background vibration here so real movement stands out from it.';
    return 'Reporting to the network. Leave the device still on its surface.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: Ds.s4,
        title: Row(
          children: [
            StatusDot(_stateColor, size: 8),
            const SizedBox(width: Ds.s3),
            Text('Node', style: Ds.title),
            const SizedBox(width: Ds.s2),
            Text(nodeID, style: Ds.mono(size: 12, color: Ds.inkMuted)),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: Ds.s4),
            child: Center(child: Text(_stateLabel, style: Ds.mono(size: 12, color: _stateColor))),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Ds.s4),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_showThrottleBanner) ...[
                    _NoticeBar(
                      color: Ds.caution,
                      icon: Icons.battery_alert_outlined,
                      message: 'Battery optimisation can throttle sensor sampling during long sessions.',
                      actionLabel: 'Open settings',
                      onAction: () async {
                        await ThrottleMitigationService.requestMitigation();
                        _maybePromptThrottleMitigation();
                      },
                    ),
                    const SizedBox(height: Ds.s3),
                  ],
                  if (_isDisabled) ...[
                    const _NoticeBar(
                      color: Ds.alert,
                      icon: Icons.block,
                      message: 'This node was disabled from the console. It will not report until re-enabled.',
                    ),
                    const SizedBox(height: Ds.s3),
                  ],

                  InstrumentPanel(
                    label: 'Status',
                    accent: _isStreaming && !_isDisabled ? _stateColor : null,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                color: _stateColor.withValues(alpha: 0.12),
                                border: Border.all(color: _stateColor.withValues(alpha: 0.5)),
                                borderRadius: BorderRadius.circular(Ds.rPanel),
                              ),
                              child: Icon(
                                _isDisabled
                                    ? Icons.block
                                    : _isCalibrating
                                        ? Icons.tune
                                        : Icons.sensors,
                                color: _stateColor,
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: Ds.s4),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(_stateLabel, style: Ds.title.copyWith(color: _stateColor)),
                                  const SizedBox(height: 2),
                                  Text(_stateExplanation, style: Ds.bodyDim),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (_isCalibrating && _isStreaming) ...[
                          const SizedBox(height: Ds.s4),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(value: _calibrationProgress.clamp(0.0, 1.0)),
                          ),
                          const SizedBox(height: Ds.s2),
                          Text(
                            '${(_calibrationProgress.clamp(0.0, 1.0) * 100).toStringAsFixed(0)}% complete',
                            style: Ds.mono(size: 11.5, color: Ds.inkMuted),
                          ),
                        ],
                        const SizedBox(height: Ds.s4),
                        const PanelRule(),
                        const SizedBox(height: Ds.s3),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _isStreaming ? 'Reporting to network' : 'Not reporting',
                                style: Ds.body,
                              ),
                            ),
                            Switch(
                              value: _isStreaming,
                              onChanged: _isDisabled ? null : _toggleStreaming,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Ds.s3),

                  InstrumentPanel(
                    label: 'Live motion',
                    trailing: Text(
                      _currentWaveMagnitude.toStringAsFixed(4),
                      style: Ds.mono(size: 11, color: Ds.trace),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TraceView(data: _localTrace, headIndex: _localTraceHead, height: 104),
                        const SizedBox(height: Ds.s2),
                        Text(
                          'Filtered acceleration, gravity removed. Flat is good - spikes are what gets reported.',
                          style: Ds.label,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Ds.s3),

                  InstrumentPanel(
                    label: 'Sensing conditions',
                    child: Wrap(
                      spacing: Ds.s5,
                      runSpacing: Ds.s4,
                      children: [
                        Readout(
                          label: 'Resting surface',
                          value: _surfaceType == SurfaceType.unknown ? null : _surfaceType.name,
                          unresolvedNote: 'not classified yet',
                          valueColor: _surfaceType == SurfaceType.soft ? Ds.caution : Ds.ink,
                        ),
                        Readout(
                          label: 'Sensors in use',
                          value: _lastChannelState == null
                              ? null
                              : (_lastChannelState == ChannelDominanceState.bothChannelsUsable
                                  ? 'accel + gyro'
                                  : 'accel only'),
                          unresolvedNote: 'no movement yet',
                        ),
                        Readout(
                          label: 'Detections',
                          value: '$_triggerCount',
                          uncertainty: null,
                        ),
                        Readout(
                          label: 'Last detection',
                          value: _lastTriggerAt == null
                              ? null
                              : '${DateTime.now().difference(_lastTriggerAt!).inSeconds}s ago',
                          unresolvedNote: 'none this session',
                        ),
                        Readout(
                          label: 'Sensitivity',
                          value: _pollingService.sensitivityMultiplier.toStringAsFixed(2),
                          unit: 'x',
                        ),
                        Readout(
                          label: 'Position',
                          value: '${_currentLocation.latitude.toStringAsFixed(3)}, '
                              '${_currentLocation.longitude.toStringAsFixed(3)}',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Ds.s3),
                  Text(
                    _surfaceType == SurfaceType.soft
                        ? 'Soft surfaces damp vibration, so readings from here are weighted lower. '
                            'A hard flat surface gives the network better data.'
                        : 'Keep the device still and flat. Picking it up registers as movement.',
                    style: Ds.label,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: Ds.s5),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Inline notice bar - states what happened and what to do about it,
/// without apologising or going vague.
class _NoticeBar extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _NoticeBar({
    required this.color,
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Ds.s3, vertical: Ds.s3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(Ds.rPanel),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: Ds.s3),
          Expanded(child: Text(message, style: Ds.body.copyWith(fontSize: 12.5))),
          if (actionLabel != null) ...[
            const SizedBox(width: Ds.s2),
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(foregroundColor: color, padding: const EdgeInsets.symmetric(horizontal: Ds.s2)),
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------------
// 4. THE HUB WITH TRUE TDOA AND DECOUPLED STATE ARCHITECTURE
// ----------------------------------------------------------------------
enum MapItemType { hub, node, epicenter }

class MapItemData {
  final String id;
  final LatLng loc;
  final MapItemType type;
  final String tooltipMessage;

  MapItemData({
    required this.id,
    required this.loc,
    required this.type,
    required this.tooltipMessage,
  });
}

/// Reports hover (desktop/web) and tap (all platforms, notably touch,
/// where hover never fires) up to whoever owns [isActive] - used to
/// highlight a marker's uncertainty circle without the circle itself
/// living inside this widget (it's drawn as a real CircleLayer on the map
/// instead, so its radius can be a true geographic distance - see
/// _buildUncertaintyCircle). Tap toggles; hover just tracks the pointer,
/// and only clears the highlight if it's still the one that set it, so a
/// mouse crossing directly from one icon to an adjacent one can't have the
/// outgoing icon's exit wipe out the incoming icon's highlight.
class _HoverTapTrigger extends StatelessWidget {
  final Widget child;
  final bool isActive;
  final VoidCallback onActivate;
  final VoidCallback onDeactivateIfActive;

  const _HoverTapTrigger({
    required this.child,
    required this.isActive,
    required this.onActivate,
    required this.onDeactivateIfActive,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => onActivate(),
      onExit: (_) => onDeactivateIfActive(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => isActive ? onDeactivateIfActive() : onActivate(),
        child: child,
      ),
    );
  }
}

class HubScreen extends StatefulWidget {
  const HubScreen({super.key});
  @override
  State<HubScreen> createState() => _HubScreenState();
}

class _HubScreenState extends State<HubScreen> with WidgetsBindingObserver, TickerProviderStateMixin{
  late final DatabaseReference _networkRef;
  late final DatabaseReference _liveRef;

  late AnimationController _waveAnimationController;
  final TelemetryState _telemetryState = TelemetryState();
  final Map<String, Map<String, dynamic>> _nodeLatestEvents = {};
  
  final Map<String, LatLng> _activeNodes = {};
  final Map<String, LatLng> _activeHubs = {};
  final Map<String, double> _nodeSensitivities = {}; 
  final Map<String, bool> _disabledNodes = {}; 

  late final String _hubId;
  
  LatLng _hubLocation = const LatLng(17.9846, -76.9714);
  String _currentMapStyle = 'dataviz-dark';
  String _tectonicResolution = 'low'; 
  
  bool _isTectonicOverlayActive = false;
  bool _isLoadingGeoJson = false;
  List<Polyline> _tectonicLines = [];
  
  bool _isMapMenuExpanded = false;
  final String mapTilerKey = '8e2ryGtHdAUEGhbdshZS';
  double _globalHpfAlpha = 0.9;
  double _globalDeclinationDeg = 0.0;

  // Keyed by event id rather than appended-to, so an epicenter marker
  // refines in place as more nodes associate instead of spawning a new pin
  // every time the estimate updates.
  final Map<String, MapItemData> _epicenterMarkers = {};
  final Map<String, HypocentreEstimate> _activeEstimates = {};
  // Which disturbance icon (by event id) currently has its uncertainty
  // circle shown - hovered on desktop/web, tapped on touch - and the
  // CircleLayer entry _buildAllMarkers() computes for it, using the same
  // render location (post-overlap-spread) as the marker itself so the
  // circle is never a pixel off from the icon it belongs to.
  String? _highlightedEpicenterId;
  CircleMarker? _highlightedCircleMarker;
  List<Marker> _cachedMarkers = [];
  
  final MapController _mapController = MapController();
  bool _isMapReady = false;

  late final HubHypocentreService _hypocentreService;

  late final int _hubBootTimeUs;
  StreamSubscription? _networkAddSub;
  StreamSubscription? _networkChangeSub;
  StreamSubscription? _liveSub;
  StreamSubscription<Position>? _hubPositionSub;
  StreamSubscription? _nodesPresenceSub;
  StreamSubscription? _hubsPresenceSub;
  StreamSubscription? _nodeSettingsSub;
  StreamSubscription? _hpfSettingsSub;
  StreamSubscription? _declinationSettingsSub;
  StreamSubscription? _estimateSub;
  StreamSubscription? _eventExpiredSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _hypocentreService = HubHypocentreService();
    unawaited(_hypocentreService.start());
    unawaited(AlertService.initialize());
    _estimateSub = _hypocentreService.onEstimateUpdate.listen(_handleEstimateUpdate);
    _eventExpiredSub = _hypocentreService.onEventExpired.listen((eventId) {
      if (mounted) {
        setState(() {
          _epicenterMarkers.remove(eventId);
          _activeEstimates.remove(eventId);
          _rebuildCachedMarkers();
        });
      }
    });

    _waveAnimationController = AnimationController(
      vsync: this, 
      duration: const Duration(seconds: 1)
    )..repeat();

    final currentUser = FirebaseAuth.instance.currentUser;
    _hubId = currentUser != null 
        ? 'hub_${currentUser.uid.substring(0, 10)}' 
        : 'hub_${math.Random().nextInt(999999)}';

    _networkRef = FirebaseDatabase.instance.ref('sensor_network');
    _liveRef = FirebaseDatabase.instance.ref('live_waves');
    _hubBootTimeUs = DateTime.now().millisecondsSinceEpoch * 1000;

    FirebaseDatabase.instance.ref('diagnostic_hubs/$_hubId').onDisconnect().remove();
    
    if (kIsWeb || defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) {
      _initHubGPS();
    }
    
    _listenToNetworkPresence();
    _listenToFirebase();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden || state == AppLifecycleState.detached) {
      _networkAddSub?.pause();
      _networkChangeSub?.pause();
      _liveSub?.pause();
      FirebaseDatabase.instance.ref('diagnostic_hubs/$_hubId').remove();
    } else if (state == AppLifecycleState.resumed) {
      _networkAddSub?.resume();
      _networkChangeSub?.resume();
      _liveSub?.resume();
      FirebaseDatabase.instance.ref('diagnostic_hubs/$_hubId').set({
        'lat': _hubLocation.latitude,
        'lng': _hubLocation.longitude,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
    }
  }

  List<TectonicLineData> _masterTectonicData = [];

  Future<void> _reloadTectonicData() async {
    if (!mounted) return;
    setState(() {
      _isLoadingGeoJson = true;
      _tectonicLines.clear(); 
    });
    
    try {
      final String jsonStr = await rootBundle.loadString('assets/PB2002_steps_$_tectonicResolution.geojson');
      _masterTectonicData = await compute(parseTectonicJsonInBackground, jsonStr);
      
      const List<double> longitudeOffsets = [-360.0, 0.0, 360.0];
      for (var data in _masterTectonicData) {
        Color boundColor = Color(data.colorValue);
        for (double offset in longitudeOffsets) {
          data.cachedPolylines[offset] = Polyline(
            points: data.points.map((pt) => LatLng(pt[0], pt[1] + offset)).toList(),
            color: boundColor,
            strokeWidth: 2.0,
          );
        }
      }

      if (_isMapReady && mounted) {
        _updateVisibleLines(_mapController.camera);
      }
    } catch (e) {
      debugPrint("GeoJSON Parse Error: $e");
    } finally {
      if (mounted) setState(() => _isLoadingGeoJson = false);
    }
  }

  void _updateVisibleLines(MapCamera camera) {
    if (!_isTectonicOverlayActive || _masterTectonicData.isEmpty || !mounted) return;

    final bounds = camera.visibleBounds;
    final List<Polyline> visibleLines = [];
    const List<double> longitudeOffsets = [-360.0, 0.0, 360.0];

    for (var data in _masterTectonicData) {
      for (double offset in longitudeOffsets) {
        if (data.isVisible(bounds, offset)) {
          visibleLines.add(data.cachedPolylines[offset]!);
        }
      }
    }

    if (mounted) setState(() => _tectonicLines = visibleLines);
  }

  Future<void> _toggleTectonicGeoJson(bool isActive) async {
    if (!mounted) return;
    setState(() => _isTectonicOverlayActive = isActive);
    if (!isActive) {
      setState(() {
        _tectonicLines.clear();
      });
      return;
    }
    _reloadTectonicData();
  }

  void _rebuildCachedMarkers() {
    if (!mounted) return;
    _cachedMarkers = _buildAllMarkers();
  }

  Future<void> _initHubGPS() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return;
      }

      _hubPositionSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 2)
      ).listen((Position position) {
        if (mounted) {
          setState(() {
            _hubLocation = LatLng(position.latitude, position.longitude);
          });
          
          final hubRef = FirebaseDatabase.instance.ref('diagnostic_hubs/$_hubId');
          hubRef.set({
            'lat': position.latitude,
            'lng': position.longitude,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          });
        }
      },
      onError: (Object error) => debugPrint("Hub GPS Stream Error Absorbed: $error"),
      cancelOnError: false,
      );
    } catch (e) {
      debugPrint("Hub GPS Error: $e");
    }
  }

  void _listenToNetworkPresence() {
    _nodesPresenceSub = FirebaseDatabase.instance.ref('nodes_presence').onValue.listen((event) {
      if (!mounted) return;
      final val = event.snapshot.value as Map?;
      if (val != null) {
        setState(() {
          _activeNodes.clear();
          val.forEach((key, value) {
            if (value is Map) {
              _activeNodes[key.toString()] = LatLng((value['lat'] as num).toDouble(), (value['lng'] as num).toDouble());
            }
          });
          _rebuildCachedMarkers();
        });
      } else {
        setState(() {
           _activeNodes.clear();
           _rebuildCachedMarkers();
        });
      }
    });

    _hubsPresenceSub = FirebaseDatabase.instance.ref('diagnostic_hubs').onValue.listen((event) {
      if (!mounted) return;
      final val = event.snapshot.value as Map?;
      if (val != null) {
        setState(() {
          _activeHubs.clear();
          val.forEach((key, value) {
            if (value is Map) {
              _activeHubs[key.toString()] = LatLng((value['lat'] as num).toDouble(), (value['lng'] as num).toDouble());
            }
          });
          _rebuildCachedMarkers();
        });
      } else {
        setState(() {
          _activeHubs.clear();
          _rebuildCachedMarkers();
        });
      }
    });

    _nodeSettingsSub = FirebaseDatabase.instance.ref('node_settings').onValue.listen((event) {
      if (!mounted) return;
      final val = event.snapshot.value as Map?;
      if (val != null) {
        setState(() {
          val.forEach((key, value) {
             if (value is Map) {
                if (value['sensitivity'] != null) {
                  _nodeSensitivities[key.toString()] = (value['sensitivity'] as num).toDouble();
                }
                if (value['is_disabled'] != null) {
                  _disabledNodes[key.toString()] = value['is_disabled'] == true;
                } else {
                  _disabledNodes[key.toString()] = false;
                }
             }
          });
        });
      }
    });

    _hpfSettingsSub = FirebaseDatabase.instance.ref('global_settings/hpf_alpha').onValue.listen((event) {
      if (!mounted) return;
      if (event.snapshot.value != null) {
        setState(() {
          _globalHpfAlpha = (event.snapshot.value as num).toDouble();
        });
      }
    });

    _declinationSettingsSub =
        FirebaseDatabase.instance.ref('global_settings/magnetic_declination_deg').onValue.listen((event) {
      if (!mounted) return;
      if (event.snapshot.value != null) {
        setState(() {
          _globalDeclinationDeg = (event.snapshot.value as num).toDouble();
        });
      }
    });
  }

  void _showClearHistoryDialog(BuildContext context) {
    String selectedRange = '24_hours';

    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: Ds.panel,
              shape: RoundedRectangleBorder(
                side: const BorderSide(color: Colors.white10),
                borderRadius: BorderRadius.circular(12),
              ),
              title: const Row(
                children: [
                  Icon(Icons.delete_sweep_outlined, color: Ds.alert),
                  SizedBox(width: 10),
                  Text("Clear History", style: TextStyle(color: Colors.white)),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Select the timeframe of records you wish to purge:",
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: selectedRange, 
                    dropdownColor: const Color(0xFF222230),
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      labelText: "Time Period",
                      labelStyle: TextStyle(color: Ds.inkDim),
                    ),
                    items: const [
                      DropdownMenuItem(value: '24_hours', child: Text("Older than 24 Hours")),
                      DropdownMenuItem(value: '7_days', child: Text("Older than 7 Days")),
                      DropdownMenuItem(value: '30_days', child: Text("Older than 30 Days")),
                      DropdownMenuItem(value: 'all', child: Text("All Time (Full Reset)")),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setDialogState(() => selectedRange = val);
                      }
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Ds.alert.withValues(alpha: 0.18), foregroundColor: Ds.alert),
                  onPressed: () {
                    Navigator.of(dialogContext).pop();
                    if (mounted) _showConfirmationDialog(context, selectedRange);
                  },
                  child: const Text("PROCEED", style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _purgeInactiveDevices() async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    const int timeoutMs = 60000; 

    try {
      final nodesSnap = await FirebaseDatabase.instance.ref('nodes_presence').get();
      if (nodesSnap.exists && nodesSnap.value != null) {
        final mapVal = nodesSnap.value;
        if (mapVal is Map) {
          for (var key in mapVal.keys) {
            final nodeData = mapVal[key];
            if (nodeData is Map && nodeData['timestamp'] != null) {
              int ts = (nodeData['timestamp'] as num).toInt();
              if (now - ts > timeoutMs) {
                await FirebaseDatabase.instance.ref('nodes_presence/$key').remove();
              }
            }
          }
        }
      }

      final hubsSnap = await FirebaseDatabase.instance.ref('diagnostic_hubs').get();
      if (hubsSnap.exists && hubsSnap.value != null) {
        final mapVal = hubsSnap.value;
        if (mapVal is Map) {
          for (var key in mapVal.keys) {
            if (key.toString() == _hubId) continue; 
            
            final hubData = mapVal[key];
            if (hubData is Map && hubData['timestamp'] != null) {
              int ts = (hubData['timestamp'] as num).toInt();
              if (now - ts > timeoutMs) {
                await FirebaseDatabase.instance.ref('diagnostic_hubs/$key').remove();
              }
            }
          }
        }
      }

      if (mounted) {
        setState(() {
          _epicenterMarkers.clear();
          _activeEstimates.clear();
          _rebuildCachedMarkers();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Inactive devices safely removed from the network."),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      debugPrint("Purge error: $e");
    }
  }

  void _showConfirmationDialog(BuildContext context, String range) {
    String rangeLabel = "";
    switch (range) {
      case '24_hours': rangeLabel = "records older than 24 hours"; break;
      case '7_days': rangeLabel = "records older than 7 days"; break;
      case '30_days': rangeLabel = "records older than 30 days"; break;
      case 'all': rangeLabel = "ALL historical records"; break;
    }

    showDialog(
      context: context,
      builder: (BuildContext confirmContext) {
        return AlertDialog(
          backgroundColor: Ds.panel,
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: Ds.alert, width: 1.5),
            borderRadius: BorderRadius.circular(12),
          ),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Ds.caution),
              SizedBox(width: 10),
              Text("Confirm Deletion", style: TextStyle(color: Colors.white)),
            ],
          ),
          content: Text(
            "Are you sure you want to permanently delete $rangeLabel?\n\nThis operation cannot be undone.",
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(confirmContext).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () async {
                Navigator.of(confirmContext).pop();
                await _executeClearHistory(context, range);
              },
              child: const Text("YES, DELETE", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  Future<void> _executeClearHistory(BuildContext context, String range) async {
    try {
      final ref = FirebaseDatabase.instance.ref('telemetry_history');

      if (range == 'all') {
        await ref.remove();
      } else {
        Duration duration;
        if (range == '24_hours') {
          duration = const Duration(hours: 24);
        } else if (range == '7_days') {
          duration = const Duration(days: 7);
        } else {
          duration = const Duration(days: 30);
        }

        final cutoffUs = DateTime.now().subtract(duration).microsecondsSinceEpoch;
        final snapshot = await ref.orderByChild('timestamp_us').endAt(cutoffUs).get();

        if (snapshot.exists && snapshot.value is Map) {
          Map<String, dynamic> updates = {};
          (snapshot.value as Map).forEach((key, value) {
            updates[key] = null; 
          });
          await ref.update(updates);
        }
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("History successfully updated."),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Error clearing history: $e"),
            backgroundColor: Ds.panelRaised,
          ),
        );
      }
    }
  }

  void _listenToFirebase() {
    _networkAddSub = _networkRef.onChildAdded.listen((event) => _handleIncomingNodeData(event.snapshot));
    _networkChangeSub = _networkRef.onChildChanged.listen((event) => _handleIncomingNodeData(event.snapshot));

    _liveSub = _liveRef.onValue.listen((event) {
      if (!mounted) return;
      final val = event.snapshot.value;
      Map rawData = {};
      
      if (val is Map) {
        rawData = Map.from(val);
      } else if (val is List) {
        for (int i = 0; i < val.length; i++) {
          if (val[i] != null) rawData[i.toString()] = val[i];
        }
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      double networkPeakMagnitude = 0.0;
      Set<String> liveNodeIds = {}; 
      Map<String, double> liveVals = {};

      rawData.forEach((key, value) {
        if (value is Map) {
          String nodeId = key.toString();
          int ts = (value['ts'] as num? ?? 0).toInt();
          
          if (now - ts < 2000) {
            liveNodeIds.add(nodeId);
            double val = (value['mag'] as num? ?? 0.0).toDouble();
            liveVals[nodeId] = val;
            if (val > networkPeakMagnitude) {
              networkPeakMagnitude = val;
            }
          }
        }
      });
      
      _telemetryState.updateWaves(liveVals, networkPeakMagnitude, liveNodeIds);
    });
  }

  void _handleIncomingNodeData(DataSnapshot snapshot) {
    if (snapshot.value == null || !mounted) return;
    
    final map = Map<String, dynamic>.from(snapshot.value as Map);
    if (map['event_type'] != 'disturbance') return;

    int eventTimestamp = (map['timestamp_us'] as num? ?? 0).toInt();
    if (eventTimestamp < _hubBootTimeUs) return;

    setState(() {
      String nodeId = map['node_id'] ?? 'unknown';
      _nodeLatestEvents[nodeId] = map;
    });
    // Stages 3-5 (association gate, method selection, recursive estimate,
    // feedback) run in the hub math isolate; no node-count gate here - the
    // decision table has a method for one node too, just a weaker one.
    _hypocentreService.ingestObservation(map);
  }

  String _describeEstimate(EstimateUpdateMsg u) {
    final depthStr = u.depthMeters != null
        ? "Depth: ${(u.depthMeters! / 1000.0).toStringAsFixed(1)} km (±${(u.depthUncertaintyMeters / 1000.0).toStringAsFixed(1)} km)"
        : "Depth: unresolved at this node count";
    final maturityStr =
        u.maturity == MethodMaturity.exotic ? "Research-level method - treat with caution" : "Standard method";
    return "${u.methodLabel}\n$maturityStr\n"
        "Lat: ${u.latitude.toStringAsFixed(4)}, Lng: ${u.longitude.toStringAsFixed(4)}\n"
        "$depthStr\n"
        "±${(u.horizontalUncertaintyMeters / 1000.0).toStringAsFixed(1)} km horizontal\n"
        "${u.associatedNodeIds.length} node(s) associated";
  }

  void _handleEstimateUpdate(EstimateUpdateMsg update) {
    if (!mounted) return;
    _activeEstimates[update.eventId] = update.toEstimate();

    setState(() {
      _epicenterMarkers[update.eventId] = MapItemData(
        id: update.eventId,
        loc: LatLng(update.latitude, update.longitude),
        type: MapItemType.epicenter,
        tooltipMessage: _describeEstimate(update),
      );
      _rebuildCachedMarkers();
    });

    // Only recentre the map when a *new* event appears - re-centring on
    // every refinement of an event already on screen would be jarring.
    if (update.isNewEvent && _isMapReady) {
      try {
        _mapController.move(LatLng(update.latitude, update.longitude), 18.0);
      } catch (e) {
        debugPrint("Failed to move MapController: $e");
      }
    }

    if (update.isNewEvent) {
      unawaited(AlertService.raiseDisturbanceAlert(
        methodLabel: update.methodLabel,
        latitude: update.latitude,
        longitude: update.longitude,
      ));
    }
  }

  List<Marker> _buildAllMarkers() {
    List<MapItemData> rawItems = [];

    _activeHubs.forEach((id, loc) {
      rawItems.add(MapItemData(
        id: id,
        loc: loc,
        type: MapItemType.hub,
        tooltipMessage: "Diagnostic Hub: $id\nLat: ${loc.latitude.toStringAsFixed(4)}, Lng: ${loc.longitude.toStringAsFixed(4)}",
      ));
    });

    _activeNodes.forEach((id, loc) {
      rawItems.add(MapItemData(
        id: id,
        loc: loc,
        type: MapItemType.node,
        tooltipMessage: "Node: $id\nLat: ${loc.latitude.toStringAsFixed(4)}, Lng: ${loc.longitude.toStringAsFixed(4)}",
      ));
    });

    rawItems.addAll(_epicenterMarkers.values);

    Map<int, List<MapItemData>> grid = {}; 

    for (var item in rawItems) {
      int latHash = (item.loc.latitude * 10000).round();
      int lngHash = (item.loc.longitude * 10000).round();
      int key = Object.hash(latHash, lngHash);
      
      if (grid.containsKey(key)) {
        grid[key]!.add(item);
      } else {
        grid[key] = [item];
      }
    }

    List<Marker> finalMarkers = [];
    CircleMarker? highlightedCircle;
    for (var group in grid.values) {
      if (group.length == 1) {
        finalMarkers.add(_buildMarkerFromData(group.first, group.first.loc));
        if (group.first.id == _highlightedEpicenterId) {
          highlightedCircle = _buildUncertaintyCircle(group.first, group.first.loc) ?? highlightedCircle;
        }
      } else {
        double radiusDegrees = 0.00015 + (group.length * 0.000015); 
        double sumLat = 0.0;
        double sumLng = 0.0;
        for (var item in group) {
          sumLat += item.loc.latitude;
          sumLng += item.loc.longitude;
        }
        
        double centerLat = sumLat / group.length;
        double centerLng = sumLng / group.length;

        for (int i = 0; i < group.length; i++) {
          double angle = (2 * math.pi * i) / group.length;
          double latOffset = radiusDegrees * math.cos(angle);
          double lngOffset = radiusDegrees * math.sin(angle);
          
          LatLng spreadLoc = LatLng(centerLat + latOffset, centerLng + lngOffset);
          finalMarkers.add(_buildMarkerFromData(group[i], spreadLoc));
          if (group[i].id == _highlightedEpicenterId) {
            highlightedCircle = _buildUncertaintyCircle(group[i], spreadLoc) ?? highlightedCircle;
          }
        }
      }
    }

    _highlightedCircleMarker = highlightedCircle;
    return finalMarkers;
  }

  /// The circle radius is the actual horizontal uncertainty of that
  /// specific hypocentre estimate, in real-world meters - not a fixed
  /// on-screen size - so it shrinks and grows across zoom levels the way
  /// a real distance should, and a wide, unresolved estimate visibly reads
  /// as less certain than a tightly-constrained one.
  CircleMarker? _buildUncertaintyCircle(MapItemData data, LatLng renderLoc) {
    final est = _activeEstimates[data.id];
    if (est == null) return null;
    return CircleMarker(
      point: renderLoc,
      radius: math.max(est.horizontalUncertaintyMeters, 50.0),
      useRadiusInMeter: true,
      color: Ds.alert.withValues(alpha: 0.15),
      borderColor: Ds.alert.withValues(alpha: 0.6),
      borderStrokeWidth: 1.5,
    );
  }

  Marker _buildMarkerFromData(MapItemData data, LatLng renderLoc) {
    Widget iconWidget;
    switch (data.type) {
      case MapItemType.hub:
        iconWidget = Tooltip(
          message: data.tooltipMessage,
          child: const Icon(Icons.hub, color: Ds.research, size: 34),
        );
        break;
      case MapItemType.node:
        bool isDisabled = _disabledNodes[data.id] ?? false;
        iconWidget = Tooltip(
          message: data.tooltipMessage,
          child: Icon(isDisabled ? Icons.cell_tower_outlined : Icons.cell_tower, color: isDisabled ? Ds.alert : Ds.trace, size: 30),
        );
        break;
      case MapItemType.epicenter:
        iconWidget = _HoverTapTrigger(
          isActive: _highlightedEpicenterId == data.id,
          onActivate: () => setState(() => _highlightedEpicenterId = data.id),
          onDeactivateIfActive: () {
            if (_highlightedEpicenterId == data.id) {
              setState(() => _highlightedEpicenterId = null);
            }
          },
          child: Tooltip(
            message: data.tooltipMessage,
            child: const Icon(Icons.crisis_alert, color: Ds.alert, size: 36),
          ),
        );
        break;
    }

    return Marker(
      point: renderLoc,
      width: 50,
      height: 50,
      child: iconWidget,
    );
  }

  void _showSettingsMenu() {
    showDialog(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: StatefulBuilder(
              builder: (context, setModalState) {
                return InstrumentPanel(
                  label: 'Network settings',
                  padding: const EdgeInsets.all(Ds.s4),
                  scrollable: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Plate boundary detail', style: Ds.title),
                      const SizedBox(height: Ds.s1),
                      Text(
                        'Higher detail draws more of the boundary geometry, at some cost to map smoothness.',
                        style: Ds.bodyDim,
                      ),
                      const SizedBox(height: Ds.s3),
                      Row(
                        children: [
                          for (final level in const ['low', 'medium', 'high'])
                            Padding(
                              padding: const EdgeInsets.only(right: Ds.s2),
                              child: OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: _tectonicResolution == level ? Ds.nominal : Ds.inkDim,
                                  side: BorderSide(
                                    color: _tectonicResolution == level ? Ds.nominal : Ds.hairline,
                                  ),
                                  padding: const EdgeInsets.symmetric(horizontal: Ds.s3, vertical: Ds.s2),
                                  minimumSize: Size.zero,
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Ds.rPanel)),
                                ),
                                onPressed: () {
                                  setModalState(() => _tectonicResolution = level);
                                  setState(() => _tectonicResolution = level);
                                  if (_isTectonicOverlayActive) _reloadTectonicData();
                                },
                                child: Text(level, style: Ds.mono(size: 11.5)),
                              ),
                            ),
                        ],
                      ),

                      const SizedBox(height: Ds.s5),
                      const PanelRule(),
                      const SizedBox(height: Ds.s4),

                      Text('Background filtering', style: Ds.title),
                      const SizedBox(height: Ds.s1),
                      Text(
                        'How aggressively nodes strip slow drift out of their accelerometer signal. '
                        'Higher keeps more of the fast movement that matters.',
                        style: Ds.bodyDim,
                      ),
                      const SizedBox(height: Ds.s2),
                      Row(
                        children: [
                          Expanded(
                            child: Slider(
                              value: _globalHpfAlpha,
                              min: 0.0,
                              max: 1.0,
                              divisions: 100,
                              label: _globalHpfAlpha.toStringAsFixed(2),
                              onChanged: (val) {
                                setModalState(() => _globalHpfAlpha = val);
                                setState(() => _globalHpfAlpha = val);
                                FirebaseDatabase.instance.ref('global_settings/hpf_alpha').set(val);
                              },
                            ),
                          ),
                          SizedBox(
                            width: 44,
                            child: Text(_globalHpfAlpha.toStringAsFixed(2),
                                style: Ds.mono(size: 12.5, weight: FontWeight.w600)),
                          ),
                          TextButton(
                            onPressed: () {
                              setModalState(() => _globalHpfAlpha = 0.9);
                              setState(() => _globalHpfAlpha = 0.9);
                              FirebaseDatabase.instance.ref('global_settings/hpf_alpha').set(0.9);
                            },
                            child: const Text('Reset'),
                          ),
                        ],
                      ),

                      const SizedBox(height: Ds.s4),
                      Text('Magnetic declination', style: Ds.title),
                      const SizedBox(height: Ds.s1),
                      Text(
                        'Corrects compass bearings to true north. Look up the value for your region '
                        'and set it once - it applies to every node.',
                        style: Ds.bodyDim,
                      ),
                      const SizedBox(height: Ds.s2),
                      Row(
                        children: [
                          Expanded(
                            child: Slider(
                              value: _globalDeclinationDeg,
                              min: -30.0,
                              max: 30.0,
                              divisions: 120,
                              label: _globalDeclinationDeg.toStringAsFixed(1),
                              onChanged: (val) {
                                setModalState(() => _globalDeclinationDeg = val);
                                setState(() => _globalDeclinationDeg = val);
                                FirebaseDatabase.instance
                                    .ref('global_settings/magnetic_declination_deg')
                                    .set(val);
                              },
                            ),
                          ),
                          SizedBox(
                            width: 44,
                            child: Text('${_globalDeclinationDeg.toStringAsFixed(1)}°',
                                style: Ds.mono(size: 12.5, weight: FontWeight.w600)),
                          ),
                          TextButton(
                            onPressed: () {
                              setModalState(() => _globalDeclinationDeg = 0.0);
                              setState(() => _globalDeclinationDeg = 0.0);
                              FirebaseDatabase.instance
                                  .ref('global_settings/magnetic_declination_deg')
                                  .set(0.0);
                            },
                            child: const Text('Reset'),
                          ),
                        ],
                      ),

                      const SizedBox(height: Ds.s5),
                      const PanelRule(),
                      const SizedBox(height: Ds.s3),
                      Text(
                        'Per-node sensitivity and surface settings are on each node in the Nodes panel.',
                        style: Ds.label,
                      ),
                      const SizedBox(height: Ds.s3),
                      Align(
                        alignment: Alignment.centerRight,
                        child: ElevatedButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Done'),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  void _showNodeSettings(String nodeId) {
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final current = _nodeSensitivities[nodeId] ?? 1.0;
            return Dialog(
              backgroundColor: Colors.transparent,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: InstrumentPanel(
                  label: 'Node $nodeId',
                  padding: const EdgeInsets.all(Ds.s4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Trigger sensitivity', style: Ds.title),
                      const SizedBox(height: Ds.s1),
                      Text(
                        'Higher values make this node report smaller movements. '
                        'Too high and ordinary footsteps get reported.',
                        style: Ds.bodyDim,
                      ),
                      const SizedBox(height: Ds.s3),
                      Row(
                        children: [
                          Text('0.1', style: Ds.mono(size: 10.5, color: Ds.inkMuted)),
                          Expanded(
                            child: Slider(
                              value: current,
                              min: 0.1,
                              max: 3.0,
                              divisions: 29,
                              label: current.toStringAsFixed(2),
                              onChanged: (val) {
                                setModalState(() => _nodeSensitivities[nodeId] = val);
                                setState(() {});
                                FirebaseDatabase.instance.ref('node_settings/$nodeId/sensitivity').set(val);
                              },
                            ),
                          ),
                          Text('3.0', style: Ds.mono(size: 10.5, color: Ds.inkMuted)),
                          const SizedBox(width: Ds.s2),
                          Text(current.toStringAsFixed(2), style: Ds.mono(size: 13, weight: FontWeight.w600)),
                        ],
                      ),
                      const SizedBox(height: Ds.s4),
                      const PanelRule(),
                      const SizedBox(height: Ds.s4),
                      Text('Resting surface', style: Ds.title),
                      const SizedBox(height: Ds.s1),
                      Text(
                        'The node guesses this from background vibration. Override it if the guess is wrong.',
                        style: Ds.bodyDim,
                      ),
                      const SizedBox(height: Ds.s3),
                      Row(
                        children: [
                          for (final option in const ['unknown', 'hard', 'soft'])
                            Padding(
                              padding: const EdgeInsets.only(right: Ds.s2),
                              child: OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Ds.inkDim,
                                  side: const BorderSide(color: Ds.hairline),
                                  padding: const EdgeInsets.symmetric(horizontal: Ds.s3, vertical: Ds.s2),
                                  minimumSize: Size.zero,
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Ds.rPanel)),
                                ),
                                onPressed: () {
                                  FirebaseDatabase.instance
                                      .ref('node_settings/$nodeId/surface_override')
                                      .set(option);
                                },
                                child: Text(
                                  option == 'unknown' ? 'Auto-detect' : option,
                                  style: Ds.mono(size: 11.5, color: Ds.inkDim),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: Ds.s5),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () {
                            setModalState(() => _nodeSensitivities[nodeId] = 1.0);
                            setState(() {});
                            FirebaseDatabase.instance.ref('node_settings/$nodeId/sensitivity').set(1.0);
                          },
                          child: const Text('Reset sensitivity'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    
    _networkAddSub?.cancel();
    _networkChangeSub?.cancel();
    _liveSub?.cancel();
    _hubPositionSub?.cancel();
    _nodesPresenceSub?.cancel();
    _hubsPresenceSub?.cancel();
    _nodeSettingsSub?.cancel();
    _hpfSettingsSub?.cancel();
    _declinationSettingsSub?.cancel();
    _estimateSub?.cancel();
    _eventExpiredSub?.cancel();
    
    _networkAddSub = null;
    _networkChangeSub = null;
    _liveSub = null;
    _hubPositionSub = null;
    _nodesPresenceSub = null;
    _hubsPresenceSub = null;
    _nodeSettingsSub = null;
    _hpfSettingsSub = null;
    _declinationSettingsSub = null;
    _estimateSub = null;
    _eventExpiredSub = null;

    _waveAnimationController.dispose();
    _hypocentreService.dispose();
    
    // Explicitly clear map data
    _tectonicLines.clear();
    _cachedMarkers.clear();
    _epicenterMarkers.clear();
    _activeEstimates.clear();
    _masterTectonicData.clear();

    FirebaseDatabase.instance.ref('diagnostic_hubs/$_hubId').remove();
    super.dispose();
  }

  // ====================================================================
  // CONSOLE LAYOUT
  //
  // Desktop-first balanced dashboard. Wide: events | map+trace | nodes,
  // all visible at once. Medium: drops the node rail into the left
  // column. Narrow: falls back to tabs, since three columns on a phone
  // would be three unreadable slivers.
  // ====================================================================

  int _activeNodeCount() => _activeNodes.keys.where((id) => !(_disabledNodes[id] ?? false)).length;

  Color get _networkHealthColor {
    if (_activeNodes.isEmpty) return Ds.inert;
    if (_activeEstimates.isNotEmpty) return Ds.alert;
    if (_activeNodeCount() < _activeNodes.length) return Ds.caution;
    return Ds.nominal;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildStatusRail(),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth >= Ds.wide) return _buildWideConsole();
                  if (constraints.maxWidth >= Ds.medium) return _buildMediumConsole();
                  return _buildNarrowConsole();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusRail() {
    final total = _activeNodes.length;
    final live = _activeNodeCount();
    return Container(
      height: 46,
      decoration: const BoxDecoration(
        color: Ds.panel,
        border: Border(bottom: BorderSide(color: Ds.hairline)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: Ds.s4),
      child: Row(
        children: [
          StatusDot(_networkHealthColor, size: 9),
          const SizedBox(width: Ds.s3),
          Text('GyroHub', style: Ds.title),
          const SizedBox(width: Ds.s2),
          Text(_hubId, style: Ds.mono(size: 11, color: Ds.inkMuted)),
          const SizedBox(width: Ds.s5),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  RailStat(
                    label: 'Nodes',
                    value: '$live/$total',
                    dot: total == 0 ? Ds.inert : (live < total ? Ds.caution : Ds.nominal),
                    tooltip: total == 0 ? 'No nodes connected' : '$live reporting, ${total - live} disabled',
                  ),
                  const SizedBox(width: Ds.s5),
                  RailStat(
                    label: 'Events',
                    value: '${_activeEstimates.length}',
                    dot: _activeEstimates.isEmpty ? Ds.inert : Ds.alert,
                    tooltip: 'Disturbances currently being tracked',
                  ),
                  const SizedBox(width: Ds.s5),
                  RailStat(
                    label: 'Hubs',
                    value: '${_activeHubs.length}',
                    dot: Ds.inert,
                    tooltip: 'Other consoles watching this network',
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.cleaning_services_outlined, size: 18),
            tooltip: 'Clear inactive devices',
            onPressed: _purgeInactiveDevices,
          ),
          IconButton(
            icon: const Icon(Icons.tune, size: 18),
            tooltip: 'Network settings',
            onPressed: _showSettingsMenu,
          ),
          IconButton(
            icon: const Icon(Icons.logout, size: 18),
            tooltip: 'Sign out',
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              if (!context.mounted) return;
              Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const RoleSelectionScreen()));
            },
          ),
        ],
      ),
    );
  }

  Widget _buildWideConsole() {
    return Padding(
      padding: const EdgeInsets.all(Ds.s3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 330, child: _buildEventsColumn()),
          const SizedBox(width: Ds.s3),
          Expanded(
            child: Column(
              children: [
                Expanded(child: _buildMapPanel()),
                const SizedBox(height: Ds.s3),
                SizedBox(height: 172, child: _buildNetworkTracePanel()),
              ],
            ),
          ),
          const SizedBox(width: Ds.s3),
          SizedBox(width: 340, child: _buildNodesPanel()),
        ],
      ),
    );
  }

  Widget _buildMediumConsole() {
    return Padding(
      padding: const EdgeInsets.all(Ds.s3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 320,
            child: Column(
              children: [
                Expanded(child: _buildEventsColumn()),
                const SizedBox(height: Ds.s3),
                Expanded(child: _buildNodesPanel()),
              ],
            ),
          ),
          const SizedBox(width: Ds.s3),
          Expanded(
            child: Column(
              children: [
                Expanded(child: _buildMapPanel()),
                const SizedBox(height: Ds.s3),
                SizedBox(height: 158, child: _buildNetworkTracePanel()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNarrowConsole() {
    return DefaultTabController(
      length: 4,
      child: Column(
        children: [
          Container(
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Ds.hairline)),
            ),
            child: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              indicatorColor: Ds.nominal,
              labelColor: Ds.ink,
              unselectedLabelColor: Ds.inkMuted,
              labelStyle: Ds.mono(size: 12, weight: FontWeight.w600),
              unselectedLabelStyle: Ds.mono(size: 12, weight: FontWeight.w500),
              tabs: const [
                Tab(text: 'Map'),
                Tab(text: 'Events'),
                Tab(text: 'Nodes'),
                Tab(text: 'History'),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(Ds.s3),
              child: TabBarView(
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  Column(
                    children: [
                      Expanded(child: _buildMapPanel()),
                      const SizedBox(height: Ds.s3),
                      SizedBox(height: 140, child: _buildNetworkTracePanel()),
                    ],
                  ),
                  _buildEventsPanel(),
                  _buildNodesPanel(),
                  _buildHistoryPanel(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Left column on desktop: active events on top, history beneath. Both
  /// stay visible - a fresh detection reads very differently when you can
  /// see what came before it without switching views.
  Widget _buildEventsColumn() {
    return Column(
      children: [
        Expanded(flex: 3, child: _buildEventsPanel()),
        const SizedBox(height: Ds.s3),
        Expanded(flex: 2, child: _buildHistoryPanel()),
      ],
    );
  }

  // -- Events ----------------------------------------------------------

  Widget _buildEventsPanel() {
    final events = _activeEstimates.entries.toList();
    return InstrumentPanel(
      label: 'Active events',
      accent: events.isEmpty ? null : Ds.alert,
      padding: EdgeInsets.zero,
      trailing: Text('${events.length}', style: Ds.mono(size: 12, color: events.isEmpty ? Ds.inkMuted : Ds.alert)),
      child: events.isEmpty
          ? const SingleChildScrollView(
              child: EmptyState(
                icon: Icons.graphic_eq,
                message: 'Nothing moving right now.',
                hint: 'Detections appear here the moment a node reports one.',
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(Ds.s3),
              itemCount: events.length,
              separatorBuilder: (_, __) => const SizedBox(height: Ds.s3),
              itemBuilder: (context, i) => _buildEventCard(events[i].key, events[i].value),
            ),
    );
  }

  /// The console's one deliberately bold element. Every figure here is
  /// paired with how much it can be trusted: the uncertainty bar, the
  /// method's maturity, and how many nodes actually contributed.
  Widget _buildEventCard(String eventId, HypocentreEstimate est) {
    final isHighlighted = _highlightedEpicenterId == eventId;
    final nodeCount = est.associatedNodeIds.length;
    final km = est.horizontalUncertaintyMeters / 1000.0;
    // Spread is scaled against a 25 km reference: at or beyond that, the
    // estimate is effectively unconstrained for a local network.
    final spread = (est.horizontalUncertaintyMeters / 25000.0).clamp(0.0, 1.0);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() {
        _highlightedEpicenterId = eventId;
        _rebuildCachedMarkers();
      }),
      onExit: (_) => setState(() {
        if (_highlightedEpicenterId == eventId) _highlightedEpicenterId = null;
        _rebuildCachedMarkers();
      }),
      child: GestureDetector(
        onTap: () {
          setState(() {
            _highlightedEpicenterId = eventId;
            _rebuildCachedMarkers();
          });
          if (_isMapReady) {
            try {
              _mapController.move(LatLng(est.latitude, est.longitude), 15.0);
            } catch (_) {}
          }
        },
        child: Container(
          padding: const EdgeInsets.all(Ds.s3),
          decoration: BoxDecoration(
            color: isHighlighted ? Ds.panelRaised : Ds.abyss,
            border: Border.all(color: isHighlighted ? Ds.alert.withValues(alpha: 0.7) : Ds.hairlineFaint),
            borderRadius: BorderRadius.circular(Ds.rPanel),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const StatusDot(Ds.alert, size: 7),
                  const SizedBox(width: Ds.s2),
                  Expanded(
                    child: Text(
                      '${est.latitude.toStringAsFixed(4)}, ${est.longitude.toStringAsFixed(4)}',
                      style: Ds.mono(size: 13, weight: FontWeight.w600),
                    ),
                  ),
                  StateChip(
                    '$nodeCount node${nodeCount == 1 ? '' : 's'}',
                    nodeCount >= 4 ? Ds.nominal : Ds.caution,
                    tooltip: nodeCount >= 4
                        ? 'Enough nodes to constrain depth'
                        : 'Too few nodes to pin this down well',
                  ),
                ],
              ),
              const SizedBox(height: Ds.s3),
              ConfidenceBar(
                spread: spread,
                caption: '±${km.toStringAsFixed(1)} km horizontal',
              ),
              const SizedBox(height: Ds.s3),
              Row(
                children: [
                  Expanded(
                    child: Readout(
                      label: 'Depth',
                      value: est.depthMeters == null ? null : (est.depthMeters! / 1000).toStringAsFixed(1),
                      unit: est.depthMeters == null ? null : 'km',
                      uncertainty: est.depthMeters == null
                          ? null
                          : '${(est.depthUncertaintyMeters / 1000).toStringAsFixed(1)}',
                      unresolvedNote: 'not resolved',
                    ),
                  ),
                  const SizedBox(width: Ds.s3),
                  Expanded(
                    child: Readout(
                      label: 'Origin',
                      value: _formatClock(est.originTimeUs),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Ds.s3),
              const PanelRule(),
              const SizedBox(height: Ds.s2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Text(est.methodLabel, style: Ds.label.copyWith(color: Ds.inkDim))),
                  const SizedBox(width: Ds.s2),
                  if (est.maturity == MethodMaturity.exotic)
                    const StateChip(
                      'research',
                      Ds.research,
                      icon: Icons.science_outlined,
                      tooltip: 'Active-research technique, not settled practice. Treat with caution.',
                    )
                  else
                    const StateChip('standard', Ds.nominal, tooltip: 'Established seismological method'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatClock(double micros) {
    if (micros <= 0) return '--:--:--';
    final dt = DateTime.fromMicrosecondsSinceEpoch(micros.round());
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';
  }

  // -- Nodes -----------------------------------------------------------

  Widget _buildNodesPanel() {
    final ids = _activeNodes.keys.toList();
    return InstrumentPanel(
      label: 'Nodes',
      padding: EdgeInsets.zero,
      trailing: Text('${_activeNodeCount()}/${ids.length}', style: Ds.mono(size: 12, color: Ds.inkMuted)),
      child: ids.isEmpty
          ? const SingleChildScrollView(
              child: EmptyState(
                icon: Icons.sensors_off,
                message: 'No nodes connected.',
                hint: 'Open the app on a phone and start it as a node.',
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(Ds.s3),
              itemCount: ids.length,
              separatorBuilder: (_, __) => const SizedBox(height: Ds.s2),
              itemBuilder: (context, i) => _buildNodeRow(ids[i]),
            ),
    );
  }

  Widget _buildNodeRow(String nodeId) {
    final latest = _nodeLatestEvents[nodeId];
    final loc = _activeNodes[nodeId];
    final disabled = _disabledNodes[nodeId] ?? false;
    final waveform = _telemetryState.nodeWaveforms[nodeId] ?? List.filled(60, 0.0);

    final saturated = latest?['accel_saturated'] == true;
    final bothChannels = saturated || latest?['channel_state'] == 'bothChannelsUsable';
    final surface = latest?['surface_type']?.toString() ?? 'unknown';
    final azimuth = (latest?['azimuth_true_deg'] as num?)?.toDouble();
    final azimuthResolved = latest?['azimuth_resolved'] == true;

    return Container(
      padding: const EdgeInsets.all(Ds.s3),
      decoration: BoxDecoration(
        color: Ds.abyss,
        border: Border.all(color: disabled ? Ds.alert.withValues(alpha: 0.3) : Ds.hairlineFaint),
        borderRadius: BorderRadius.circular(Ds.rPanel),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              StatusDot(disabled ? Ds.alert : Ds.nominal, size: 7),
              const SizedBox(width: Ds.s2),
              Expanded(child: Text(nodeId, style: Ds.mono(size: 12.5, weight: FontWeight.w600))),
              Transform.scale(
                scale: 0.72,
                child: Switch(
                  value: !disabled,
                  onChanged: (v) => FirebaseDatabase.instance.ref('node_settings/$nodeId/is_disabled').set(!v),
                ),
              ),
            ],
          ),
          const SizedBox(height: Ds.s1),
          TraceView(
            data: waveform,
            headIndex: _telemetryState.headIndex,
            height: 40,
            showGrid: false,
            color: disabled ? Ds.inert : Ds.trace,
          ),
          const SizedBox(height: Ds.s2),
          Wrap(
            spacing: Ds.s1,
            runSpacing: Ds.s1,
            children: [
              if (saturated)
                const StateChip('clipped', Ds.alert,
                    icon: Icons.warning_amber_rounded,
                    tooltip: 'Accelerometer maxed out - amplitude from this node is unreliable'),
              StateChip(
                bothChannels ? 'accel + gyro' : 'accel only',
                bothChannels ? Ds.nominal : Ds.inkMuted,
                tooltip: bothChannels
                    ? 'Gyroscope picked up rotation too'
                    : 'Gyroscope stayed at its noise floor',
              ),
              StateChip(
                surface,
                surface == 'soft' ? Ds.caution : (surface == 'hard' ? Ds.nominal : Ds.inkMuted),
                tooltip: surface == 'soft'
                    ? 'Soft surface damps vibration - this node is weighted lower'
                    : 'Resting surface classification',
              ),
              if (azimuth != null)
                StateChip(
                  azimuthResolved ? '${azimuth.toStringAsFixed(0)}°' : '${azimuth.toStringAsFixed(0)}° ±180',
                  azimuthResolved ? Ds.nominal : Ds.caution,
                  icon: Icons.navigation_outlined,
                  tooltip: azimuthResolved
                      ? 'Direction to source, confirmed by rotation data'
                      : 'Direction is an axis only - source could be either way along it',
                ),
            ],
          ),
          if (loc != null) ...[
            const SizedBox(height: Ds.s2),
            Text(
              '${loc.latitude.toStringAsFixed(3)}, ${loc.longitude.toStringAsFixed(3)}',
              style: Ds.mono(size: 10.5, color: Ds.inkMuted, weight: FontWeight.w400),
            ),
          ],
          const SizedBox(height: Ds.s2),
          Row(
            children: [
              Expanded(
                child: Text('Sensitivity', style: Ds.label),
              ),
              Text(
                (_nodeSensitivities[nodeId] ?? 1.0).toStringAsFixed(2),
                style: Ds.mono(size: 11, color: Ds.inkDim),
              ),
              const SizedBox(width: Ds.s2),
              InkWell(
                onTap: () => _showNodeSettings(nodeId),
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(Icons.tune, size: 14, color: Ds.inkMuted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // -- Network trace ----------------------------------------------------

  Widget _buildNetworkTracePanel() {
    return InstrumentPanel(
      label: 'Network motion',
      trailing: Text(
        _activeNodes.isEmpty ? 'idle' : 'live',
        style: Ds.mono(size: 11, color: _activeNodes.isEmpty ? Ds.inkMuted : Ds.trace),
      ),
      padding: const EdgeInsets.all(Ds.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _waveAnimationController,
                builder: (context, child) => TraceView(
                  data: _telemetryState.networkPeakWaveform,
                  headIndex: _telemetryState.headIndex,
                  height: double.infinity,
                ),
              ),
            ),
          ),
          const SizedBox(height: Ds.s2),
          Text('Strongest motion seen anywhere on the network', style: Ds.label),
        ],
      ),
    );
  }

  // -- Map --------------------------------------------------------------

  Widget _buildMapPanel() {
    return InstrumentPanel(
      label: 'Map',
      padding: EdgeInsets.zero,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isLoadingGeoJson)
            const Padding(
              padding: EdgeInsets.only(right: Ds.s2),
              child: SizedBox(width: 11, height: 11, child: CircularProgressIndicator(strokeWidth: 1.5)),
            ),
          Text('Plate boundaries', style: Ds.label),
          const SizedBox(width: Ds.s1),
          Transform.scale(
            scale: 0.66,
            child: Switch(
              value: _isTectonicOverlayActive,
              onChanged: (val) => _toggleTectonicGeoJson(val),
            ),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(Ds.rPanel)),
        child: Stack(
          children: [
            RepaintBoundary(
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: _hubLocation,
                  initialZoom: 16.0,
                  onMapReady: () {
                    if (!mounted) return;
                    setState(() => _isMapReady = true);
                    if (_isTectonicOverlayActive) {
                      _updateVisibleLines(_mapController.camera);
                    }
                  },
                  onPositionChanged: (position, hasGesture) {
                    _updateVisibleLines(_mapController.camera);
                  },
                ),
                children: [
                  TileLayer(
                    urlTemplate: "https://api.maptiler.com/maps/$_currentMapStyle/{z}/{x}/{y}.png?key=$mapTilerKey",
                    userAgentPackageName: 'com.mrp.seismic_network',
                  ),
                  if (_isTectonicOverlayActive) PolylineLayer(polylines: _tectonicLines),
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 150),
                    opacity: _highlightedCircleMarker != null ? 1.0 : 0.0,
                    child: CircleLayer(
                      circles: _highlightedCircleMarker != null ? [_highlightedCircleMarker!] : [],
                    ),
                  ),
                  MarkerLayer(markers: _cachedMarkers),
                ],
              ),
            ),
            Positioned(top: Ds.s3, right: Ds.s3, child: _buildMapStyleControl()),
            if (_isTectonicOverlayActive)
              Positioned(bottom: Ds.s3, left: Ds.s3, child: _buildTectonicLegend()),
          ],
        ),
      ),
    );
  }

  Widget _buildMapStyleControl() {
    const styles = [
      'satellite', 'hybrid', 'basic-v2-dark', 'dataviz-dark',
      'streets-v2', 'topo-v2', 'basic-v2', 'dataviz', 'ocean',
    ];
    return Container(
      decoration: BoxDecoration(
        color: Ds.panel.withValues(alpha: 0.94),
        border: Border.all(color: Ds.hairline),
        borderRadius: BorderRadius.circular(Ds.rPanel),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _isMapMenuExpanded = !_isMapMenuExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Ds.s3, vertical: Ds.s2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.layers_outlined, size: 14, color: Ds.inkDim),
                  const SizedBox(width: Ds.s2),
                  Text(_currentMapStyle, style: Ds.mono(size: 11, color: Ds.ink)),
                  const SizedBox(width: Ds.s1),
                  Icon(
                    _isMapMenuExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 14,
                    color: Ds.inkMuted,
                  ),
                ],
              ),
            ),
          ),
          if (_isMapMenuExpanded) ...[
            const PanelRule(),
            ...styles.map((style) {
              final selected = _currentMapStyle == style;
              return InkWell(
                onTap: () => setState(() {
                  _currentMapStyle = style;
                  _isMapMenuExpanded = false;
                }),
                child: Container(
                  width: 152,
                  padding: const EdgeInsets.symmetric(horizontal: Ds.s3, vertical: Ds.s2),
                  color: selected ? Ds.nominal.withValues(alpha: 0.12) : null,
                  child: Row(
                    children: [
                      if (selected)
                        const Icon(Icons.check, size: 11, color: Ds.nominal)
                      else
                        const SizedBox(width: 11),
                      const SizedBox(width: Ds.s2),
                      Text(
                        style,
                        style: Ds.mono(
                          size: 11,
                          color: selected ? Ds.nominal : Ds.inkDim,
                          weight: selected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildTectonicLegend() {
    return Container(
      padding: const EdgeInsets.all(Ds.s3),
      decoration: BoxDecoration(
        color: Ds.panel.withValues(alpha: 0.94),
        border: Border.all(color: Ds.hairline),
        borderRadius: BorderRadius.circular(Ds.rPanel),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('PLATE BOUNDARIES', style: Ds.bezelLabel),
          const SizedBox(height: Ds.s2),
          _buildLegendItem(Colors.redAccent, 'Subduction'),
          _buildLegendItem(Colors.orangeAccent, 'Continental convergent'),
          _buildLegendItem(Colors.greenAccent, 'Continental transform'),
          _buildLegendItem(Colors.deepPurpleAccent, 'Continental rift'),
          _buildLegendItem(Colors.blueAccent, 'Oceanic spreading'),
          _buildLegendItem(Colors.lightGreenAccent, 'Oceanic transform'),
          _buildLegendItem(Colors.pinkAccent, 'Oceanic convergent'),
        ],
      ),
    );
  }

  // -- History ----------------------------------------------------------

  Widget _buildHistoryPanel() {
    return InstrumentPanel(
      label: 'Recent detections',
      padding: EdgeInsets.zero,
      trailing: InkWell(
        onTap: () => _showClearHistoryDialog(context),
        child: const Padding(
          padding: EdgeInsets.all(2),
          child: Icon(Icons.delete_sweep_outlined, size: 15, color: Ds.inkMuted),
        ),
      ),
      child: StreamBuilder<DatabaseEvent>(
        stream: FirebaseDatabase.instance
            .ref('telemetry_history')
            .orderByChild('timestamp_us')
            .limitToLast(50)
            .onValue,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(Ds.s5),
                child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            );
          }
          final value = snapshot.data?.snapshot.value;
          if (value == null) {
            return const SingleChildScrollView(
              child: EmptyState(
                icon: Icons.history_toggle_off,
                message: 'No detections logged yet.',
                hint: 'Every reported disturbance lands here.',
              ),
            );
          }

          final raw = Map<dynamic, dynamic>.from(value as Map);
          final events = raw.values.map((e) => Map<dynamic, dynamic>.from(e as Map)).toList()
            ..sort((a, b) => ((b['timestamp_us'] as num?) ?? 0).compareTo((a['timestamp_us'] as num?) ?? 0));

          return ListView.separated(
            padding: const EdgeInsets.all(Ds.s3),
            itemCount: events.length,
            separatorBuilder: (_, __) => const SizedBox(height: Ds.s2),
            itemBuilder: (context, i) {
              final e = events[i];
              final nodeId = e['node_id']?.toString() ?? 'unknown';
              final az = (e['azimuth_true_deg'] as num?)?.toDouble();
              final resolved = e['azimuth_resolved'] == true;
              final both = e['accel_saturated'] == true || e['channel_state'] == 'bothChannelsUsable';
              final ts = (e['timestamp_us'] as num?)?.toDouble() ?? 0;

              return Container(
                padding: const EdgeInsets.symmetric(horizontal: Ds.s3, vertical: Ds.s2),
                decoration: BoxDecoration(
                  color: Ds.abyss,
                  border: Border.all(color: Ds.hairlineFaint),
                  borderRadius: BorderRadius.circular(Ds.rPanel),
                ),
                child: Row(
                  children: [
                    Text(_formatClock(ts), style: Ds.mono(size: 11.5, color: Ds.inkDim)),
                    const SizedBox(width: Ds.s3),
                    Expanded(child: Text(nodeId, style: Ds.mono(size: 11.5, weight: FontWeight.w600))),
                    if (az != null) ...[
                      Text(
                        resolved ? '${az.toStringAsFixed(0)}°' : '${az.toStringAsFixed(0)}°±180',
                        style: Ds.mono(size: 11, color: resolved ? Ds.inkDim : Ds.caution),
                      ),
                      const SizedBox(width: Ds.s2),
                    ],
                    StatusDot(both ? Ds.nominal : Ds.inert, size: 6, glow: false),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildLegendItem(Color color, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3.0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 14, height: 2, color: color),
          const SizedBox(width: Ds.s2),
          Text(label, style: Ds.label),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------------
// 5. LIVE STREAM PAINTER
// ----------------------------------------------------------------------
// LiveStreamPainter was removed: replaced by TracePainter in
// ui/instruments.dart, which draws a centred baseline, grid and gradient
// fill instead of a bare polyline.
