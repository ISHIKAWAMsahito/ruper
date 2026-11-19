import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 買い切り「広告非表示」IAP。購入状態は SharedPreferences に保存する。
class IapService extends ChangeNotifier {
  IapService(this._prefs) {
    _adsRemoved = _prefs.getBool(_kAdsRemoved) ?? false;
  }

  /// Play Console / App Store Connect に登録する商品ID（管理対象・非消耗型）
  static const String productId = 'remove_ads';
  static const String _kAdsRemoved = 'ads_removed';

  /// 復元結果がストアから返らない場合に処理中表示を解除するまでの時間
  static const Duration _restoreTimeout = Duration(seconds: 8);

  final SharedPreferences _prefs;
  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;
  Timer? _restoreTimer;

  bool _adsRemoved = false;
  bool _restoreInFlight = false;
  bool _disposed = false;
  bool storeAvailable = false;
  bool purchasing = false;
  ProductDetails? product;
  String? message;

  bool get adsRemoved => _adsRemoved;

  Future<void> init() async {
    _sub ??= _iap.purchaseStream.listen(
      _onPurchases,
      onError: (Object e) {
        purchasing = false;
        _restoreInFlight = false;
        _restoreTimer?.cancel();
        message = '購入処理でエラーが発生しました';
        _notify();
      },
    );
    try {
      storeAvailable = await _iap.isAvailable();
      if (!storeAvailable) {
        _notify();
        return;
      }
      final res = await _iap.queryProductDetails({productId});
      if (res.productDetails.isNotEmpty) {
        product = res.productDetails.first;
      }
    } catch (_) {
      storeAvailable = false;
    }
    _notify();
  }

  Future<void> buy() async {
    final p = product;
    if (p == null || purchasing || _adsRemoved) return;
    purchasing = true;
    message = null;
    _notify();
    try {
      await _iap.buyNonConsumable(
        purchaseParam: PurchaseParam(productDetails: p),
      );
    } catch (_) {
      purchasing = false;
      message = '購入を開始できませんでした';
      _notify();
    }
  }

  Future<void> restore() async {
    if (purchasing) return;
    purchasing = true;
    _restoreInFlight = true;
    message = null;
    _notify();
    try {
      await _iap.restorePurchases();
      // ストアから何も返らなかった場合に「処理中…」のまま固まらないようにする。
      _restoreTimer?.cancel();
      _restoreTimer = Timer(_restoreTimeout, () {
        if (_disposed || !_restoreInFlight) return;
        purchasing = false;
        _restoreInFlight = false;
        if (!_adsRemoved) {
          message = '復元できる購入がありませんでした';
        }
        _notify();
      });
    } catch (_) {
      purchasing = false;
      _restoreInFlight = false;
      message = '復元に失敗しました';
      _notify();
    }
  }

  Future<void> _onPurchases(List<PurchaseDetails> list) async {
    var handled = false;
    for (final p in list) {
      if (p.productID != productId) continue;
      handled = true;
      switch (p.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          // バナーを即座に dispose / 非表示にするため、完了処理より先に永続化して通知する。
          await _setAdsRemoved(true);
          purchasing = false;
          _restoreInFlight = false;
          _restoreTimer?.cancel();
          message = '広告を非表示にしました。ありがとうございます！';
          break;
        case PurchaseStatus.error:
          purchasing = false;
          _restoreInFlight = false;
          _restoreTimer?.cancel();
          message = '購入に失敗しました';
          break;
        case PurchaseStatus.canceled:
          purchasing = false;
          _restoreInFlight = false;
          _restoreTimer?.cancel();
          break;
        case PurchaseStatus.pending:
          purchasing = true;
          break;
      }
      if (p.pendingCompletePurchase) {
        await _iap.completePurchase(p);
      }
    }
    if (!handled && _restoreInFlight) {
      purchasing = false;
      _restoreInFlight = false;
      _restoreTimer?.cancel();
      if (!_adsRemoved) {
        message = '復元できる購入がありませんでした';
      }
    }
    _notify();
  }

  Future<void> _setAdsRemoved(bool v) async {
    _adsRemoved = v;
    await _prefs.setBool(_kAdsRemoved, v);
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _restoreTimer?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}
