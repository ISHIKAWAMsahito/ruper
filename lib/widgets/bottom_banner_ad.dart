import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../services/iap_service.dart';

// ---------------------------------------------------------------------------
// AdMob 設定：リリース前に kUseTestAds を false にし、本番ユニットIDへ差し替える。
// （AndroidManifest.xml の APPLICATION_ID も本番IDへ変更すること）
// ---------------------------------------------------------------------------
const bool kUseTestAds = true;
const String _kTestBannerAndroid = 'ca-app-pub-3940256099942544/6300978713';
const String _kTestBannerIos = 'ca-app-pub-3940256099942544/2934735716';
const String _kProdBannerAndroid = 'ca-app-pub-XXXXXXXXXXXXXXXX/YYYYYYYYYY';
const String _kProdBannerIos = 'ca-app-pub-XXXXXXXXXXXXXXXX/ZZZZZZZZZZ';

String get _bannerUnitId {
  if (Platform.isIOS) return kUseTestAds ? _kTestBannerIos : _kProdBannerIos;
  return kUseTestAds ? _kTestBannerAndroid : _kProdBannerAndroid;
}

/// 画面最下部にのみ常駐するバナー広告。
///
/// - 全画面広告（インタースティシャル / リワード）は読み込まない。
/// - 読み込み完了までは [SizedBox.shrink]（高さ0）でレイアウトシフトを防ぐ。
/// - 広告非表示の購入／復元が成立した瞬間に [BannerAd.dispose] し、枠を消す。
class BottomBannerAd extends StatefulWidget {
  const BottomBannerAd({super.key, required this.iap});

  final IapService iap;

  @override
  State<BottomBannerAd> createState() => _BottomBannerAdState();
}

class _BottomBannerAdState extends State<BottomBannerAd> {
  BannerAd? _ad;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    widget.iap.addListener(_onIapChanged);
    _loadIfAllowed();
  }

  @override
  void didUpdateWidget(covariant BottomBannerAd oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.iap != widget.iap) {
      oldWidget.iap.removeListener(_onIapChanged);
      widget.iap.addListener(_onIapChanged);
      _onIapChanged();
    }
  }

  @override
  void dispose() {
    widget.iap.removeListener(_onIapChanged);
    _disposeAd();
    super.dispose();
  }

  void _onIapChanged() {
    if (widget.iap.adsRemoved) {
      _disposeAd();
      if (mounted) setState(() {});
      return;
    }
    _loadIfAllowed();
  }

  void _loadIfAllowed() {
    if (widget.iap.adsRemoved || _ad != null) return;
    _ad = BannerAd(
      adUnitId: _bannerUnitId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) {
          if (!mounted || widget.iap.adsRemoved) {
            _disposeAd();
            return;
          }
          setState(() => _loaded = true);
        },
        onAdFailedToLoad: (ad, _) {
          ad.dispose();
          if (_ad == ad) {
            _ad = null;
            _loaded = false;
          }
          if (mounted) setState(() {});
        },
      ),
    )..load();
  }

  void _disposeAd() {
    _loaded = false;
    final ad = _ad;
    _ad = null;
    ad?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    if (widget.iap.adsRemoved || ad == null || !_loaded) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      width: ad.size.width.toDouble(),
      height: ad.size.height.toDouble(),
      child: AdWidget(ad: ad),
    );
  }
}
