import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/magnifier_screen.dart';
import 'services/camera_service.dart';
import 'services/iap_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);

  final prefs = await SharedPreferences.getInstance();
  final iap = IapService(prefs);

  // 起動を遅らせないため、広告SDKとIAPの初期化は待たずに並行実行する。
  // 買い切り済みなら AdMob 自体を初期化しない（バナーは読み込まない。全画面広告はそもそも使用しない）。
  if (!iap.adsRemoved) {
    // unawaited(MobileAds.instance.initialize());
  }
  unawaited(iap.init());
  final camera = CameraService(prefs);

  runApp(MagnifierApp(camera: camera, iap: iap));
}

class MagnifierApp extends StatelessWidget {
  const MagnifierApp({super.key, required this.camera, required this.iap});

  final CameraService camera;
  final IapService iap;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ルーペ＆手鏡',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: Colors.black,
      ),
      home: MagnifierScreen(camera: camera, iap: iap),
    );
  }
}
