import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart'; 
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart'; // Added Auth
import 'package:firebase_database/firebase_database.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:geolocator/geolocator.dart';
import 'dart:math' as math;
import 'dart:async';
import 'disturbance_detector.dart';
import 'firebase_options.dart';

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
  runApp(const GyroApp());
}

class GyroApp extends StatelessWidget {
  const GyroApp({super.key});
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
              // Changed routing to hit the Login Screen first
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

class _NodeScreenState extends State<NodeScreen> {
  late final String nodeID; 
  late DatabaseReference _database;
  bool _isStreaming = false;
  bool _isDisabled = false; // Tracks if Hub has disabled this node
  final DisturbanceDetector _detector = DisturbanceDetector();
  double _calibrationProgress = 0.0;
  
  LatLng _currentLocation = const LatLng(17.9846, -76.9714);

  Timer? _liveWaveTimer;
  double _currentWaveMagnitude = 0.0;

  StreamSubscription? _gyroSub;
  StreamSubscription? _calibSub;
  StreamSubscription? _waveSub;
  StreamSubscription? _distSub;
  StreamSubscription<Position>? _positionSub;
  StreamSubscription? _sensitivitySub; 
  StreamSubscription? _hpfSub;
  StreamSubscription? _statusSub; // Sub for disabled status

