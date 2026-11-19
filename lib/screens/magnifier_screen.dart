import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_shaders/flutter_shaders.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/camera_service.dart';
import '../services/iap_service.dart';
import '../utils/color_filters.dart';
import '../widgets/ring_light_frame.dart';
import '../widgets/visibility_filter_layer.dart';

/// AdMob バナーのテスト用広告ユニットID（Android）。リリース前に本番IDへ差し替えてください。
const String _kBannerAdUnitId = 'ca-app-pub-3940256099942544/6300978111';

/// ライブ中にフィルターボタンを押したときの案内文。
const String _kFilterFrozenOnlyMessage = 'フィルターは画面静止時のみ利用できます';

class MagnifierScreen extends StatefulWidget {
  const MagnifierScreen({super.key, required this.camera, required this.iap});

  final CameraService camera;
  final IapService iap;

  @override
  State<MagnifierScreen> createState() => _MagnifierScreenState();
}

class _MagnifierScreenState extends State<MagnifierScreen>
    with WidgetsBindingObserver {
  PermissionStatus? _permission;
  double _baseZoom = 1.0;

  /// アプリ全体としての最大ズーム倍率。カメラの上限を超えた分はデジタル拡大で補う。
  static const double _kMaxTotalZoom = 10.0;

  /// カメラ上限を超えた分のデジタル拡大率（1.0 = なし）。
  double _digital = 1.0;

  /// バナーが表示されている間だけ true。
  final ValueNotifier<bool> _bannerVisible = ValueNotifier<bool>(false);

  CameraService get cam => widget.camera;
  IapService get iap => widget.iap;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ShaderBuilder.precacheShader(ViewColorFilters.sharpenShaderAsset);
    // 第1フレーム描画後に権限確認・カメラ起動を行う（スプラッシュ裏でのブロック回避）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  bool _booting = false;

  Future<void> _boot() async {
    if (!mounted || _booting) return;
    _booting = true;
    try {
      await _bootInner();
    } finally {
      _booting = false;
    }
  }

  /// 要求ダイアログを出さずに状態だけ確認し、許可されていれば起動する。
  Future<void> _recheckPermission() async {
    try {
      final status = await Permission.camera.status;
      if (status.isGranted) await _boot();
    } catch (_) {}
  }

  Future<void> _bootInner() async {
    PermissionStatus status;
    try {
      status = await Permission.camera.status;
      if (!status.isGranted) {
        status = await Permission.camera.request();
      }
    } catch (_) {
      status = PermissionStatus.denied;
    }
    if (!mounted) return;
    setState(() => _permission = status);
    if (status.isGranted) {
      await cam.initialize();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_permission != null && !_permission!.isGranted) {
      // 設定アプリで許可された場合に備えて、復帰時に権限を再確認する。
      if (state == AppLifecycleState.resumed) _recheckPermission();
      return;
    }
    if (_permission?.isGranted != true) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      cam.pause();
    } else if (state == AppLifecycleState.resumed) {
      cam.resume();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    cam.dispose();
    _bannerVisible.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // 最上部に黒背景バナー広告を配置
            _TopBannerAd(
              iap: iap,
              onVisibleChanged: (_) {},
            ),
            Expanded(
              child: _buildMain(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMain() {
    if (_permission == null) {
      return const _LoadingIndicator();
    }
    if (!_permission!.isGranted) {
      return _PermissionDenied(
        permanentlyDenied: _permission!.isPermanentlyDenied,
        onRetry: _boot,
      );
    }
    return ListenableBuilder(
      listenable: cam,
      builder: (context, _) {
        final c = cam.controller;
        if (cam.error != null && c == null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline,
                      size: 56, color: Colors.white54),
                  const SizedBox(height: 16),
                  Text(
                    'カメラを起動できません\n${cam.error}',
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: cam.retry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('再試行'),
                  ),
                ],
              ),
            ),
          );
        }
        // カメラ初期化中（権限許可済み・未初期化・エラーなし）は
        // 画面中央にインジケータを表示する。
        return Stack(
          fit: StackFit.expand,
          children: [
            _buildViewer(c),
            if (!cam.initialized && cam.error == null) const _LoadingIndicator(),
            if (cam.isFront) const RingLightFrame(),
            _buildTopBar(),
            if (!cam.isFrozen && cam.initialized) _buildZoomSlider(),
            _buildBottomBar(),
          ],
        );
      },
    );
  }

  // ---------------- ビューア ----------------
  Widget _buildViewer(CameraController? c) {
    Widget content;
    if (cam.isFrozen) {
      // フリーズ時点のデジタル拡大率を初期拡大として引き継ぐ。
      content = _FrozenViewer(
        initialScale: _activeDigital,
        child: SizedBox.expand(
          child: _mirrorIfNeeded(
            Image.memory(
              cam.frozenImage!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              filterQuality: FilterQuality.high,
            ),
          ),
        ),
      );
    } else if (c != null && cam.initialized && c.value.isInitialized) {
      final size = c.value.previewSize!;
      content = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: (_) => _baseZoom = _totalZoom,
        onScaleUpdate: (d) {
          if (d.pointerCount >= 2) _setZoom(_baseZoom * d.scale);
        },
        onScaleEnd: (_) => cam.persistZoom(),
        child: SizedBox.expand(
          // カメラ上限を超えた分は Transform.scale でデジタル拡大する。
          child: ClipRect(
            child: Transform.scale(
              scale: _activeDigital,
              child: _mirrorIfNeeded(
                ClipRect(
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: size.height,
                      height: size.width,
                      child: CameraPreview(c),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    } else {
      return const SizedBox.expand(child: ColoredBox(color: Colors.black));
    }
    return VisibilityFilterLayer(
      filter: cam.isFrozen ? cam.filter : ViewFilter.none,
      child: content,
    );
  }

  Widget _mirrorIfNeeded(Widget child) {
    if (cam.isFront && CameraService.mirrorFrontPreview) {
      return Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(-1.0, 1.0, 1.0),
        child: child,
      );
    }
    return child;
  }

  // ---------------- 上部バー ----------------
  Widget _buildTopBar() {
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              _RoundButton(
                icon: cam.torchOn ? Icons.flashlight_on : Icons.flashlight_off,
                active: cam.torchOn,
                enabled: !cam.isFront && !cam.isFrozen,
                tooltip: 'ライト',
                onPressed: cam.toggleTorch,
              ),
              const Spacer(),
              _ZoomBadge(zoom: _totalZoom),
              if (cam.isFrozen && cam.filter != ViewFilter.none) ...[
                const SizedBox(width: 8),
                _FilterBadge(filter: cam.filter),
              ],
              const Spacer(),
              ListenableBuilder(
                listenable: iap,
                builder: (_, __) => iap.adsRemoved
                    ? const SizedBox(width: 48)
                    : _RoundButton(
                        icon: Icons.block,
                        tooltip: '広告を非表示',
                        onPressed: _showRemoveAdsDialog,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------- ズーム共通処理 ----------------
  /// ズームボタン1回あたりの変化量（倍率）。
  static const double _kZoomStep = 0.5;

  /// プリセット倍率。
  static const List<double> _kZoomPresets = [1.0, 2.0, 5.0, 10.0];

  /// 縦ズームバーの、スライダー以外の領域＋下部操作（プリセット/シャッター）と
  /// 重ならないための余白。画面が低いときスライダー長をこの分だけ縮める。
  static const double _kZoomBarReserve = 440.0;

  /// カメラ（ハードウェア）側に設定できる上限。
  double get _hwCap => math.min(cam.maxZoom, _kMaxTotalZoom);

  /// 実際に効いているデジタル拡大率。ハードウェアズームが上限に達していない
  /// とき（カメラ切替・復帰など）は 1.0 に自己修復する。
  double get _activeDigital =>
      (_digital > 1.0 && cam.zoom >= _hwCap - 0.001) ? _digital : 1.0;

  /// ユーザーに見せる総合倍率（ハードウェア × デジタル）。
  double get _totalZoom => (cam.zoom * _activeDigital)
      .clamp(cam.minZoom, _kMaxTotalZoom)
      .toDouble();

  /// ピンチ・スライダー・＋/−・プリセットすべてがここを通る。
  /// [value] は総合倍率。上限までをカメラ、超過分をデジタル拡大に振り分ける。
  void _setZoom(double value) {
    final total = value.clamp(cam.minZoom, _kMaxTotalZoom).toDouble();
    final hw = _hwCap;
    final hwZoom = total.clamp(cam.minZoom, math.max(cam.minZoom, hw)).toDouble();
    final digital = total > hw + 0.001 ? total / hw : 1.0;
    if (cam.maxZoom > cam.minZoom && (cam.zoom - hwZoom).abs() > 0.0001) {
      cam.setZoom(hwZoom);
    }
    if ((digital - _digital).abs() > 0.0001) {
      setState(() => _digital = digital);
    }
  }

  /// ボタン操作（＋/−・プリセット）用。値を設定して保存まで行う。
  /// 保存されるのはカメラ側のズームのみ（デジタル拡大分は再起動で戻る）。
  void _setZoomAndPersist(double value) {
    _setZoom(value);
    cam.persistZoom();
  }

  /// ＋/−ボタン用。1タップで [delta] だけ変更する。
  void _stepZoom(double delta) => _setZoomAndPersist(_totalZoom + delta);

  /// プリセットが実際に設定される倍率（minZoom〜最大に clamp）。
  double _presetTarget(double preset) =>
      preset.clamp(cam.minZoom, _kMaxTotalZoom).toDouble();

  Widget _buildZoomPresets() {
    final total = _totalZoom;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final p in _kZoomPresets)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: _ZoomPresetButton(
              label: '${p.toStringAsFixed(0)}x',
              selected: (total - _presetTarget(p)).abs() < 0.05,
              onPressed: () => _setZoomAndPersist(p),
            ),
          ),
      ],
    );
  }

  // ---------------- 縦スライダー ----------------
  Widget _buildZoomSlider() {
    final total = _totalZoom;
    final canZoomIn = total < _kMaxTotalZoom - 0.001;
    final canZoomOut = total > cam.minZoom + 0.001;
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final sliderLength = (constraints.maxHeight - _kZoomBarReserve)
              .clamp(120.0, 240.0)
              .toDouble();
          return Align(
            alignment: Alignment.centerRight,
            child: Container(
              margin: const EdgeInsets.only(right: 6),
              // リップルが見えるよう、背景は Material で描く。
              child: Material(
                color: Colors.black38,
                borderRadius: BorderRadius.circular(24),
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.add),
                        color: Colors.white,
                        disabledColor: Colors.white24,
                        iconSize: 24,
                        tooltip: '拡大',
                        onPressed:
                            canZoomIn ? () => _stepZoom(_kZoomStep) : null,
                      ),
                      SizedBox(
                        height: sliderLength,
                        width: 44,
                        child: RotatedBox(
                          quarterTurns: 3,
                          child: SizedBox(
                            width: sliderLength,
                            child: Slider(
                              value: total,
                              min: cam.minZoom,
                              max: _kMaxTotalZoom,
                              onChanged: _setZoom,
                              onChangeEnd: (_) => cam.persistZoom(),
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.remove),
                        color: Colors.white,
                        disabledColor: Colors.white24,
                        iconSize: 24,
                        tooltip: '縮小',
                        onPressed:
                            canZoomOut ? () => _stepZoom(-_kZoomStep) : null,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------------- 下部バー ----------------
  Widget _buildBottomBar() {
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ズームプリセットはライブ中のみ（ズームスライダーと同じ条件）。
              if (!cam.isFrozen && cam.initialized) ...[
                _buildZoomPresets(),
                const SizedBox(height: 16),
              ],
              Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _RoundButton(
                icon: Icons.cameraswitch,
                size: 56,
                enabled: cam.canSwitch && !cam.switching,
                tooltip: 'インカメラ/アウトカメラ',
                onPressed: cam.switchCamera,
              ),
              _ShutterButton(
                frozen: cam.isFrozen,
                enabled: cam.initialized,
                onPressed: cam.isFrozen ? cam.unfreeze : cam.freeze,
              ),
              // フィルターは静止中のみ有効。ライブ中はグレーアウトし、
              // タップすると案内を表示する。
              _RoundButton(
                icon: cam.filter.icon,
                size: 56,
                active: cam.isFrozen && cam.filter != ViewFilter.none,
                enabled: cam.isFrozen,
                tooltip: cam.isFrozen
                    ? '視認性フィルター（${cam.filter.label}）'
                    : _kFilterFrozenOnlyMessage,
                onPressed: _cycleFilter,
                onDisabledTap: _showFilterFrozenOnlyHint,
              ),
            ],
          ),
            ],
          ),
        ),
      ),
    );
  }

  void _showFilterFrozenOnlyHint() {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(
          content: Text(_kFilterFrozenOnlyMessage),
          duration: Duration(milliseconds: 1800),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  void _cycleFilter() {
    if (!cam.isFrozen) {
      _showFilterFrozenOnlyHint();
      return;
    }
    cam.cycleFilter();
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(cam.filter.label),
          duration: const Duration(milliseconds: 900),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  // ---------------- 広告非表示ダイアログ ----------------
  void _showRemoveAdsDialog() {
    void closeIfRemoved() {
      if (iap.adsRemoved && mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    }

    iap.message = null;
    iap.addListener(closeIfRemoved);
    showDialog<void>(
      context: context,
      builder: (ctx) => ListenableBuilder(
        listenable: iap,
        builder: (_, __) {
          final price = iap.product?.price;
          final String body;
          if (iap.adsRemoved) {
            body = '広告は非表示になっています。';
          } else if (iap.storeAvailable && iap.product != null) {
            body = '買い切り $price で、画面上部のバナー広告がすべて非表示になります。';
          } else {
            body = '現在ストアに接続できません。時間をおいてお試しください。';
          }
          final msg = iap.message;
          return AlertDialog(
            title: const Text('広告を非表示にする'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(body),
                if (msg != null && !iap.adsRemoved) ...[
                  const SizedBox(height: 12),
                  Text(
                    msg,
                    style: const TextStyle(color: Colors.amber, fontSize: 13),
                  ),
                ],
              ],
            ),
            actions: [
              if (!iap.adsRemoved)
                TextButton(
                  onPressed: iap.purchasing ? null : iap.restore,
                  child: const Text('購入を復元'),
                ),
              if (!iap.adsRemoved)
                FilledButton(
                  onPressed: iap.product != null && !iap.purchasing
                      ? iap.buy
                      : null,
                  child: Text(iap.purchasing ? '処理中…' : '購入する'),
                ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('閉じる'),
              ),
            ],
          );
        },
      ),
    ).whenComplete(() => iap.removeListener(closeIfRemoved));
  }
}

// =============================================================================
// 最上部バナー広告（アダプティブ）
// =============================================================================

class _TopBannerAd extends StatefulWidget {
  const _TopBannerAd({required this.iap, required this.onVisibleChanged});

  final IapService iap;
  final ValueChanged<bool> onVisibleChanged;

  @override
  State<_TopBannerAd> createState() => _TopBannerAdState();
}

class _TopBannerAdState extends State<_TopBannerAd> {
  static const Duration _retryDelay = Duration(seconds: 60);

  BannerAd? _ad;
  bool _loaded = false;
  bool _loading = false;
  Timer? _retryTimer;

  IapService get _iap => widget.iap;

  @override
  void initState() {
    super.initState();
    _iap.addListener(_onIapChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeLoad();
  }

  void _onIapChanged() {
    if (!mounted) return;
    if (_iap.adsRemoved) {
      _removeAd();
    }
  }

  void _removeAd() {
    _retryTimer?.cancel();
    final old = _ad;
    final wasVisible = _loaded;
    _ad = null;
    _loaded = false;
    if (wasVisible) {
      widget.onVisibleChanged(false);
    }
    setState(() {});
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  Future<void> _maybeLoad() async {
    if (_iap.adsRemoved || _ad != null || _loading) return;
    _loading = true;
    try {
      final width = MediaQuery.sizeOf(context).width.truncate();
      final size = await AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(
        width,
      );
      if (!mounted || _iap.adsRemoved || size == null) {
        _loading = false;
        return;
      }
      // MobileAds の初期化は main.dart 側（unawaited）で実施済みのため、ここでは待たない。
      final ad = BannerAd(
        adUnitId: _kBannerAdUnitId,
        size: size,
        request: const AdRequest(),
        listener: BannerAdListener(
          onAdLoaded: (loadedAd) {
            _loading = false;
            if (!mounted || _iap.adsRemoved) {
              loadedAd.dispose();
              return;
            }
            setState(() => _loaded = true);
            widget.onVisibleChanged(true);
          },
          onAdFailedToLoad: (failedAd, error) {
            failedAd.dispose();
            _loading = false;
            if (!mounted) return;
            if (identical(_ad, failedAd)) {
              _ad = null;
            }
            _loaded = false;
            widget.onVisibleChanged(false);
            setState(() {});
            _scheduleRetry();
          },
        ),
      );
      _ad = ad;
      await ad.load();
    } catch (_) {
      _loading = false;
      _ad?.dispose();
      _ad = null;
      if (mounted) {
        _loaded = false;
        widget.onVisibleChanged(false);
        _scheduleRetry();
      }
    }
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    _retryTimer = Timer(_retryDelay, () {
      if (mounted) _maybeLoad();
    });
  }

  @override
  void dispose() {
    _iap.removeListener(_onIapChanged);
    _retryTimer?.cancel();
    _ad?.dispose();
    _ad = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    if (_iap.adsRemoved || !_loaded || ad == null) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      color: Colors.black,
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      alignment: Alignment.center,
      child: SizedBox(
        width: ad.size.width.toDouble(),
        height: ad.size.height.toDouble(),
        child: AdWidget(ad: ad),
      ),
    );
  }
}

// =============================================================================
// 部品ウィジェット
// =============================================================================

class _LoadingIndicator extends StatelessWidget {
  const _LoadingIndicator();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: CircularProgressIndicator(color: Colors.amber),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.onPressed,
    this.active = false,
    this.enabled = true,
    this.size = 48,
    this.tooltip,
    this.onDisabledTap,
  });

  final IconData icon;
  final VoidCallback onPressed;

  /// 非活性（グレーアウト）中にタップされたときの処理（案内表示用）。
  final VoidCallback? onDisabledTap;
  final bool active;
  final bool enabled;
  final double size;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.35,
      child: Material(
        color: active ? Colors.amber : Colors.black54,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onPressed : onDisabledTap,
          child: SizedBox(
            width: size,
            height: size,
            child: Tooltip(
              message: tooltip ?? '',
              child: Icon(
                icon,
                color: active ? Colors.black : Colors.white,
                size: size * 0.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// ズームプリセット（1x/2x/4x）用の小さなピルボタン。
class _ZoomPresetButton extends StatelessWidget {
  const _ZoomPresetButton({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: 'ズーム $label',
      child: Material(
        color: selected ? Colors.amber : Colors.black54,
        shape: StadiumBorder(
          side: BorderSide(
            color: selected ? Colors.amber : Colors.white38,
            width: 1.5,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            width: 56,
            height: 44,
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? Colors.black : Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 静止画ビューア。フリーズ時点のデジタル拡大率を初期拡大として引き継ぎ、
/// 以降はピンチ/ドラッグで最大10倍まで観察できる。
/// ライブ→静止の切替で毎回作り直されるため、状態は静止ごとに初期化される。
class _FrozenViewer extends StatefulWidget {
  const _FrozenViewer({required this.initialScale, required this.child});

  final double initialScale;
  final Widget child;

  @override
  State<_FrozenViewer> createState() => _FrozenViewerState();
}

class _FrozenViewerState extends State<_FrozenViewer> {
  final TransformationController _ctrl = TransformationController();
  bool _initialized = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        if (!_initialized) {
          _initialized = true;
          final sc = widget.initialScale;
          if (sc > 1.0 && c.hasBoundedWidth && c.hasBoundedHeight) {
            // 画面中心を基準に sc 倍。
            _ctrl.value = Matrix4.diagonal3Values(sc, sc, 1.0)
              ..setTranslationRaw(
                c.maxWidth * (1 - sc) / 2,
                c.maxHeight * (1 - sc) / 2,
                0.0,
              );
          }
        }
        return InteractiveViewer(
          transformationController: _ctrl,
          minScale: 1.0,
          maxScale: 10.0,
          child: widget.child,
        );
      },
    );
  }
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({
    required this.frozen,
    required this.enabled,
    required this.onPressed,
  });

  final bool frozen;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.4,
      child: Tooltip(
        message: frozen ? '静止を解除' : '画面を静止',
        child: GestureDetector(
        onTap: enabled ? onPressed : null,
        child: Container(
          width: 76,
          height: 76,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 4),
            color: Colors.black38,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: frozen ? Colors.amber : Colors.white,
            ),
            child: Icon(
              // ライブ中: 画面を撮り止めるカメラアイコン / 静止中: 固定中を示す鍵（タップで解除）
              frozen ? Icons.lock : Icons.camera,
              color: Colors.black87,
              size: 32,
            ),
          ),
        ),
        ),
      ),
    );
  }
}

class _FilterBadge extends StatelessWidget {
  const _FilterBadge({required this.filter});

  final ViewFilter filter;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.amber.shade700,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(filter.icon, size: 16, color: Colors.black),
          const SizedBox(width: 4),
          Text(
            filter.shortLabel,
            style: const TextStyle(
              color: Colors.black,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _ZoomBadge extends StatelessWidget {
  const _ZoomBadge({required this.zoom});

  final double zoom;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '${zoom.toStringAsFixed(1)}x',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _PermissionDenied extends StatelessWidget {
  const _PermissionDenied({
    required this.permanentlyDenied,
    required this.onRetry,
  });

  final bool permanentlyDenied;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography, size: 64, color: Colors.white54),
            const SizedBox(height: 16),
            const Text(
              'ルーペとして使うには\nカメラの許可が必要です',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 18),
            ),
            const SizedBox(height: 8),
            const Text(
              '映像は端末内だけで処理され、外部に送信されません。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white60, fontSize: 13),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: permanentlyDenied ? openAppSettings : onRetry,
              child: Text(permanentlyDenied ? '設定を開く' : '許可する'),
            ),
          ],
        ),
      ),
    );
  }
}