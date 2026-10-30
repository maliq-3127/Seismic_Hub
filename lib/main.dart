import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'dart:math' as math;
import 'disturbance_detector.dart';
import 'firebase_options.dart';
import 'dart:async';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    // Check if Firebase is already initialized to prevent [core/duplicate-app]
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
  } catch (e) {
    // FIX: Replaced standard print with debugPrint for production safety
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
      title: 'Seismic Network V4',
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
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HubScreen())),
            ),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------
// 2. NODE SCREEN (Added Sliders & Real-Time Wave)
// ----------------------------------------------------------------------
class NodeScreen extends StatefulWidget {
  const NodeScreen({super.key});
  @override
  State<NodeScreen> createState() => _NodeScreenState();
}

class _NodeScreenState extends State<NodeScreen> {
  String nodeID = 'node_1'; 
  late DatabaseReference _database;
  bool _isStreaming = false;
  final DisturbanceDetector _detector = DisturbanceDetector();
  double _calibrationProgress = 0.0;

  // Real-time pushing timer
  Timer? _liveWaveTimer;
  double _currentWaveMagnitude = 0.0;

  // StreamSubscription variables to prevent memory leaks
  StreamSubscription? _gyroSub;
  StreamSubscription? _calibSub;
  StreamSubscription? _waveSub;
  StreamSubscription? _distSub;

  @override
  void initState() {
    super.initState();
    _database = FirebaseDatabase.instance.ref('sensor_network/$nodeID');

    _gyroSub = gyroscopeEventStream().listen((event) {
      if (_isStreaming) _detector.processGyroscopeData(event.x, event.y);
    });

    _calibSub = _detector.onCalibrationProgress.listen((progress) {
      if (mounted) setState(() => _calibrationProgress = progress);
    });

    _waveSub = _detector.onLiveWave.listen((mag) => _currentWaveMagnitude = mag);

    _distSub = _detector.onDisturbanceDetected.listen((result) {
      if (_isStreaming) {
        _database.set({
          'node_id': nodeID,
          'event_type': 'disturbance',
          'angle': result.angleDegrees,
          'speed_mps': result.estimatedSpeedMps,
          'reset_time_ms': result.resetTime.inMilliseconds,
          'timestamp_us': result.preciseTimestampUs,
        });
      }
    });
  }