  @override
  void initState() {
    super.initState();
    nodeID = 'node_${math.Random().nextInt(999999)}';
    _database = FirebaseDatabase.instance.ref('sensor_network/$nodeID');

    // Authenticate the node silently in the background
    Future.microtask(() async {
      try {
        await FirebaseAuth.instance.signInAnonymously();
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

    // Listen for Disable Status from Hub
    _statusSub = FirebaseDatabase.instance.ref('node_settings/$nodeID/is_disabled').onValue.listen((event) {
      if (mounted) {
        setState(() {
          _isDisabled = (event.snapshot.value == true);
          // Auto-kill the stream if disabled by Hub
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

    _gyroSub = gyroscopeEventStream(
      samplingPeriod: const Duration(milliseconds: 20)
    ).listen((event) {
      if (_isStreaming && !_isDisabled) _detector.processGyroscopeData(event.x, event.y);
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
        });
      }
    });
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
          
          final presenceRef = FirebaseDatabase.instance.ref('nodes_presence/$nodeID');
          try {
            presenceRef.onDisconnect().remove();
          } catch (_) {}
          
          presenceRef.set({
            'lat': position.latitude,
            'lng': position.longitude,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          });
        }
      });
    } catch (e) {
      debugPrint("GPS Retrieval Error: $e");
    }
  }

  void _toggleStreaming(bool val) {
    if (_isDisabled && val) return; // Prevent turning on if disabled

    setState(() {
      _isStreaming = val;
      final liveRef = FirebaseDatabase.instance.ref('live_waves/$nodeID');
      
      if (_isStreaming) {
        _detector.forceRecalibration();
        
        try {
          liveRef.onDisconnect().remove();
        } catch (_) {}

        _liveWaveTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
           liveRef.set({
             'mag': _currentWaveMagnitude,
             'ts': DateTime.now().millisecondsSinceEpoch,
           });
        });
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
    _positionSub?.cancel();
    _sensitivitySub?.cancel();
    _hpfSub?.cancel();
    _statusSub?.cancel();
    FirebaseDatabase.instance.ref('nodes_presence/$nodeID').remove();
    _liveWaveTimer?.cancel();
    final liveRef = FirebaseDatabase.instance.ref('live_waves/$nodeID');
    try {
      liveRef.onDisconnect().cancel();
    } catch (_) {}
    liveRef.remove();
    
    _gyroSub?.cancel();
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
            
            // Disabled Warning Message
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
            
            const SizedBox(height: 40),
            SwitchListTile(
              title: const Text('Transmit Telemetry'),
              value: _isStreaming,
              activeThumbColor: Colors.greenAccent, 
              // Nullify onChanged if disabled to prevent user from turning it on
              onChanged: _isDisabled ? null : _toggleStreaming,
            ),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------
// 4. THE HUB
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

class _HubScreenState extends State<HubScreen> {
  late final DatabaseReference _networkRef;
  late final DatabaseReference _liveRef;

  final List<double> _networkPeakWaveform = List.filled(60, 0.0, growable: true); 
  final Map<String, List<double>> _nodeWaveforms = {};
  final Map<String, Map<String, dynamic>> _nodeLatestEvents = {};
  
  final Map<String, LatLng> _activeNodes = {};
  final Map<String, LatLng> _activeHubs = {};
  final Map<String, double> _nodeSensitivities = {}; 
  final Map<String, bool> _disabledNodes = {}; // Tracks disabled state

  late final String _hubId;

  Map<String, dynamic>? _firstReadingInPair;
  
  LatLng _hubLocation = const LatLng(17.9846, -76.9714);
  
  String _currentMapStyle = 'dark_all';
  bool _isTectonicLayerActive = false;
  double _globalHpfAlpha = 0.9;

  final List<MapItemData> _epicenterDataList = [];
  
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

  @override
  void initState() {
    super.initState();
    _hubId = 'hub_${math.Random().nextInt(999999)}';
    _networkRef = FirebaseDatabase.instance.ref('sensor_network');
    _liveRef = FirebaseDatabase.instance.ref('live_waves');
    
    _hubBootTimeUs = DateTime.now().millisecondsSinceEpoch * 1000;
    
    if (kIsWeb || defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) {
      _initHubGPS();
    }
    
    _listenToNetworkPresence();
    _listenToFirebase();
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
          try {
            hubRef.onDisconnect().remove();
          } catch (_) {}
          
          hubRef.set({
            'lat': position.latitude,
            'lng': position.longitude,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          });
        }
      });
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
        });
      } else {
        setState(() => _activeNodes.clear());
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

      if (mounted) {
        setState(() {
          double networkPeakMagnitude = 0.0;
          Set<String> liveNodeIds = {}; 

          rawData.forEach((key, value) {
            if (value is Map) {
              String nodeId = key.toString();
              int ts = (value['ts'] as num? ?? 0).toInt();
              
              if (now - ts < 2000) {
                liveNodeIds.add(nodeId);
                double val = (value['mag'] as num? ?? 0.0).toDouble();
                
                if (val > networkPeakMagnitude) {
                  networkPeakMagnitude = val;
                }

                if (!_nodeWaveforms.containsKey(nodeId)) {
                   _nodeWaveforms[nodeId] = List.filled(60, 0.0, growable: true);
                }
                _nodeWaveforms[nodeId]!.add(val);
                if (_nodeWaveforms[nodeId]!.length > 60) _nodeWaveforms[nodeId]!.removeAt(0);
              }
            }
          });

          _nodeWaveforms.removeWhere((key, _) => !liveNodeIds.contains(key));
          _networkPeakWaveform.add(networkPeakMagnitude);
          if (_networkPeakWaveform.length > 60) _networkPeakWaveform.removeAt(0);
        });
      }
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
    if (_activeNodes.length < 2) return; 

    String nodeId = newReading['node_id'] ?? 'unknown';

    if (_firstReadingInPair == null) {
      _firstReadingInPair = newReading;
      return;
    }

    if (_firstReadingInPair!['node_id'] == nodeId) {
      _firstReadingInPair = newReading; 
      return;
    }

    double lat1 = (_firstReadingInPair!['lat'] as num).toDouble();
    double lng1 = (_firstReadingInPair!['lng'] as num).toDouble();
    LatLng loc1 = LatLng(lat1, lng1);

    double lat2 = (newReading['lat'] as num).toDouble();
    double lng2 = (newReading['lng'] as num).toDouble();
    LatLng loc2 = LatLng(lat2, lng2);

    int time1Us = (_firstReadingInPair!['timestamp_us'] as num).toInt();
    int time2Us = (newReading['timestamp_us'] as num).toInt();
    
    double timeDeltaSecs = (time2Us - time1Us).abs() / 1000000.0;
    double distanceBetweenNodes = const Distance().as(LengthUnit.Meter, loc1, loc2);
    
    double calculatedWaveSpeedMps = timeDeltaSecs > 0 ? (distanceBetweenNodes / timeDeltaSecs) : 0.0;
    double originAngle = (_firstReadingInPair!['angle'] as num).toDouble();
    
    double epicenterDistanceMeters = timeDeltaSecs * calculatedWaveSpeedMps;
    LatLng epicenter = const Distance().offset(loc1, epicenterDistanceMeters, originAngle);

    _plotEpicenter(epicenter, "Bolt Equation Epicenter", calculatedWaveSpeedMps);
    _firstReadingInPair = null; 
  }

