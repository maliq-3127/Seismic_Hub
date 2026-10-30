import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

/// Local notification + alert sound whenever the hub detects a new
/// disturbance (see main.dart's _handleEstimateUpdate).
///
/// Scope worth being explicit about: this fires from Dart code that's
/// actually running, which covers the app in the foreground and, on most
/// platforms, backgrounded-but-not-killed. It is NOT a substitute for a
/// true push-based alert that would wake the app from fully closed/
/// terminated - that needs a server watching the data and sending a real
/// push notification (Firebase Cloud Messaging via a Cloud Function),
/// which is backend infrastructure, not something addable from client
/// code alone. This covers "the Hub app is open and running", which is
/// what was asked for (mobile or desktop) - not "alert me even if I fully
/// quit the app."
///
/// Deliberately skipped on web: this plugin combination isn't wired up
/// for a browser context here, and desktop/mobile is what was asked for.
class AlertService {
  static final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  static final AudioPlayer _player = AudioPlayer();
  static bool _initialized = false;
  static int _nextNotificationId = 0;

  static Future<void> initialize() async {
    if (kIsWeb || _initialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const linuxSettings = LinuxInitializationSettings(defaultActionName: 'Open GyroHub');
    // guid below is a fixed, randomly-generated identifier for this app -
    // not registered anywhere, just needs to be stable and unique to this
    // app so Windows can group its notifications correctly.
    const windowsSettings = WindowsInitializationSettings(
      appName: 'GyroHub',
      appUserModelId: 'com.gyrohub.hub',
      guid: '84971eba-b2c7-4433-bbaa-e73eb4d69f0c',
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
      macOS: darwinSettings,
      linux: linuxSettings,
      windows: windowsSettings,
    );

    try {
      await _notifications.initialize(initSettings);
      // Darwin (iOS/macOS) permission prompting is handled by the
      // request*Permission flags above, as part of initialize() itself.
      // Android 13+ needs its own runtime permission request, separately.
      if (defaultTargetPlatform == TargetPlatform.android) {
        await Permission.notification.request();
      }
      _initialized = true;
    } catch (e) {
      debugPrint('AlertService failed to initialize: $e');
    }
  }

  /// Plays the alert sound and raises a system notification. Call this
  /// only for a genuinely new disturbance (see the isNewEvent check at the
  /// call site) - not on every refinement of one already known about,
  /// which would turn this into a spam of repeat alerts for one real event.
  static Future<void> raiseDisturbanceAlert({
    required String methodLabel,
    required double latitude,
    required double longitude,
  }) async {
    if (kIsWeb) return;
    if (!_initialized) await initialize();

    unawaited(_player.play(AssetSource('sounds/alert.wav')));

    const androidDetails = AndroidNotificationDetails(
      'disturbance_alerts',
      'Disturbance alerts',
      channelDescription: 'Notifies when the network detects a new seismic disturbance',
      importance: Importance.max,
      priority: Priority.high,
    );
    const darwinDetails = DarwinNotificationDetails(presentSound: true, presentAlert: true, presentBadge: true);
    const linuxDetails = LinuxNotificationDetails();
    const windowsDetails = WindowsNotificationDetails();

    const details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
      linux: linuxDetails,
      windows: windowsDetails,
    );

    try {
      await _notifications.show(
        _nextNotificationId++,
        'Disturbance detected',
        '$methodLabel near ${latitude.toStringAsFixed(3)}, ${longitude.toStringAsFixed(3)}',
        details,
      );
    } catch (e) {
      debugPrint('AlertService failed to show notification: $e');
    }
  }
}
