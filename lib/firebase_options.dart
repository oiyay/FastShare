import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    return const FirebaseOptions(
      apiKey: 'AIzaSyBElDSp2WxkrrF_yFKyqc8G5RxptbmBTok',
      appId: '1:656230834422:android:3c8f224a160f5472c08cd7',
      messagingSenderId: '656230834422',
      projectId: 'fastshare-525ad',
      databaseURL: 'https://fastshare-525ad-default-rtdb.asia-southeast1.firebasedatabase.app',
      storageBucket: 'fastshare-525ad.firebasestorage.app',
    );
  }
}