  void _toggleStreaming(bool val) {
    setState(() {
      _isStreaming = val;
      if (_isStreaming) {
        _detector.forceRecalibration();
        // Push live wave data to Firebase at 20Hz (50ms) for real-time graph
        _liveWaveTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
           FirebaseDatabase.instance.ref('live_waves/$nodeID').set(_currentWaveMagnitude);
        });
      } else {
        _liveWaveTimer?.cancel();
      }
    });
  }

  @override
  void dispose() {
    _liveWaveTimer?.cancel();
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
      appBar: AppBar(title: const Text('Node Tuner')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            if (isCalibrating && _isStreaming) ...[
              LinearProgressIndicator(value: _calibrationProgress),
              const SizedBox(height: 10),
              const Text("Learning Ambient Noise..."),
            ] else ...[
              Icon(Icons.radar, size: 60, color: _isStreaming ? Colors.greenAccent : Colors.grey),
            ],
            const SizedBox(height: 30),
            
            // SENSITIVITY SLIDER
            const Text("Sensitivity Multiplier", style: TextStyle(fontWeight: FontWeight.bold)),
            Slider(
              value: _detector.sensitivityMultiplier,
              min: 0.1,
              max: 3.0,
              divisions: 29,
              label: _detector.sensitivityMultiplier.toStringAsFixed(1),
              activeColor: Colors.amber,
              onChanged: (val) => setState(() => _detector.sensitivityMultiplier = val),
            ),
            
            // SPEED CALIBRATION SLIDER
            const Text("Speed/Intensity Calibration", style: TextStyle(fontWeight: FontWeight.bold)),
            Slider(
              value: _detector.speedMultiplier,
              min: 0.1,
              max: 3.0,
              divisions: 29,
              label: _detector.speedMultiplier.toStringAsFixed(1),
              activeColor: Colors.cyanAccent,
              onChanged: (val) => setState(() => _detector.speedMultiplier = val),
            ),

            const SizedBox(height: 40),
            SwitchListTile(
              title: const Text('Transmit Telemetry'),
              value: _isStreaming,
              // FIX: Replaced deprecated activeColor with activeThumbColor
              activeThumbColor: Colors.greenAccent, 
              onChanged: _toggleStreaming,
            ),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------
// 3. THE HUB (360 Radar & Real-Time Graph)
// ----------------------------------------------------------------------
class HubScreen extends StatefulWidget {
  const HubScreen({super.key});
  @override
  State<HubScreen> createState() => _HubScreenState();
}

class _HubScreenState extends State<HubScreen> {
  final DatabaseReference _networkRef = FirebaseDatabase.instance.ref('sensor_network');
  final DatabaseReference _liveRef = FirebaseDatabase.instance.ref('live_waves');

  Map<String, dynamic>? _latestEvent;
  final List<double> _realTimeWaveform = List.filled(60, 0.0, growable: true); 

  // Track Hub stream subscriptions
  StreamSubscription? _networkSub;
  StreamSubscription? _liveSub;

  @override
  void initState() {
    super.initState();
    
    // Listen for distinct impacts
    _networkSub = _networkRef.onValue.listen((event) {
      if (event.snapshot.value != null) {
        final rawData = event.snapshot.value as Map;
        rawData.forEach((key, data) {
          final map = Map<String, dynamic>.from(data as Map);
          if (map['event_type'] == 'disturbance') {
            if (mounted) setState(() => _latestEvent = map);
          }
        });
      }
    });

    // Listen for high-speed live wave data (Real-Time UI)
    _liveSub = _liveRef.onValue.listen((event) {
      if (event.snapshot.value != null) {
        final rawData = event.snapshot.value as Map;
        // Assuming we are monitoring node_1's live wave
        if (rawData.containsKey('node_1')) {
          double val = (rawData['node_1'] as num).toDouble();
          if (mounted) {
            setState(() {
              _realTimeWaveform.add(val);
              if (_realTimeWaveform.length > 60) _realTimeWaveform.removeAt(0);
            });
          }
        }
      }
    });
  }

  @override
  void dispose() {
    _networkSub?.cancel();
    _liveSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    double angle = (_latestEvent?['angle'] ?? 0.0).toDouble();
    double speed = (_latestEvent?['speed_mps'] ?? 0.0).toDouble();

    return Scaffold(
      appBar: AppBar(title: const Text("HUB: Real-Time Telemetry")),
      body: Row(
        children: [
          // LEFT PANEL: 360 Vector Radar
          Expanded(
            flex: 1,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text("DISTURBANCE DIRECTION (360°)", style: TextStyle(letterSpacing: 2.0, color: Colors.grey)),
                const SizedBox(height: 40),
                Transform.rotate(
                  // Negated the angle to invert left/right orientation while preserving up/down
                  angle: -angle * (math.pi / 180), 
                  child: const Icon(Icons.arrow_upward, size: 120, color: Colors.redAccent),
                ),
                const SizedBox(height: 20),
                Text("${angle.toStringAsFixed(1)}°", style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
                Text("${speed.toStringAsFixed(2)} m/s", style: const TextStyle(color: Colors.cyanAccent, fontSize: 24)),
              ],
            ),
          ),
          
          Container(width: 1, color: Colors.white12),
          
          // RIGHT PANEL: Real-Time Stream Graph
          Expanded(
            flex: 1,
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text("LIVE KINETIC STREAM (20Hz)", style: TextStyle(letterSpacing: 1.5, color: Colors.grey)),
                  Expanded(
                    child: Container(
                      margin: const EdgeInsets.only(top: 20),
                      decoration: BoxDecoration(border: Border.all(color: Colors.white10), color: Colors.black26),
                      child: CustomPaint(painter: LiveStreamPainter(_realTimeWaveform)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class LiveStreamPainter extends CustomPainter {
  final List<double> values;
  LiveStreamPainter(this.values);

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;

    final paint = Paint()
      ..color = Colors.greenAccent
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    final path = Path();
    final double dx = size.width / (values.length - 1);
    
    // Auto-scaling the Y axis based on current peak
    double maxVal = values.reduce(math.max);
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