  void _plotEpicenter(LatLng location, String label, double calculatedSpeed) {
    _epicenterDataList.add(MapItemData(
      id: 'epi_${DateTime.now().millisecondsSinceEpoch}_${math.Random().nextInt(1000)}',
      loc: location,
      type: MapItemType.epicenter,
      tooltipMessage: "$label\nLat: ${location.latitude.toStringAsFixed(4)}, Lng: ${location.longitude.toStringAsFixed(4)}\nCalculated Speed: ${calculatedSpeed.toStringAsFixed(2)} m/s",
    ));
    
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
      // Show nodes on the map regardless of whether they have a waveform streaming
      rawItems.add(MapItemData(
        id: id,
        loc: loc,
        type: MapItemType.node,
        tooltipMessage: "Node: $id\nLat: ${loc.latitude.toStringAsFixed(4)}, Lng: ${loc.longitude.toStringAsFixed(4)}",
      ));
    });

    rawItems.addAll(_epicenterDataList);

    Map<String, List<MapItemData>> grid = {};
    for (var item in rawItems) {
      String key = "${item.loc.latitude.toStringAsFixed(4)}_${item.loc.longitude.toStringAsFixed(4)}";
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
        // Adjust map icon color if disabled
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

  // ----------------------------------------------------------------------
  // SETTINGS MENUS
  // ----------------------------------------------------------------------
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
                  const Text("Map Theme", style: TextStyle(color: Colors.white70)),
                  DropdownButton<String>(
                    dropdownColor: const Color(0xFF16161F),
                    value: _currentMapStyle,
                    items: ['light_all', 'dark_all', 'rastertiles/voyager']
                        .map((s) => DropdownMenuItem(value: s, child: Text(s.toUpperCase(), style: const TextStyle(color: Colors.white))))
                        .toList(),
                    onChanged: (val) {
                      if (val != null) setState(() => _currentMapStyle = val);
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
    _networkAddSub?.cancel();
    _networkChangeSub?.cancel();
    _liveSub?.cancel();
    _hubPositionSub?.cancel();
    _nodesPresenceSub?.cancel();
    _hubsPresenceSub?.cancel();
    _nodeSettingsSub?.cancel();
    _hpfSettingsSub?.cancel();
    FirebaseDatabase.instance.ref('diagnostic_hubs/$_hubId').remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text("DIAGNOSTIC HUB"),
          actions: [
            // Sign Out Button
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
            ],
          ),
        ),
        body: TabBarView(
          physics: const NeverScrollableScrollPhysics(),
          children: [
            _buildTelemetryTab(),
            _buildMapTab(),
          ],
        ),
      ),
    );
  }

  Widget _buildTelemetryTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
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
                    child: CustomPaint(painter: LiveStreamPainter(_networkPeakWaveform)),
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
    );
  }

  Widget _buildNodeCard(String nodeId) {
    final waveform = _nodeWaveforms[nodeId] ?? List.filled(60, 0.0);
    final latestEvent = _nodeLatestEvents[nodeId];
    final location = _activeNodes[nodeId];
    
    double angle = (latestEvent?['angle'] ?? 0.0).toDouble();
    double localSpeed = (latestEvent?['speed_mps'] ?? 0.0).toDouble();
    String latStr = location != null ? location.latitude.toStringAsFixed(4) : "Awaiting Lock";
    String lngStr = location != null ? location.longitude.toStringAsFixed(4) : "Awaiting Lock";
    
    bool hasEvent = latestEvent != null;
    bool canCalculateSpeed = _activeNodes.length >= 2;
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
                  // Status & Toggle Control
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.circle, color: isDisabled ? Colors.redAccent : Colors.greenAccent, size: 12),
                      const SizedBox(width: 4),
                      Text(isDisabled ? "Disabled" : "Active", style: TextStyle(color: isDisabled ? Colors.redAccent : Colors.greenAccent, fontWeight: FontWeight.bold)),
                      const Spacer(),
                      Switch(
                        value: !isDisabled,
                        activeThumbColor: Colors.greenAccent, // Changed from activeColor to activeThumbColor
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
                    child: Icon(Icons.arrow_upward, size: 40, color: hasEvent ? Colors.redAccent : Colors.grey.shade800),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    hasEvent ? "${angle.toStringAsFixed(1)}°" : "N/A", 
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: hasEvent ? Colors.white : Colors.grey.shade600)
                  ),
                  const SizedBox(height: 4),
                  if (hasEvent)
                    canCalculateSpeed 
                      ? Text("${localSpeed.toStringAsFixed(1)} m/s", style: const TextStyle(color: Colors.cyanAccent, fontSize: 14))
                      : const Text("Speed calc unavailable:\n<2 Active Nodes", textAlign: TextAlign.center, style: TextStyle(color: Colors.orangeAccent, fontSize: 12)),
                ],
              ),
            ),
            
            Container(width: 1, height: 120, color: Colors.white12, margin: const EdgeInsets.symmetric(horizontal: 16)),
            
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text("LIVE STREAM", style: TextStyle(fontSize: 12, letterSpacing: 1.0, color: Colors.grey)),
                  const SizedBox(height: 8),
                  Container(
                    height: 120,
                    decoration: BoxDecoration(border: Border.all(color: Colors.white10), color: Colors.black26),
                    child: isDisabled 
                        ? const Center(child: Text("DATA STREAM HALTED", style: TextStyle(color: Colors.redAccent, letterSpacing: 2.0, fontWeight: FontWeight.bold)))
                        : CustomPaint(painter: LiveStreamPainter(waveform, strokeColor: Colors.blueAccent)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMapTab() {
    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: _hubLocation, 
            initialZoom: 16.0,
            maxZoom: 22.0, 
            onMapReady: () {
              _isMapReady = true;
            },
          ),
          children: [
            if (_isTectonicLayerActive) ...[
              TileLayer(
                urlTemplate: 'assets/protomaps_tectonic_base/{z}/{x}/{y}.png',
                tileProvider: AssetTileProvider(),
                maxNativeZoom: 12, 
              ),
              const OfflineTectonicVectorLayer(),
            ] else ...[
              TileLayer(
                urlTemplate: 'https://{s}.basemaps.cartocdn.com/$_currentMapStyle/{z}/{x}/{y}.png',
                subdomains: const ['a', 'b', 'c', 'd'],
                userAgentPackageName: 'com.seismic.network', 
                maxNativeZoom: 19, 
              ),
            ],

            MarkerLayer(markers: _buildAllMarkers()),
          ],
        ),
        
        Positioned(
          top: 20,
          left: 20,
          child: Card(
            color: const Color(0xFF16161F).withValues(alpha: 0.95), 
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Row(
                children: [
                  const Text("Tectonic Plate Data", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                  const SizedBox(width: 12),
                  Switch(
                    value: _isTectonicLayerActive,
                    activeThumbColor: Colors.amberAccent, 
                    onChanged: (val) => setState(() => _isTectonicLayerActive = val),
                  ),
                ],
              ),
            ),
          ),
        ),

        if (_activeNodes.length < 2)
          Positioned(
            bottom: 20, 
            right: 20,
            child: Card(
              color: Colors.redAccent.withValues(alpha: 0.9), 
              elevation: 8,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12.0, horizontal: 16.0),
                child: Text(
                  "Less than two nodes – Epicentre Calculation Unavailable",
                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class LiveStreamPainter extends CustomPainter {
  final List<double> values;
  final Color strokeColor;

  LiveStreamPainter(this.values, {this.strokeColor = Colors.greenAccent});

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final paint = Paint()..color = strokeColor..strokeWidth = 2.5..style = PaintingStyle.stroke;
    final path = Path();
    final double dx = size.width / (values.length - 1);
    
    double maxVal = values.reduce((a, b) => math.max(a, b)); 
    
    if (maxVal < 1.0) maxVal = 1.0; 
    path.moveTo(0, size.height - (values[0] / maxVal) * size.height);
    for (int i = 1; i < values.length; i++) {
      double yVal = size.height - (values[i] / maxVal) * size.height;
      path.lineTo(i * dx, yVal);
    }
    canvas.drawPath(path, paint);
  }
  @override
  bool shouldRepaint(covariant LiveStreamPainter oldDelegate) => true;
}

class OfflineTectonicVectorLayer extends StatefulWidget {
  const OfflineTectonicVectorLayer({super.key});
  @override
  State<OfflineTectonicVectorLayer> createState() => _OfflineTectonicVectorLayerState();
}

class _OfflineTectonicVectorLayerState extends State<OfflineTectonicVectorLayer> {
  List<Polyline> _tectonicPolylines = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadTectonicData();
  }

  Future<void> _loadTectonicData() async {
    try {
      final String response = await rootBundle.loadString('assets/data/tectonic_boundaries.geojson');
      final data = json.decode(response);
      List<Polyline> tempLines = [];

      if (data['features'] != null) {
        for (var feature in data['features']) {
          final geometry = feature['geometry'];
          final properties = feature['properties'] ?? {};
          final String boundaryType = (properties['type'] ?? properties['Type'] ?? properties['TYPE'] ?? 'unknown').toString().toLowerCase();
          
          Color strokeColor;
          double strokeWidth = 3.0;
          
          if (boundaryType.contains('convergent') || boundaryType.contains('subduction')) {
            strokeColor = Colors.redAccent;
            strokeWidth = 4.0;
          } else if (boundaryType.contains('divergent') || boundaryType.contains('ridge')) {
            strokeColor = Colors.cyanAccent;
          } else if (boundaryType.contains('transform') || boundaryType.contains('fault')) {
            strokeColor = Colors.amberAccent;
          } else {
            strokeColor = Colors.purpleAccent; 
          }

          if (geometry != null && geometry['type'] == 'LineString') {
            List<LatLng> points = [];
            for (var coord in geometry['coordinates']) {
              points.add(LatLng(coord[1].toDouble(), coord[0].toDouble()));
            }
            tempLines.add(Polyline(points: points, color: strokeColor, strokeWidth: strokeWidth));
          } else if (geometry != null && geometry['type'] == 'MultiLineString') {
            for (var line in geometry['coordinates']) {
              List<LatLng> points = [];
              for (var coord in line) {
                points.add(LatLng(coord[1].toDouble(), coord[0].toDouble()));
              }
              tempLines.add(Polyline(points: points, color: strokeColor, strokeWidth: strokeWidth));
            }
          }
        }
      }

      if (mounted) {
        setState(() {
          _tectonicPolylines = tempLines;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint("Failed to parse tectonic vector asset: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: Colors.amberAccent));
    }
    return PolylineLayer(polylines: _tectonicPolylines);
  }
}