// --- SYSTEM & NETWORK IMPORTS ---
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

// --- UI & HARDWARE PLUGINS ---
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:geolocator/geolocator.dart';

// ==========================================
// 1. APPLICATION ENTRY POINT
// ==========================================
void main() {
  runApp(const GyroHubApp());
}

class GyroHubApp extends StatelessWidget {
  const GyroHubApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Seismic Net',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const MainNavigation(),
    );
  }
}

// ==========================================
// 2. BOTTOM NAVIGATION WRAPPER
// ==========================================
class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _currentIndex = 0;

  final List<Widget> _pages = [
    const RoleSelectionPage(),
    const WarningLevelsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_currentIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.hub), label: 'Network'),
          NavigationDestination(icon: Icon(Icons.warning_amber_rounded), label: 'Warning Levels'),
        ],
      ),
    );
  }
}

// ==========================================
// 3. ROLE SELECTION PAGE (MAIN MENU)
// ==========================================
class RoleSelectionPage extends StatelessWidget {
  const RoleSelectionPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Network Setup')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text("Select Device Role", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 40),
            ElevatedButton.icon(
              icon: const Icon(Icons.cell_tower, size: 32),
              label: const Text("Initialize as HUB", style: TextStyle(fontSize: 20)),
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20)),
              onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (context) => const HubPage()),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              icon: const Icon(Icons.sensors, size: 32),
              label: const Text("Initialize as NODE", style: TextStyle(fontSize: 20)),
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20)),
              onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (context) => const NodePage()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================
// 4. HUB PAGE (THE SERVER / RECEIVER)
// ==========================================
class HubPage extends StatefulWidget {
  const HubPage({super.key});
  @override
  State<HubPage> createState() => _HubPageState();
}

class _HubPageState extends State<HubPage> {
  RawDatagramSocket? _udpSocket;
  final List<String> _connectedNodes = [];
  final Map<String, Map<String, dynamic>> _nodeData = {};

  @override
  void initState() {
    super.initState();
    _startListening();
  }

  void _startListening() async {
    try {
      _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 5000);
      _udpSocket?.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          Datagram? datagram = _udpSocket?.receive();
          if (datagram != null) {
            String message = utf8.decode(datagram.data);
            _processNodeData(datagram.address.address, message);
          }
        }
      });
    } catch (e) {
      debugPrint("Failed to bind socket. Is port 5000 in use?");
    }
  }

  void _processNodeData(String ip, String data) {
    try {
      final decodedData = jsonDecode(data);
      
      // ERROR FIX: Ensure the widget is still alive before updating the UI
      if (!mounted) return;

      setState(() {
        if (!_connectedNodes.contains(ip)) _connectedNodes.add(ip);
        
        double magnitude = sqrt(pow(decodedData['x'], 2) + pow(decodedData['y'], 2) + pow(decodedData['z'], 2));
        
        _nodeData[ip] = {
          'severity': magnitude,
          'lat': decodedData['lat'],
          'lng': decodedData['lng'],
        };
      });
    } catch (e) {
      // Ignore malformed packets silently
    }
  }

  @override
  void dispose() {
    _udpSocket?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Hub Dashboard')),
      body: _connectedNodes.isEmpty
          ? const Center(child: Text("Listening for Nodes on Port 5000...", style: TextStyle(color: Colors.grey)))
          : ListView.builder(
              itemCount: _connectedNodes.length,
              itemBuilder: (context, index) {
                String ip = _connectedNodes[index];
                var data = _nodeData[ip];
                double severity = data?['severity'] ?? 0.0;
                double lat = data?['lat'] ?? 0.0;
                double lng = data?['lng'] ?? 0.0;

                return Card(
                  margin: const EdgeInsets.all(8.0),
                  child: ListTile(
                    leading: const Icon(Icons.wifi_tethering, color: Colors.green),
                    title: Text('Node IP: $ip'),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Severity: ${severity.toStringAsFixed(2)}'),
                        Text('Location: ${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      ],
                    ),
                    trailing: Icon(
                      Icons.warning,
                      color: severity > 5.0 ? Colors.red : Colors.grey,
                    ),
                  ),
                );
              },
            ),
    );
  }
}

// ==========================================
// 5. NODE PAGE (THE CLIENT / SENDER)
// ==========================================
class NodePage extends StatefulWidget {
  const NodePage({super.key});
  @override
  State<NodePage> createState() => _NodePageState();
}

class _NodePageState extends State<NodePage> {
  final TextEditingController _ipController = TextEditingController();
  bool _isRegistered = false;
  bool _permissionDenied = false;
  
  StreamSubscription? _gyroSubscription;
  StreamSubscription<Position>? _positionSubscription;
  RawDatagramSocket? _udpSocket;
  Position? _currentPosition;
  DateTime _lastSendTime = DateTime.now();

