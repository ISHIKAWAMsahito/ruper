import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/color_filters.dart';

/// カメラ制御、ズーム、LED、手鏡反転、フリーズキャプチャを担当する。
class CameraService extends ChangeNotifier {
  CameraService(this._prefs);

  final SharedPreferences _prefs;

  /// インカメラのプレビューを水平反転して鏡と同じ見え方にする。
  /// 端末によって既にプレビューが反転済みの場合は false にしてください。
  static const bool mirrorFrontPreview = true;

  static const _kFront = 'cam_is_front';
  static const _kZoom = 'cam_zoom';
  static const _kTorch = 'cam_torch';
  static const _kFilter = 'cam_filter';

  List<CameraDescription> _cameras = [];
  CameraController? _controller;
  bool _zoomBusy = false;
  double _pendingZoom = 1.0;

  /// _start / pause / dispose のたびに進める世代番号。
  /// 起動処理の途中で pause などが割り込んだ場合に、古い起動処理を破棄するために使う。
  int _startGen = 0;
  bool _disposed = false;

  /// pause() が呼ばれてから resume() されるまで true。
  /// 権限ダイアログ明けの resumed イベントなどで二重起動しないために使う。
  bool _paused = false;

  static const _initTimeout = Duration(seconds: 7);
  static const _hwCallTimeout = Duration(seconds: 3);
  static const _disposeTimeout = Duration(seconds: 3);

  bool isFront = false;
  bool torchOn = false;
  bool initialized = false;
  bool switching = false;
  double minZoom = 1.0;
  double maxZoom = 1.0;
  double zoom = 1.0;
  ViewFilter filter = ViewFilter.none;
  Uint8List? frozenImage;
  String? error;

  CameraController? get controller => _controller;
  bool get isFrozen => frozenImage != null;
  bool get canSwitch =>
      _cameras.any((c) => c.lensDirection == CameraLensDirection.front) &&
      _cameras.any((c) => c.lensDirection == CameraLensDirection.back);

  /// dispose 後に notifyListeners して例外にならないようにする。
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// 前回設定を復元してカメラを起動する。
  Future<void> initialize() async {
    if (_disposed) return;
    isFront = _prefs.getBool(_kFront) ?? false;
    zoom = _prefs.getDouble(_kZoom) ?? 1.0;
    torchOn = _prefs.getBool(_kTorch) ?? false;
    final fi = _prefs.getInt(_kFilter) ?? 0;
    filter = ViewFilter.values[fi.clamp(0, ViewFilter.values.length - 1)];
    error = null;
    _notify();
    try {
      _cameras = await availableCameras().timeout(_initTimeout);
    } on TimeoutException {
      error = 'カメラ一覧の取得がタイムアウトしました。再試行してください。';
      _notify();
      return;
    } on CameraException catch (e) {
      error = e.description ?? e.code;
      _notify();
      return;
    } catch (e) {
      error = '$e';
      _notify();
      return;
    }
    if (_disposed) return;
    if (_cameras.isEmpty) {
      error = 'カメラが見つかりません';
      _notify();
      return;
    }
    if (_paused) return; // 取得中にバックグラウンドへ移行した。resume() が起動する。
    await _start();
  }

  /// エラー表示からの再試行。
  Future<void> retry() async {
    if (_disposed) return;
    error = null;
    _notify();
    if (_cameras.isEmpty) {
      await initialize();
    } else {
      await _start();
    }
  }

  CameraDescription _pick() {
    final dir = isFront ? CameraLensDirection.front : CameraLensDirection.back;
    return _cameras.firstWhere(
      (c) => c.lensDirection == dir,
      orElse: () {
        isFront = _cameras.first.lensDirection == CameraLensDirection.front;
        return _cameras.first;
      },
    );
  }

  /// コントローラを安全に破棄する（ネイティブがハングしても待ち続けない・例外を握りつぶす）。
  Future<void> _safeDispose(CameraController? c) async {
    if (c == null) return;
    try {
      await c.dispose().timeout(_disposeTimeout);
    } catch (_) {
      // タイムアウト・破棄済みなどは無視
    }
  }

  /// ハードウェア依存の呼び出しを保護する。失敗・タイムアウト時は fallback を返す。
  Future<T> _guard<T>(Future<T> Function() call, T fallback) async {
    try {
      return await call().timeout(_hwCallTimeout);
    } catch (_) {
      return fallback;
    }
  }

  Future<void> _start() async {
    final gen = ++_startGen;
    final old = _controller;
    _controller = null;
    initialized = false;
    _notify();
    await _safeDispose(old);
    if (gen != _startGen || _disposed) return;

    final c = CameraController(
      _pick(),
      ResolutionPreset.veryHigh,
      enableAudio: false,
    );

    // --- 1. カメラ本体の初期化（ここだけは失敗したらエラー扱い） ---
    String? failure;
    try {
      await c.initialize().timeout(_initTimeout);
    } on TimeoutException {
      failure = 'カメラの初期化がタイムアウトしました。再起動をお試しください。';
    } on CameraException catch (e) {
      failure = e.description ?? e.code;
    } catch (e) {
      failure = '$e';
    }
    if (failure != null) {
      await _safeDispose(c);
      if (gen == _startGen && !_disposed) {
        error = failure;
        _notify();
      }
      return;
    }
    if (gen != _startGen || _disposed) {
      await _safeDispose(c);
      return;
    }

    // --- 2. 初期化できたら直ちにUIへ通知（最優先） ---
    // ズーム・フラッシュの設定結果を待たずにプレビューとUIを描画させる。
    _controller = c;
    initialized = true;
    error = null;
    _notify();

    // --- 3. 付加機能の設定は通知後に非同期で適用（失敗してもプレビューは継続） ---
    unawaited(_applyCameraSettingsAfterInit(c, gen));
  }

