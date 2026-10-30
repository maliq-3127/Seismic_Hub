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
      title: 'Seismic Network',
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F0F12),
        cardColor: const Color(0xFF16161F),
      ),
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
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 20,
          runSpacing: 20,
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.phone_android),
              label: const Text('MOBILE NODE'),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NodeScreen())),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.analytics),
              label: const Text('DIAGNOSTIC HUB'),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HubLoginScreen())),
            ),
          ],
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
          content: Text(e.message ?? "Authentication failed", style: const TextStyle(color: Colors.white)),
          backgroundColor: Colors.redAccent,
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
      appBar: AppBar(title: const Text("Hub Authentication")),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.admin_panel_settings, size: 80, color: Colors.purpleAccent),
              const SizedBox(height: 32),
              TextField(
                controller: _emailCtrl,
                decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passCtrl,
                decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
                obscureText: true,
              ),
              const SizedBox(height: 32),
              if (_isLoading)
                const CircularProgressIndicator(color: Colors.purpleAccent)
              else
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    TextButton(
                      onPressed: () => _authenticate(isLogin: false),
                      child: const Text("Register", style: TextStyle(color: Colors.grey)),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.purpleAccent, foregroundColor: Colors.white),
                      onPressed: () => _authenticate(isLogin: true),
                      child: const Text("Secure Login"),
                    ),
                  ],
                )
            ],
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Node Tuner ($nodeID)')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            Text(
              "GPS Locked: ${_currentLocation.latitude.toStringAsFixed(4)}, ${_currentLocation.longitude.toStringAsFixed(4)}", 
              style: const TextStyle(color: Colors.greenAccent),
            ),
            const SizedBox(height: 20),

            if (_showThrottleBanner)
              Card(
                color: Colors.amber.withValues(alpha: 0.15),
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    children: [
                      const Text(
                        "Background battery optimization may throttle sensor sampling during long sessions.",
                        style: TextStyle(color: Colors.amberAccent),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      ElevatedButton(
                        onPressed: () async {
                          await ThrottleMitigationService.requestMitigation();
                          _maybePromptThrottleMitigation();
                        },
                        child: const Text('Fix in Settings'),
                      ),
                    ],
                  ),
                ),
              ),

            if (_isDisabled)
              const Padding(
                padding: EdgeInsets.only(bottom: 20.0),
                child: Text(
                  "This node has been disabled", 
                  style: TextStyle(color: Colors.redAccent, fontSize: 18, fontWeight: FontWeight.bold)
                ),
              ),

            if (_isCalibrating && _isStreaming) ...[
              LinearProgressIndicator(value: _calibrationProgress),
              const SizedBox(height: 10),
              const Text("Learning Ambient Noise..."),
            ] else ...[
              Icon(
                _isDisabled ? Icons.block : Icons.radar, 
                size: 60, 
                color: _isDisabled ? Colors.redAccent : (_isStreaming ? Colors.greenAccent : Colors.grey)
              ),
            ],
            const SizedBox(height: 40),
            
            Text("Remote Sensitivity: ${_pollingService.sensitivityMultiplier.toStringAsFixed(2)}x", style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 8),
            Text(
              "Surface: ${_surfaceType.name}  •  Channels: ${_lastChannelState == null ? 'accelerometer only so far' : _lastChannelState!.name}",
              style: const TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            
            const SizedBox(height: 40),
            SwitchListTile(
              title: const Text('Transmit Telemetry'),
              value: _isStreaming,
              activeThumbColor: Colors.greenAccent, 
              onChanged: _isDisabled ? null : _toggleStreaming,
            ),
          ],
        ),
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
              backgroundColor: const Color(0xFF16161F),
              shape: RoundedRectangleBorder(
                side: const BorderSide(color: Colors.white10),
                borderRadius: BorderRadius.circular(12),
              ),
              title: const Row(
                children: [
                  Icon(Icons.delete_sweep, color: Colors.redAccent),
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
                      labelStyle: TextStyle(color: Colors.purpleAccent),
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
                  child: const Text("CANCEL", style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
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
          backgroundColor: const Color(0xFF16161F),
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: Colors.redAccent, width: 1.5),
            borderRadius: BorderRadius.circular(12),
          ),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent),
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
              child: const Text("CANCEL", style: TextStyle(color: Colors.grey)),
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
            backgroundColor: Colors.redAccent,
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
    for (var group in grid.values) {
      if (group.length == 1) {
        finalMarkers.add(_buildMarkerFromData(group.first, group.first.loc));
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
        }
      }
    }

    return finalMarkers;
  }

  Marker _buildMarkerFromData(MapItemData data, LatLng renderLoc) {
    Widget iconWidget;
    switch (data.type) {
      case MapItemType.hub:
        iconWidget = Tooltip(
          message: data.tooltipMessage,
          child: const Icon(Icons.hub, color: Colors.purpleAccent, size: 40),
        );
        break;
      case MapItemType.node:
        bool isDisabled = _disabledNodes[data.id] ?? false;
        iconWidget = Tooltip(
          message: data.tooltipMessage,
          child: Icon(isDisabled ? Icons.cell_tower_outlined : Icons.cell_tower, color: isDisabled ? Colors.redAccent : Colors.blueAccent, size: 35),
        );
        break;
      case MapItemType.epicenter:
        iconWidget = Tooltip(
          message: data.tooltipMessage,
          child: const Icon(Icons.crisis_alert, color: Colors.redAccent, size: 40),
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
        return AlertDialog(
          backgroundColor: const Color(0xFF16161F),
          title: const Text("Settings", style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text("Tectonic Fidelity", style: TextStyle(color: Colors.white70)),
                  DropdownButton<String>(
                    dropdownColor: const Color(0xFF16161F),
                    value: _tectonicResolution,
                    items: ['low', 'medium', 'high']
                        .map((s) => DropdownMenuItem(value: s, child: Text(s.toUpperCase(), style: const TextStyle(color: Colors.white))))
                        .toList(),
                    onChanged: (val) {
                      if (val != null) {
                        setState(() => _tectonicResolution = val);
                        if (_isTectonicOverlayActive) {
                          _reloadTectonicData();
                        }
                      }
                      Navigator.pop(ctx);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Text("HPF Aggressiveness", style: TextStyle(color: Colors.white70, fontSize: 14)),
              StatefulBuilder(
                builder: (context, setModalState) {
                  return Row(
                    children: [
                      Expanded(
                        child: Slider(
                          value: _globalHpfAlpha,
                          min: 0.0,
                          max: 1.0,
                          divisions: 100,
                          label: _globalHpfAlpha.toStringAsFixed(2),
                          activeColor: Colors.purpleAccent,
                          onChanged: (val) {
                            setModalState(() => _globalHpfAlpha = val);
                            setState(() => _globalHpfAlpha = val);
                            FirebaseDatabase.instance.ref('global_settings/hpf_alpha').set(val);
                          },
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          setModalState(() => _globalHpfAlpha = 0.9);
                          setState(() => _globalHpfAlpha = 0.9);
                          FirebaseDatabase.instance.ref('global_settings/hpf_alpha').set(0.9);
                        },
                        child: const Text("Reset", style: TextStyle(color: Colors.redAccent)),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 20),
              const Text("Magnetic Declination (deg)", style: TextStyle(color: Colors.white70, fontSize: 14)),
              const Text(
                "Look up your region's declination once and set it here - a single regional constant, not a per-node model. See ARCHITECTURE.md.",
                style: TextStyle(color: Colors.grey, fontSize: 11),
              ),
              StatefulBuilder(
                builder: (context, setModalState) {
                  return Row(
                    children: [
                      Expanded(
                        child: Slider(
                          value: _globalDeclinationDeg,
                          min: -30.0,
                          max: 30.0,
                          divisions: 120,
                          label: _globalDeclinationDeg.toStringAsFixed(1),
                          activeColor: Colors.purpleAccent,
                          onChanged: (val) {
                            setModalState(() => _globalDeclinationDeg = val);
                            setState(() => _globalDeclinationDeg = val);
                            FirebaseDatabase.instance.ref('global_settings/magnetic_declination_deg').set(val);
                          },
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          setModalState(() => _globalDeclinationDeg = 0.0);
                          setState(() => _globalDeclinationDeg = 0.0);
                          FirebaseDatabase.instance.ref('global_settings/magnetic_declination_deg').set(0.0);
                        },
                        child: const Text("Reset", style: TextStyle(color: Colors.redAccent)),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                icon: const Icon(Icons.tune),
                label: const Text("Node sensitivity..."),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  foregroundColor: Colors.white,
                ),
                onPressed: () {
                  Navigator.pop(ctx);
                  _showNodeSensitivityDialog();
                },
              )
            ],
          ),
        );
      }
    );
  }

  void _showNodeSensitivityDialog() {
    List<String> nodeKeys = _activeNodes.keys.toList();
    
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF16161F),
          title: const Text("Node Sensitivities", style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: double.maxFinite,
            child: nodeKeys.isEmpty 
              ? const Text("No active nodes available.", style: TextStyle(color: Colors.grey))
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: nodeKeys.length,
                  itemBuilder: (context, index) {
                    String nodeId = nodeKeys[index];
                    return StatefulBuilder(
                      builder: (context, setModalState) {
                        double currentVal = _nodeSensitivities[nodeId] ?? 1.0;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(nodeId, style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold)),
                            Row(
                              children: [
                                const Text("0.1", style: TextStyle(fontSize: 10, color: Colors.grey)),
                                Expanded(
                                  child: Slider(
                                    value: currentVal,
                                    min: 0.1, max: 3.0, divisions: 29,
                                    label: currentVal.toStringAsFixed(1),
                                    activeColor: Colors.amber,
                                    onChanged: (val) {
                                      setModalState(() => currentVal = val);
                                      FirebaseDatabase.instance.ref('node_settings/$nodeId/sensitivity').set(val);
                                    },
                                  ),
                                ),
                                const Text("3.0", style: TextStyle(fontSize: 10, color: Colors.grey)),
                                const SizedBox(width: 8),
                                TextButton(
                                  onPressed: () {
                                    setModalState(() => currentVal = 1.00);
                                    FirebaseDatabase.instance.ref('node_settings/$nodeId/sensitivity').set(1.00);
                                  },
                                  child: const Text("Reset", style: TextStyle(color: Colors.redAccent)),
                                ),
                              ],
                            ),
                            Row(
                              children: [
                                const Text("Surface:", style: TextStyle(fontSize: 11, color: Colors.grey)),
                                const SizedBox(width: 8),
                                for (final option in const ['unknown', 'hard', 'soft'])
                                  Padding(
                                    padding: const EdgeInsets.only(right: 6.0),
                                    child: OutlinedButton(
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        minimumSize: Size.zero,
                                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      ),
                                      onPressed: () {
                                        FirebaseDatabase.instance.ref('node_settings/$nodeId/surface_override').set(option);
                                      },
                                      child: Text(option == 'unknown' ? 'Auto' : option, style: const TextStyle(fontSize: 11)),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        );
                      }
                    );
                  }
                ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Close", style: TextStyle(color: Colors.white)),
            )
          ],
        );
      }
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

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text("DIAGNOSTIC HUB (${_hubId.toUpperCase()})"),
          actions: [
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: 'Sign Out',
              onPressed: () async {
                await FirebaseAuth.instance.signOut();
                if (!context.mounted) return;
                Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const RoleSelectionScreen()));
              },
            ),
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: 'Settings',
              onPressed: _showSettingsMenu,
            )
          ],
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.speed), text: "NETWORK TELEMETRY"),
              Tab(icon: Icon(Icons.map), text: "GEOSPATIAL MAP"),
              Tab(icon: Icon(Icons.history), text: "EVENT HISTORY"),
            ],
          ),
        ),
        body: TabBarView(
          physics: const NeverScrollableScrollPhysics(),
          children: [
            _buildTelemetryTab(),
            _buildMapTab(),
            _buildHistoryTab(),
          ],
        ),
      ),
    );
  }

  Widget _buildTelemetryTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: RepaintBoundary(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text("SUMMARY", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: 2.0)),
            const SizedBox(height: 8),
            Card(
              shape: RoundedRectangleBorder(side: const BorderSide(color: Colors.purpleAccent, width: 1.5), borderRadius: BorderRadius.circular(8)),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text("PEAK NETWORK KINETIC STREAM", style: TextStyle(letterSpacing: 1.5, color: Colors.grey)),
                    const SizedBox(height: 10),
                    Container(
                      height: 120,
                      decoration: BoxDecoration(border: Border.all(color: Colors.white10), color: Colors.black26),
                      child: AnimatedBuilder(
                        animation: _waveAnimationController,
                        builder: (context, child) {
                          return CustomPaint(painter: LiveStreamPainter(_telemetryState.networkPeakWaveform, _telemetryState.headIndex));
                        }
                      ),
                    ),
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 24),
            const Divider(color: Colors.white24),
            const SizedBox(height: 16),

            Text("${_activeEstimates.length} ACTIVE EVENT(S)", style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: 2.0)),
            const SizedBox(height: 16),
            if (_activeEstimates.isEmpty)
              const Center(child: Text("No events associated yet.", style: TextStyle(color: Colors.grey))),
            ..._activeEstimates.entries.map((entry) {
              final est = entry.value;
              final depthStr = est.depthMeters != null
                  ? "${(est.depthMeters! / 1000.0).toStringAsFixed(1)} km deep"
                  : "depth unresolved";
              return Card(
                margin: const EdgeInsets.only(bottom: 8.0),
                color: const Color(0xFF16161F),
                shape: RoundedRectangleBorder(
                  side: BorderSide(color: est.maturity == MethodMaturity.exotic ? Colors.amberAccent : Colors.white10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListTile(
                  leading: const Icon(Icons.crisis_alert, color: Colors.redAccent),
                  title: Text(est.methodLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                    "${est.latitude.toStringAsFixed(4)}, ${est.longitude.toStringAsFixed(4)} - $depthStr\n"
                    "${est.associatedNodeIds.length} node(s) - ±${(est.horizontalUncertaintyMeters / 1000.0).toStringAsFixed(1)} km",
                  ),
                  isThreeLine: true,
                  trailing: est.maturity == MethodMaturity.exotic
                      ? const Tooltip(message: "Research-level method", child: Icon(Icons.science, color: Colors.amberAccent))
                      : null,
                ),
              );
            }),

            const SizedBox(height: 24),
            const Divider(color: Colors.white24),
            const SizedBox(height: 16),
            
            Text("${_activeNodes.length} ACTIVE NODES", style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: 2.0)),
            const SizedBox(height: 16),
            if (_activeNodes.isEmpty)
              const Center(child: Text("Waiting for nodes to connect...", style: TextStyle(color: Colors.grey))),
            
            ..._activeNodes.keys.map((nodeId) => _buildNodeCard(nodeId)),
          ],
        ),
      ),
    );
  }

  Widget _buildNodeCard(String nodeId) {
    final latestEvent = _nodeLatestEvents[nodeId];
    final location = _activeNodes[nodeId];
    
    final double? angle = (latestEvent?['azimuth_true_deg'] as num?)?.toDouble();
    final double? apparentVelocity = (latestEvent?['apparent_velocity_mps'] as num?)?.toDouble();
    final String channelState = latestEvent?['channel_state']?.toString() ?? 'accelerometerDominant';
    final bool accelSaturated = latestEvent?['accel_saturated'] == true;
    final String surfaceType = latestEvent?['surface_type']?.toString() ?? 'unknown';
    bool bothChannels = accelSaturated || channelState == 'bothChannelsUsable';
    String latStr = location != null ? location.latitude.toStringAsFixed(4) : "Awaiting Lock";
    String lngStr = location != null ? location.longitude.toStringAsFixed(4) : "Awaiting Lock";
    
    bool hasEvent = latestEvent != null;
    bool isDisabled = _disabledNodes[nodeId] ?? false;

    return Card(
      margin: const EdgeInsets.only(bottom: 16.0),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: LayoutBuilder(
          builder: (context, constraints) {
            bool isNarrow = constraints.maxWidth < 400;
            return Flex(
              direction: isNarrow ? Axis.vertical : Axis.horizontal,
              crossAxisAlignment: isNarrow ? CrossAxisAlignment.center : CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: isNarrow ? double.infinity : constraints.maxWidth * 0.35,
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.circle, color: isDisabled ? Colors.redAccent : Colors.greenAccent, size: 12),
                          const SizedBox(width: 4),
                          Text(isDisabled ? "Disabled" : "Active", style: TextStyle(color: isDisabled ? Colors.redAccent : Colors.greenAccent, fontWeight: FontWeight.bold)),
                          const Spacer(),
                          Switch(
                            value: !isDisabled,
                            activeThumbColor: Colors.greenAccent,
                            inactiveThumbColor: Colors.redAccent,
                            onChanged: (val) {
                              FirebaseDatabase.instance.ref('node_settings/$nodeId/is_disabled').set(!val);
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(nodeId.toUpperCase(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.blueAccent)),
                      const SizedBox(height: 4),
                      Text("Lat: $latStr", style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      Text("Lng: $lngStr", style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      Text("Surface: $surfaceType", style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      const SizedBox(height: 16),
                      Transform.rotate(
                        angle: -(angle ?? 0.0) * (math.pi / 180), 
                        child: Icon(Icons.arrow_upward, size: 40, color: (hasEvent && angle != null) ? (bothChannels ? Colors.amberAccent : Colors.redAccent) : Colors.grey.shade800),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        (hasEvent && angle != null) ? "${angle.toStringAsFixed(1)}°" : "N/A", 
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: (hasEvent && angle != null) ? Colors.white : Colors.grey)
                      ),
                      if (hasEvent) 
                         Text(bothChannels ? "(Gyroscope active)" : "(Accelerometer only)", style: const TextStyle(fontSize: 10, color: Colors.amberAccent)),
                    ],
                  ),
                ),
                if (!isNarrow) const SizedBox(width: 16),
                if (isNarrow) const SizedBox(height: 24),
                Expanded(
                  flex: isNarrow ? 0 : 1,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text("LIVE TELEMETRY STREAM", style: TextStyle(fontSize: 10, letterSpacing: 1.5, color: Colors.grey)),
                      const SizedBox(height: 8),
                      Container(
                        height: 80,
                        decoration: BoxDecoration(border: Border.all(color: Colors.white10), color: Colors.black26),
                        child: AnimatedBuilder(
                          animation: _waveAnimationController,
                          builder: (context, child) {
                             final waveform = _telemetryState.nodeWaveforms[nodeId] ?? List.filled(60, 0.0);
                             return CustomPaint(painter: LiveStreamPainter(waveform, _telemetryState.headIndex));
                          }
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text("LATEST DISTURBANCE PROFILE", style: TextStyle(fontSize: 10, letterSpacing: 1.5, color: Colors.grey)),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(4)),
                        child: Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          spacing: 16,
                          runSpacing: 16,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text("LOCAL VELOCITY (6C)", style: TextStyle(fontSize: 10, color: Colors.grey)),
                                const SizedBox(height: 4),
                                Text(apparentVelocity != null ? "${apparentVelocity.toStringAsFixed(0)} m/s" : (hasEvent ? "N/A" : "STANDBY"), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                              ],
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text("CHANNEL STATE", style: TextStyle(fontSize: 10, color: Colors.grey)),
                                const SizedBox(height: 4),
                                Text(
                                  !hasEvent ? "STANDBY" : (accelSaturated ? "Accel saturated" : (bothChannels ? "Both channels" : "Accelerometer only")), 
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: accelSaturated ? Colors.orangeAccent : Colors.white)
                                ),
                              ],
                            )
                          ],
                        ),
                      )
                    ],
                  ),
                )
              ],
            );
          }
        ),
      ),
    );
  }

  Widget _buildMapTab() {
    return Stack(
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
              if (_isTectonicOverlayActive)
                PolylineLayer(
                  polylines: _tectonicLines,
                ),
              MarkerLayer(
                markers: _cachedMarkers,
              ),
            ],
          ), 
        ), 

        Positioned(
          top: 16,
          left: 16,
          child: Card(
            color: const Color(0xFF16161F).withValues(alpha: 0.9),
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.public, color: Colors.purpleAccent, size: 20),
                      const SizedBox(width: 8),
                      const Text("Tectonic Plates", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                      const SizedBox(width: 8),
                      Switch(
                        value: _isTectonicOverlayActive,
                        onChanged: (val) => _toggleTectonicGeoJson(val),
                        activeThumbColor: Colors.purpleAccent,
                      ),
                      if (_isLoadingGeoJson)
                        const Padding(
                          padding: EdgeInsets.only(left: 8.0),
                          child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),

        Positioned(
          top: 16,
          right: 16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              FloatingActionButton(
                mini: true,
                backgroundColor: const Color(0xFF16161F),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: const BorderSide(color: Colors.white10),
                ),
                child: const Icon(Icons.layers),
                onPressed: () => setState(() => _isMapMenuExpanded = !_isMapMenuExpanded),
              ),
              if (_isMapMenuExpanded)
                Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Card(
                    color: const Color(0xFF16161F).withValues(alpha: 0.95),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: const BorderSide(color: Colors.white10),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          const Text("MapTiler Views", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 12)),
                          const SizedBox(height: 8),
                          ...[
                            'basic-v2', 'basic-v2-dark', 'streets-v2', 'satellite', 
                            'hybrid', 'topo-v2', 'dataviz', 'dataviz-dark', 'ocean'
                          ].map((style) => InkWell(
                            onTap: () => setState(() {
                              _currentMapStyle = style;
                              _isMapMenuExpanded = false;
                            }),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6.0),
                              child: Text(
                                style.toUpperCase(),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: _currentMapStyle == style ? Colors.blueAccent : Colors.white70,
                                  fontWeight: _currentMapStyle == style ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                            ),
                          )),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),

        Positioned(
          bottom: 16,
          right: 16,
          child: FloatingActionButton.extended(
            heroTag: 'purge_btn',
            backgroundColor: Colors.orangeAccent.withValues(alpha: 0.9),
            icon: const Icon(Icons.cleaning_services, color: Colors.white),
            label: const Text("CLEAR INACTIVE", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            onPressed: _purgeInactiveDevices,
          ),
        ),
        
        if (_isTectonicOverlayActive)
          Positioned(
            bottom: 16,
            left: 16,
            child: Card(
              color: const Color(0xFF16161F).withValues(alpha: 0.9),
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text("Tectonic Boundaries Legend", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.white)),
                    const SizedBox(height: 10),
                    _buildLegendItem(Colors.redAccent, "Subduction (SUB)"),
                    _buildLegendItem(Colors.orangeAccent, "Continental Conv. (CCB)"),
                    _buildLegendItem(Colors.greenAccent, "Continental Trans. (CTF)"),
                    _buildLegendItem(Colors.deepPurpleAccent, "Continental Rift (CRB)"),
                    _buildLegendItem(Colors.blueAccent, "Oceanic Spreading (OSR)"),
                    _buildLegendItem(Colors.lightGreenAccent, "Oceanic Trans. (OTF)"),
                    _buildLegendItem(Colors.pinkAccent, "Oceanic Conv. (OCR)"),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildHistoryTab() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          color: const Color(0xFF111118),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "EVENT LOGS",
                style: TextStyle(color: Colors.white54, fontWeight: FontWeight.bold, letterSpacing: 1.2),
              ),
              IconButton(
                icon: const Icon(Icons.delete_sweep, color: Colors.redAccent),
                tooltip: "Clear History",
                onPressed: () => _showClearHistoryDialog(context),
              ),
            ],
          ),
        ),
        
        Expanded(
          child: StreamBuilder<DatabaseEvent>(
            stream: FirebaseDatabase.instance
                .ref('telemetry_history')
                .orderByChild('timestamp_us')
                .limitToLast(50) 
                .onValue,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Text(
                      "Error loading history:\n${snapshot.error}", 
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.redAccent)
                    ),
                  )
                );
              }
              
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator(color: Colors.purpleAccent));
              }

              final rawData = snapshot.data?.snapshot.value;
              if (rawData == null) {
                return const Center(child: Text("No historical events recorded.", style: TextStyle(color: Colors.grey)));
              }

              List<Map<String, dynamic>> events = [];
              
              if (rawData is Map) {
                rawData.forEach((key, value) {
                  if (value is Map) events.add(Map<String, dynamic>.from(value));
                });
              } else if (rawData is List) {
                for (var value in rawData) {
                  if (value is Map) events.add(Map<String, dynamic>.from(value));
                }
              }

              if (events.isEmpty) {
                return const Center(child: Text("No VALID historical events found.", style: TextStyle(color: Colors.grey)));
              }

              events.sort((a, b) => (b['timestamp_us'] as num).compareTo(a['timestamp_us'] as num)); 

              return ListView.builder(
                padding: const EdgeInsets.all(16.0),
                itemCount: events.length,
                itemBuilder: (context, index) {
                  final event = events[index];
                  final dateStr = event['date_string'] ?? '';
                  final nodeId = event['node_id'] ?? 'Unknown';
                  final speed = (event['apparent_velocity_mps'] as num?)?.toStringAsFixed(1) ?? 'N/A';
                  final angle = (event['azimuth_true_deg'] as num?)?.toStringAsFixed(1) ?? 'N/A';
                  final bool bothChannels = event['accel_saturated'] == true || event['channel_state'] == 'bothChannelsUsable';
                  
                  DateTime? dt = DateTime.tryParse(dateStr);
                  String timeFormatted = dt != null 
                      ? "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}" 
                      : dateStr;

                  return Card(
                    color: const Color(0xFF16161F),
                    shape: RoundedRectangleBorder(
                      side: const BorderSide(color: Colors.white10, width: 1), 
                      borderRadius: BorderRadius.circular(8)
                    ),
                    margin: const EdgeInsets.only(bottom: 8.0),
                    child: ListTile(
                      leading: const Icon(Icons.waves, color: Colors.purpleAccent, size: 30),
                      title: Text("Disturbance at ${nodeId.toUpperCase()}", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blueAccent)),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4.0),
                        child: Text("Time: $timeFormatted\nLocal velocity: $speed m/s  |  Azimuth: $angle°"),
                      ),
                      trailing: bothChannels
                          ? const Tooltip(
                              message: "Both channels usable (gyroscope active)",
                              child: Icon(Icons.threed_rotation, color: Colors.amberAccent, size: 24),
                            ) 
                          : null,
                      isThreeLine: true,
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildLegendItem(Color color, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4.0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 16, height: 4, color: color),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.white70)),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------------
// 5. LIVE STREAM PAINTER
// ----------------------------------------------------------------------
class LiveStreamPainter extends CustomPainter {
  final List<double> data;
  final int headIndex;

  LiveStreamPainter(this.data, this.headIndex);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    final paint = Paint()
      ..color = Colors.greenAccent
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final path = Path();
    final double stepX = size.width / (data.length > 1 ? data.length - 1 : 1);
    
    double maxVal = 0.1; 
    for (double val in data) {
      if (val > maxVal) maxVal = val;
    }

    for (int i = 0; i < data.length; i++) {
      int circularIndex = (headIndex + i) % data.length;
      
      double x = i * stepX;
      double normalized = (data[circularIndex] / maxVal).clamp(0.0, 1.0);
      double y = size.height - (normalized * size.height);
      
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }
  
  @override
  bool shouldRepaint(covariant LiveStreamPainter oldDelegate) => true; 
}