  void _requestPermissionAndConnect() async {
    // ERROR FIX: Safely parse the IP. If it's invalid, alert the user and stop.
    InternetAddress? hubAddress = InternetAddress.tryParse(_ipController.text.trim());
    
    if (hubAddress == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Invalid IP Address format. Please check and try again.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    // Check location permission
    LocationPermission locationStatus = await Geolocator.checkPermission();
    if (locationStatus == LocationPermission.denied) {
      locationStatus = await Geolocator.requestPermission();
    }

    bool locationGranted = locationStatus == LocationPermission.always || locationStatus == LocationPermission.whileInUse;

    if (locationGranted) {
      _startStreamingData(hubAddress);
    } else {
      if (!mounted) return;
      setState(() {
        _permissionDenied = true;
      });
    }
  }

  void _startStreamingData(InternetAddress hubAddress) async {
    try {
      _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } catch (e) {
      debugPrint("Could not bind UDP socket.");
      return;
    }

    if (!mounted) return;
    setState(() {
      _isRegistered = true;
      _permissionDenied = false;
    });

    // Start background GPS stream
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high)
    ).listen((Position position) {
      _currentPosition = position;
    });

    // Start Gyro stream
    _gyroSubscription = gyroscopeEventStream().listen((GyroscopeEvent event) {
      final now = DateTime.now();
      
      // ERROR FIX: Throttle the network traffic to 10 updates per second
      if (now.difference(_lastSendTime).inMilliseconds > 100) {
        _lastSendTime = now;

        String payload = jsonEncode({
          'x': event.x,
          'y': event.y,
          'z': event.z,
          'lat': _currentPosition?.latitude ?? 0.0,
          'lng': _currentPosition?.longitude ?? 0.0,
          'timestamp': now.toIso8601String()
        });
        
        // ERROR FIX: Network drop protection. Catch errors if Wi-Fi disconnects mid-send.
        try {
          _udpSocket?.send(utf8.encode(payload), hubAddress, 5000);
        } catch (e) {
          debugPrint("Failed to send packet. Network may be unreachable.");
        }
      }
    });
  }

  @override
  void dispose() {
    _gyroSubscription?.cancel();
    _positionSubscription?.cancel();
    _udpSocket?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isRegistered) {
      return Scaffold(
        appBar: AppBar(title: const Text('Node Status')),
        body: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.check_circle_outline, color: Colors.green, size: 80),
              SizedBox(height: 20),
              Text("The node has been registered!", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              SizedBox(height: 10),
              Text("Streaming safely to Hub...", style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Configure Node')),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_permissionDenied)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 20),
                color: Colors.red.withOpacity(0.2),
                child: const Text(
                  "Error: GPS permission is strictly necessary for this application to run.",
                  style: TextStyle(color: Colors.redAccent),
                  textAlign: TextAlign.center,
                ),
              ),
            TextField(
              controller: _ipController,
              decoration: const InputDecoration(
                labelText: "Enter Hub IP Address",
                border: OutlineInputBorder(),
                hintText: "e.g. 192.168.1.50",
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _requestPermissionAndConnect,
              child: const Text("Request Permission & Connect"),
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================
// 6. WARNING LEVELS PAGE (PLACEHOLDER FOR ML)
// ==========================================
class WarningLevelsPage extends StatelessWidget {
  const WarningLevelsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Predictive AI Warning Levels')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("System Status: Active Learning", style: TextStyle(fontSize: 18, color: Colors.green)),
            const SizedBox(height: 20),
            const Text("Zone Predictions", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            
            Expanded(
              child: ListView(
                children: const [
                  PredictionCard(zone: "Zone Alpha (Living Room)", level: "Low", probability: "12%"),
                  PredictionCard(zone: "Zone Beta (Kitchen)", level: "Elevated", probability: "48%"),
                  PredictionCard(zone: "Zone Gamma (Foundation)", level: "Critical", probability: "89%", isCritical: true),
                ],
              ),
            )
          ],
        ),
      ),
    );
  }
}

class PredictionCard extends StatelessWidget {
  final String zone;
  final String level;
  final String probability;
  final bool isCritical; 

  const PredictionCard({
    super.key,
    required this.zone,
    required this.level,
    required this.probability,
    this.isCritical = false,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: isCritical ? Colors.red.withOpacity(0.2) : Colors.black12,
      child: ListTile(
        title: Text(zone),
        subtitle: Text("Predicted Shake Probability: $probability"),
        trailing: Chip(
          label: Text(level),
          backgroundColor: isCritical ? Colors.red : Colors.green,
        ),
      ),
    );
  }
}