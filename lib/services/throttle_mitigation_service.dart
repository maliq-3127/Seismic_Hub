import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Fix #6: "add system to make android or ios user go into their settings
/// to disable or mitigate the throttling."
///
/// Uses `defaultTargetPlatform` rather than dart:io's `Platform` - this
/// service is reached from UI code that already runs on web (the app's
/// existing kIsWeb branches show this project targets web too), and
/// `dart:io` is not available there; `defaultTargetPlatform` is what the
/// rest of this app already uses for the same kind of check.
///
/// Requires `permission_handler` in pubspec.yaml, and on Android requires
/// this manifest entry (AndroidManifest.xml isn't part of the lib/ folder,
/// so it isn't included here - add it yourself):
// ignore: unintended_html_in_doc_comment
///   <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />
enum ThrottleMitigationResult { alreadyGranted, granted, openedSettings, notApplicable, error }

class ThrottleMitigationService {
  /// Whether it's worth showing the user a prompt at all - false on web,
  /// on iOS (no checkable status exists there), or if the exemption is
  /// already granted.
  static Future<bool> isLikelyThrottled() async {
    if (kIsWeb) return false;
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      final status = await Permission.ignoreBatteryOptimizations.status;
      return !status.isGranted;
    } catch (_) {
      return false;
    }
  }

  static Future<ThrottleMitigationResult> requestMitigation() async {
    if (kIsWeb) return ThrottleMitigationResult.notApplicable;
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final status = await Permission.ignoreBatteryOptimizations.status;
        if (status.isGranted) return ThrottleMitigationResult.alreadyGranted;

        // A handful of OEM builds have historically thrown when this
        // system dialog is dismissed via the back button rather than
        // answered directly; the try/catch around this whole method
        // covers that, and either way we fall through to the manual
        // settings screen below.
        final requested = await Permission.ignoreBatteryOptimizations.request();
        if (requested.isGranted) return ThrottleMitigationResult.granted;

        await openAppSettings();
        return ThrottleMitigationResult.openedSettings;
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        // iOS has no public API to exempt an app from background
        // throttling - point the user at Background App Refresh instead.
        await openAppSettings();
        return ThrottleMitigationResult.openedSettings;
      }
      return ThrottleMitigationResult.notApplicable;
    } catch (_) {
      return ThrottleMitigationResult.error;
    }
  }
}
