import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform, kIsWeb;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyA0x8eAS237A3nayL3ZrZTDjcEXvAxw91g',
    appId: '1:345080171965:web:1352873f511e4ba04f96d4',
    messagingSenderId: '345080171965',
    projectId: 'gyrohub',
    databaseURL: 'https://gyrohub-default-rtdb.firebaseio.com',
    storageBucket: 'gyrohub.firebasestorage.app',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyA0x8eAS237A3nayL3ZrZTDjcEXvAxw91g',
    appId: '1:345080171965:web:1352873f511e4ba04f96d4',
    messagingSenderId: '345080171965',
    projectId: 'gyrohub',
    databaseURL: 'https://gyrohub-default-rtdb.firebaseio.com',
    storageBucket: 'gyrohub.firebasestorage.app',
  );
}