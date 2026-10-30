import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; 
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart'; 
import 'package:firebase_database/firebase_database.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:geolocator/geolocator.dart';
import 'dart:math' as math;
import 'dart:async';
import 'disturbance_detector.dart';
import 'firebase_options.dart';

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

int _getStepClassColorValue(String stepClass) {
  switch (stepClass.toUpperCase()) {
    case 'SUB': return 0xFFFF5252; 
    case 'CCB': return 0xFFFFAB40; 
    case 'CTF': return 0xFF69F0AE; 
    case 'CRB': return 0xFF7C4DFF; 
    case 'OSR': return 0xFF448AFF; 
    case 'OTF': return 0xFFB2FF59; 
    case 'OCR': return 0xFFFF4081; 
    default: return 0xFF9E9E9E;    
  }
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

        if (feature['geometry'] is Map) {
          var geom = feature['geometry'];
          
          if (geom['type'] == 'LineString' && geom['coordinates'] is List) {
            List<List<double>> points = [];
            double minLat = 90.0, maxLat = -90.0, minLng = 180.0, maxLng = -180.0;
            for (var pt in geom['coordinates']) {
              if (pt is List && pt.length >= 2) {
                double lng = (pt[0] as num).toDouble();
                double lat = (pt[1] as num).toDouble();
    
                if (lat < minLat) minLat = lat;
                if (lat > maxLat) maxLat = lat;
                if (lng < minLng) minLng = lng;
                if (lng > maxLng) maxLng = lng;

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
                double minLat = 90.0, maxLat = -90.0, minLng = 180.0, maxLng = -180.0;
                
                for (var pt in line) {
                  if (pt is List && pt.length >= 2) {
                    double lng = (pt[0] as num).toDouble();
                    double lat = (pt[1] as num).toDouble();
                    
                    if (lat < minLat) minLat = lat;
                    if (lat > maxLat) maxLat = lat;
                    if (lng < minLng) minLng = lng;
                    if (lng > maxLng) maxLng = lng;

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
// TDOA CALCULATOR HELPER
// ----------------------------------------------------------------------
class TdoaResult {
  final LatLng location;
  final double depthMeters;
  final double waveSpeedMps;
  final bool is3D;

  TdoaResult({
    required this.location,
    required this.depthMeters,
    required this.waveSpeedMps,
    required this.is3D,
  });
}

TdoaResult? _calculateTdoaEpicenter(List<Map<String, dynamic>> readings) {
  if (readings.length < 3) return null;

  const double v = 3500.0; 

  var n1 = readings[0];
  double lat1 = (n1['lat'] as num).toDouble();
  double lng1 = (n1['lng'] as num).toDouble();
  double t1 = (n1['timestamp_us'] as num).toDouble() / 1000000.0;

  double latToMeters = 111320.0;
  double lngToMeters = 111320.0 * math.cos(lat1 * math.pi / 180.0);

  if (readings.length >= 4) {
    var n2 = readings[1];
    var n3 = readings[2];
    var n4 = readings[3];

    double x2 = ((n2['lng'] as num).toDouble() - lng1) * lngToMeters;
    double y2 = ((n2['lat'] as num).toDouble() - lat1) * latToMeters;
    double t2 = (n2['timestamp_us'] as num).toDouble() / 1000000.0;
    double r2 = v * (t2 - t1);

    double x3 = ((n3['lng'] as num).toDouble() - lng1) * lngToMeters;
    double y3 = ((n3['lat'] as num).toDouble() - lat1) * latToMeters;
    double t3 = (n3['timestamp_us'] as num).toDouble() / 1000000.0;
    double r3 = v * (t3 - t1);

    double x4 = ((n4['lng'] as num).toDouble() - lng1) * lngToMeters;
    double y4 = ((n4['lat'] as num).toDouble() - lat1) * latToMeters;
    double t4 = (n4['timestamp_us'] as num).toDouble() / 1000000.0;
    double r4 = v * (t4 - t1);

    double k2 = x2 * x2 + y2 * y2 - r2 * r2;
    double k3 = x3 * x3 + y3 * y3 - r3 * r3;
    double k4 = x4 * x4 + y4 * y4 - r4 * r4;

    double a11 = 2 * x2, a12 = 2 * y2, a13 = 2 * r2;
    double a21 = 2 * x3, a22 = 2 * y3, a23 = 2 * r3;
    double a31 = 2 * x4, a32 = 2 * y4, a33 = 2 * r4;

    double detA = a11 * (a22 * a33 - a23 * a32) -
                  a12 * (a21 * a33 - a23 * a31) +
                  a13 * (a21 * a32 - a22 * a31);

    if (detA.abs() > 1e-6) {
      double detX = k2 * (a22 * a33 - a23 * a32) -
                    a12 * (k3 * a33 - a23 * k4) +
                    a13 * (k3 * a32 - a22 * k4);
      double x = detX / detA;

      double detY = a11 * (k3 * a33 - a23 * k4) -
                    k2 * (a21 * a33 - a23 * a31) +
                    a13 * (a21 * k4 - k3 * a31);
      double y = detY / detA;

      double detD = a11 * (a22 * k4 - k3 * a32) -
                    a12 * (a21 * k4 - k3 * a31) +
                    k2 * (a21 * a32 - a22 * a31);
      double d1 = detD / detA;

      double zSquared = (d1 * d1) - (x * x) - (y * y);
      double depthMeters = zSquared > 0 ? math.sqrt(zSquared) : 0.0;

      double finalLat = lat1 + (y / latToMeters);
      double finalLng = lng1 + (x / lngToMeters);

      double d12 = const Distance().as(LengthUnit.Meter, LatLng(lat1, lng1), LatLng((n2['lat'] as num).toDouble(), (n2['lng'] as num).toDouble()));
      double dt12 = t2 - t1;
      double calcSpeed = dt12 > 0 ? (d12 / dt12) : v;

      return TdoaResult(
        location: LatLng(finalLat, finalLng),
        depthMeters: depthMeters,
        waveSpeedMps: calcSpeed,
        is3D: true,
      );
    }
  }

  var n2 = readings[1];
  var n3 = readings[2];

  double x2 = ((n2['lng'] as num).toDouble() - lng1) * lngToMeters;
  double y2 = ((n2['lat'] as num).toDouble() - lat1) * latToMeters;
  double t2 = (n2['timestamp_us'] as num).toDouble() / 1000000.0;
  double r2 = v * (t2 - t1);

  double x3 = ((n3['lng'] as num).toDouble() - lng1) * lngToMeters;
  double y3 = ((n3['lat'] as num).toDouble() - lat1) * latToMeters;
  double t3 = (n3['timestamp_us'] as num).toDouble() / 1000000.0;
  double r3 = v * (t3 - t1);

  double c2 = x2 * x2 + y2 * y2 - r2 * r2;
  double c3 = x3 * x3 + y3 * y3 - r3 * r3;

  double det2D = (2 * x2 * 2 * y3) - (2 * y2 * 2 * x3);
  if (det2D.abs() < 1e-6) {
    double eps = 0.001;
    double w1 = 1.0 / eps;
    double w2 = 1.0 / ((t2 - t1) + eps);
    double w3 = 1.0 / ((t3 - t1) + eps);
    double totalW = w1 + w2 + w3;
    double epiLat = (lat1 * w1 + (n2['lat'] as num).toDouble() * w2 + (n3['lat'] as num).toDouble() * w3) / totalW;
    double epiLng = (lng1 * w1 + (n2['lng'] as num).toDouble() * w2 + (n3['lng'] as num).toDouble() * w3) / totalW;
    return TdoaResult(location: LatLng(epiLat, epiLng), depthMeters: 0.0, waveSpeedMps: v, is3D: false);
  }

  double x = (c2 * (2 * y3) - (2 * y2) * c3) / det2D;
  double y = ((2 * x2) * c3 - c2 * (2 * x3)) / det2D;

  double finalLat = lat1 + (y / latToMeters);
  double finalLng = lng1 + (x / lngToMeters);

  double d12 = const Distance().as(LengthUnit.Meter, LatLng(lat1, lng1), LatLng((n2['lat'] as num).toDouble(), (n2['lng'] as num).toDouble()));
  double dt12 = t2 - t1;
  double calcSpeed = dt12 > 0 ? (d12 / dt12) : v;

  return TdoaResult(
    location: LatLng(finalLat, finalLng),
    depthMeters: 0.0,
    waveSpeedMps: calcSpeed,
    is3D: false,
  );
}

// ----------------------------------------------------------------------
// REACTIVE TELEMETRY STATE (DECOUPLED FROM UI)
// ----------------------------------------------------------------------
class TelemetryState extends ChangeNotifier {
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
    notifyListeners();
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
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.message ?? "Authentication failed", style: const TextStyle(color: Colors.white)),
        backgroundColor: Colors.redAccent,
      ));
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
  final DisturbanceDetector _detector = DisturbanceDetector();
  double _calibrationProgress = 0.0;
  
  LatLng _currentLocation = const LatLng(17.9846, -76.9714);

  Timer? _liveWaveTimer;
  double _currentWaveMagnitude = 0.0;

  StreamSubscription? _accelSub; 
  StreamSubscription? _calibSub;
  StreamSubscription? _waveSub;
  StreamSubscription? _distSub;
  StreamSubscription<Position>? _positionSub;
  StreamSubscription? _sensitivitySub; 
  StreamSubscription? _hpfSub;
  StreamSubscription? _statusSub;
  StreamSubscription? _threeAxisSub; 

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    nodeID = 'node_${math.Random().nextInt(999999)}';
    _database = FirebaseDatabase.instance.ref('sensor_network/$nodeID');

    FirebaseDatabase.instance.ref('nodes_presence/$nodeID').onDisconnect().remove();

    Future.microtask(() async {
      try {
        await FirebaseAuth.instance.signInAnonymously();
        _registerPresence();
      } catch (error) {
        debugPrint("Node Auth Failed: $error");
      }
    });
    
    if (kIsWeb || defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) {
      _initGPS();
    }

    _sensitivitySub = FirebaseDatabase.instance.ref('node_settings/$nodeID/sensitivity').onValue.listen((event) {
      if (event.snapshot.value != null && mounted) {
        setState(() {
          _detector.sensitivityMultiplier = (event.snapshot.value as num).toDouble();
        });
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
        setState(() {
          _detector.hpfAlpha = (event.snapshot.value as num).toDouble();
        });
      }
    });

    _threeAxisSub = FirebaseDatabase.instance.ref('global_settings/enable_3_axis').onValue.listen((event) {
      if (event.snapshot.value != null && mounted) {
        setState(() {
          _detector.enable3Axis = (event.snapshot.value == true);
        });
      }
    });

    _accelSub = userAccelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 20)
    ).listen((event) {
      if (_isStreaming && !_isDisabled) {
        _detector.processAccelerometerData(event.x, event.y, event.z);
      }
    });

    _calibSub = _detector.onCalibrationProgress.listen((progress) {
      if (mounted) setState(() => _calibrationProgress = progress);
    });

    _waveSub = _detector.onLiveWave.listen((mag) => _currentWaveMagnitude = mag);

    _distSub = _detector.onDisturbanceDetected.listen((result) {
      if (_isStreaming && !_isDisabled) {
        _database.set({
          'node_id': nodeID,
          'event_type': 'disturbance',
          'angle': result.angleDegrees,
          'speed_mps': result.estimatedSpeedMps, 
          'reset_time_ms': result.resetTime.inMilliseconds,
          'timestamp_us': result.preciseTimestampUs,
          'lat': _currentLocation.latitude,
          'lng': _currentLocation.longitude,
          'is_3d': result.used3Axis,
        });

        FirebaseDatabase.instance.ref('telemetry_history').push().set({
          'node_id': nodeID,
          'timestamp_us': result.preciseTimestampUs,
          'date_string': DateTime.now().toIso8601String(),
          'angle': result.angleDegrees,
          'speed_mps': result.estimatedSpeedMps,
          'lat': _currentLocation.latitude,
          'lng': _currentLocation.longitude,
          'is_3d': result.used3Axis,
        });
      }
    });
  }

  void _registerPresence() {
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
      _accelSub?.pause();
      _liveWaveTimer?.cancel();
    } else if (state == AppLifecycleState.resumed) {
      _accelSub?.resume();
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
      liveRef.set({
        'mag': _currentWaveMagnitude,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });
    });
  }

  void _toggleStreaming(bool val) {
    if (_isDisabled && val) return;

    setState(() {
      _isStreaming = val;
      final liveRef = FirebaseDatabase.instance.ref('live_waves/$nodeID');
      
      if (_isStreaming) {
        _detector.forceRecalibration();
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
    _threeAxisSub?.cancel();
    FirebaseDatabase.instance.ref('nodes_presence/$nodeID').remove();
    _liveWaveTimer?.cancel();
    final liveRef = FirebaseDatabase.instance.ref('live_waves/$nodeID');
    try {
      liveRef.onDisconnect().cancel();
    } catch (_) {}
    liveRef.remove();
    
    _accelSub?.cancel();
    _calibSub?.cancel();
    _waveSub?.cancel();
    _distSub?.cancel();
    _detector.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool isCalibrating = _detector.state == DetectorState.calibrating;

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
            
            if (_isDisabled)
              const Padding(
                padding: EdgeInsets.only(bottom: 20.0),
                child: Text(
                  "This node has been disabled", 
                  style: TextStyle(color: Colors.redAccent, fontSize: 18, fontWeight: FontWeight.bold)
                ),
              ),

            if (isCalibrating && _isStreaming) ...[
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
            
            Text("Remote Sensitivity: ${_detector.sensitivityMultiplier.toStringAsFixed(2)}x", style: const TextStyle(color: Colors.grey)),
            if (_detector.enable3Axis)
               const Text("3-Axis Polarization: ACTIVE", style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold)),
            
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

class _HubScreenState extends State<HubScreen> with WidgetsBindingObserver {
  late final DatabaseReference _networkRef;
  late final DatabaseReference _liveRef;
  
  final TelemetryState _telemetryState = TelemetryState();

  final Map<String, Map<String, dynamic>> _nodeLatestEvents = {};
  
  final Map<String, LatLng> _activeNodes = {};
  final Map<String, LatLng> _activeHubs = {};
  final Map<String, double> _nodeSensitivities = {}; 
  final Map<String, bool> _disabledNodes = {}; 

  late final String _hubId;

  final List<Map<String, dynamic>> _recentReadings = [];
  
  LatLng _hubLocation = const LatLng(17.9846, -76.9714);
  
  String _currentMapStyle = 'dataviz-dark';
  String _tectonicResolution = 'low'; 
  
  bool _isTectonicOverlayActive = false;
  bool _isLoadingGeoJson = false;
  List<Polyline> _tectonicLines = [];
  
  // MapTiler variables
  bool _isMapMenuExpanded = false;
  final String mapTilerKey = '8e2ryGtHdAUEGhbdshZS';

  double _globalHpfAlpha = 0.9;
  bool _globalEnable3Axis = false; 

  final List<MapItemData> _epicenterDataList = [];
  List<Marker> _cachedMarkers = [];
  
  final MapController _mapController = MapController();
  bool _isMapReady = false;

  late final int _hubBootTimeUs;
  StreamSubscription? _networkAddSub;
  StreamSubscription? _networkChangeSub;
  StreamSubscription? _liveSub;
  StreamSubscription<Position>? _hubPositionSub;
  StreamSubscription? _nodesPresenceSub;
  StreamSubscription? _hubsPresenceSub;
  StreamSubscription? _nodeSettingsSub;
  StreamSubscription? _hpfSettingsSub;
  StreamSubscription? _threeAxisSettingsSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _hubId = 'hub_${math.Random().nextInt(999999)}';
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

      if (_isMapReady) {
        _updateVisibleLines(_mapController.camera);
      }
    } catch (e) {
      debugPrint("GeoJSON Parse Error: $e");
    } finally {
      if (mounted) setState(() => _isLoadingGeoJson = false);
    }
  }

  void _updateVisibleLines(MapCamera camera) {
    if (!_isTectonicOverlayActive || _masterTectonicData.isEmpty) return;

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

    setState(() => _tectonicLines = visibleLines);
  }

  Future<void> _toggleTectonicGeoJson(bool isActive) async {
    setState(() => _isTectonicOverlayActive = isActive);
    if (!isActive) return;
    _reloadTectonicData();
  }

  void _rebuildCachedMarkers() {
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

    _threeAxisSettingsSub = FirebaseDatabase.instance.ref('global_settings/enable_3_axis').onValue.listen((event) {
      if (!mounted) return;
      if (event.snapshot.value != null) {
        setState(() {
          _globalEnable3Axis = (event.snapshot.value == true);
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
                    _showConfirmationDialog(context, selectedRange);
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
      _processDisturbanceForMap(map);
    });
  }

  void _processDisturbanceForMap(Map<String, dynamic> newReading) {
    if (_activeNodes.length < 3) return; 

    String nodeId = newReading['node_id'] ?? 'unknown';
    int nowUs = DateTime.now().microsecondsSinceEpoch;

    _recentReadings.removeWhere((r) => (nowUs - (r['timestamp_us'] as num).toInt()) > 5000000);
    _recentReadings.removeWhere((r) => r['node_id'] == nodeId);
    _recentReadings.add(newReading);

    if (_recentReadings.length >= 3) {
      _recentReadings.sort((a, b) => (a['timestamp_us'] as num).compareTo(b['timestamp_us'] as num));

      TdoaResult? result = _calculateTdoaEpicenter(_recentReadings);
      if (result != null) {
        String label = result.is3D ? "3D TDOA Hypocenter" : "2D TDOA Epicenter";
        _plotEpicenter(result.location, label, result.waveSpeedMps, result.depthMeters, result.is3D);
        _recentReadings.clear(); 
      }
    }
  }

  void _plotEpicenter(LatLng location, String label, double calculatedSpeed, double depthMeters, bool is3D) {
    String depthStr = is3D ? "\nDepth: ${(depthMeters / 1000.0).toStringAsFixed(2)} km" : "";
    _epicenterDataList.add(MapItemData(
      id: 'epi_${DateTime.now().millisecondsSinceEpoch}_${math.Random().nextInt(1000)}',
      loc: location,
      type: MapItemType.epicenter,
      tooltipMessage: "$label\nLat: ${location.latitude.toStringAsFixed(4)}, Lng: ${location.longitude.toStringAsFixed(4)}$depthStr\nCalculated Speed: ${calculatedSpeed.toStringAsFixed(2)} m/s",
    ));
    
    setState(() {
      _rebuildCachedMarkers();
    });
    
    if (_isMapReady) {
      try {
        _mapController.move(location, 18.0);
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

    rawItems.addAll(_epicenterDataList);

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
    _threeAxisSettingsSub?.cancel();
    _telemetryState.dispose();
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
                        animation: _telemetryState,
                        builder: (context, child) {
                          return CustomPaint(painter: LiveStreamPainter(_telemetryState.networkPeakWaveform, _telemetryState.headIndex));
                        }
                      ),
                    ),
                    const Divider(color: Colors.white24, height: 32),
                    SwitchListTile(
                      title: const Text("3-AXIS POLARIZATION MODE", style: TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: const Text("Resolves local directional ambiguity in sparse networks (< 3 nodes) via initial Z-axis polarity.", style: TextStyle(color: Colors.grey, fontSize: 12)),
                      value: _globalEnable3Axis,
                      activeThumbColor: Colors.amberAccent, 
                      onChanged: (val) {
                        FirebaseDatabase.instance.ref('global_settings/enable_3_axis').set(val);
                      },
                      contentPadding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
            ),
            
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
    
    double angle = (latestEvent?['angle'] ?? 0.0).toDouble();
    double localSpeed = (latestEvent?['speed_mps'] ?? 0.0).toDouble();
    bool is3D = latestEvent?['is_3d'] == true;
    String latStr = location != null ? location.latitude.toStringAsFixed(4) : "Awaiting Lock";
    String lngStr = location != null ? location.longitude.toStringAsFixed(4) : "Awaiting Lock";
    
    bool hasEvent = latestEvent != null;
    bool canCalculateSpeed = _activeNodes.length >= 3; 
    bool isDisabled = _disabledNodes[nodeId] ?? false;

    return Card(
      margin: const EdgeInsets.only(bottom: 16.0),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            Expanded(
              flex: 2,
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
                  const SizedBox(height: 16),
                  Transform.rotate(
                    angle: -angle * (math.pi / 180), 
                    child: Icon(Icons.arrow_upward, size: 40, color: hasEvent ? (is3D ? Colors.amberAccent : Colors.redAccent) : Colors.grey.shade800),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    hasEvent ? "${angle.toStringAsFixed(1)}°" : "N/A", 
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: hasEvent ? Colors.white : Colors.grey)
                  ),
                  if (hasEvent && is3D) 
                     const Text("(3-Axis Resolved)", style: TextStyle(fontSize: 10, color: Colors.amberAccent)),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text("LIVE TELEMETRY STREAM", style: TextStyle(fontSize: 10, letterSpacing: 1.5, color: Colors.grey)),
                  const SizedBox(height: 8),
                  Container(
                    height: 80,
                    decoration: BoxDecoration(border: Border.all(color: Colors.white10), color: Colors.black26),
                    child: AnimatedBuilder(
                      animation: _telemetryState,
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
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("LOCAL ESTIMATE", style: TextStyle(fontSize: 10, color: Colors.grey)),
                            const SizedBox(height: 4),
                            Text(hasEvent ? "${localSpeed.toStringAsFixed(0)} m/s" : "STANDBY", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          ],
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("TDOA SPEED", style: TextStyle(fontSize: 10, color: Colors.grey)),
                            const SizedBox(height: 4),
                            Text(
                              canCalculateSpeed ? (hasEvent ? "Calculating..." : "STANDBY") : "Requires 3 Nodes", 
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: canCalculateSpeed ? Colors.white : Colors.amberAccent)
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

        // MapTiler Configuration Collapsible Menu
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
                  final speed = (event['speed_mps'] as num?)?.toStringAsFixed(1) ?? 'N/A';
                  final angle = (event['angle'] as num?)?.toStringAsFixed(1) ?? 'N/A';
                  
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
                        child: Text("Time: $timeFormatted\nEst. Speed: $speed m/s  |  Angle: $angle°"),
                      ),
                      trailing: event['is_3d'] == true 
                          ? const Tooltip(
                              message: "3-Axis Resolved",
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