  /// ズーム範囲の取得・ズーム設定・フォーカス・トーチ設定を個別に保護して適用する。
  /// いずれが失敗・無応答でもプレビュー表示には影響しない。
  Future<void> _applyCameraSettingsAfterInit(
    CameraController c,
    int gen,
  ) async {
    bool stale() => gen != _startGen || _disposed;

    // ズーム範囲
    final minZ = await _guard(() => c.getMinZoomLevel(), 1.0);
    if (stale()) return;
    final maxZ = await _guard(() => c.getMaxZoomLevel(), 1.0);
    if (stale()) return;
    minZoom = minZ;
    maxZoom = maxZ < minZ ? minZ : maxZ;
    zoom = zoom.clamp(minZoom, maxZoom).toDouble();
    _notify();

    // ズーム設定
    final zoomOk = await _guard(() async {
      await c.setZoomLevel(zoom);
      return true;
    }, false);
    if (stale()) return;
    if (!zoomOk) {
      zoom = minZoom;
      _notify();
    }

    // フォーカス
    await _guard(() async {
      await c.setFocusMode(FocusMode.auto);
      return true;
    }, false);
    if (stale()) return;

    // トーチ（インカメラでは使用しない）
    if (isFront) {
      torchOn = false;
    }
    final flashOk = await _guard(() async {
      await c.setFlashMode(torchOn ? FlashMode.torch : FlashMode.off);
      return true;
    }, false);
    if (stale()) return;
    if (!flashOk) {
      torchOn = false;
    }
    _notify();
  }

  /// ズーム倍率を設定する（連続呼び出しは最新値のみ反映）。
  Future<void> setZoom(double value) async {
    final c = _controller;
    if (c == null || !initialized || isFrozen) return;
    zoom = value.clamp(minZoom, maxZoom).toDouble();
    _pendingZoom = zoom;
    _notify();
    if (_zoomBusy) return;
    _zoomBusy = true;
    try {
      double applied = -1;
      while (applied != _pendingZoom) {
        applied = _pendingZoom;
        await c.setZoomLevel(applied);
      }
    } catch (_) {
      // ズーム中のコントローラ破棄などは無視
    } finally {
      _zoomBusy = false;
    }
  }

  /// アウトカメラのLEDトーチを切り替える。
  Future<void> toggleTorch() async {
    final c = _controller;
    if (c == null || !initialized || isFront) return;
    final next = !torchOn;
    try {
      await c.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      torchOn = next;
      await _prefs.setBool(_kTorch, torchOn);
    } catch (_) {
      torchOn = false;
    }
    _notify();
  }

  /// イン/アウトカメラを切り替える。
  Future<void> switchCamera() async {
    if (switching || !canSwitch) return;
    switching = true;
    try {
      frozenImage = null;
      isFront = !isFront;
      torchOn = false;
      await _prefs.setBool(_kFront, isFront);
      await _start();
    } finally {
      switching = false;
      _notify();
    }
  }

  /// 高解像度の静止画をメモリ上に保持してフリーズする。
  Future<void> freeze() async {
    final c = _controller;
    if (c == null || !initialized || isFrozen) return;
    try {
      final file = await c.takePicture();
      frozenImage = await file.readAsBytes();
      try {
        await c.pausePreview();
      } catch (_) {}
    } on CameraException catch (e) {
      error = e.description ?? e.code;
    } catch (e) {
      error = '$e';
    }
    _notify();
  }

  /// フリーズを解除してライブ表示に戻る。
  Future<void> unfreeze() async {
    final c = _controller;
    frozenImage = null;
    try {
      await c?.resumePreview();
    } catch (_) {}
    _notify();
  }

  void cycleFilter() {
    filter = ViewFilter.values[(filter.index + 1) % ViewFilter.values.length];
    _prefs.setInt(_kFilter, filter.index);
    _notify();
  }

  Future<void> persistZoom() => _prefs.setDouble(_kZoom, zoom);

  /// アプリがバックグラウンドに入るときにカメラを解放する。
  Future<void> pause() async {
    _paused = true;
    _startGen++; // 起動途中の処理があれば無効化する
    final old = _controller;
    _controller = null;
    initialized = false;
    _notify();
    await _safeDispose(old);
  }

  /// フォアグラウンド復帰時にカメラを再開する。
  /// pause() されていない場合（権限ダイアログ明けの resumed など）は何もしない。
  Future<void> resume() async {
    if (!_paused) return;
    _paused = false;
    if (_cameras.isEmpty || _controller != null) return;
    await _start();
  }

  @override
  void dispose() {
    _disposed = true;
    _startGen++;
    final c = _controller;
    _controller = null;
    if (c != null) unawaited(_safeDispose(c));
    super.dispose();
  }
}
