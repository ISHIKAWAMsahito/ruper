# ルーペ＆手鏡 MVP

広告に邪魔されない高画質ルーペ＆手鏡アプリ（Flutter / Android）。

## 1. 環境構築

1. Flutter SDK（3.22 以上推奨 / Dart 3.3 以上）をインストールし `flutter doctor` が通ることを確認
2. このZIPを展開したフォルダで、Flutterの雛形を補完します（`lib/` と `pubspec.yaml` は上書きされません）。
   ```bash
   cd magnifier_mvp
   flutter create . --org com.example --project-name magnifier_mvp --platforms=android
   ```
3. `flutter create` が生成する `android/app/src/main/AndroidManifest.xml` を、
   同梱の `AndroidManifest.xml` で**上書き**します（ZIPを展開し直すか、手動でコピー）。
   ※ `flutter create` 実行前に同梱版を退避し、実行後に戻してください。
4. `android/app/build.gradle(.kts)` で次を設定します。
   - `minSdk = 21` 以上（`camera` / `google_mobile_ads` の要件。`flutter.minSdkVersion` が 21 未満の場合のみ変更）
   - `applicationId` を自分のパッケージ名に変更
5. 依存パッケージを取得して実機で実行します（カメラは実機推奨）。
   ```bash
   flutter pub get
   flutter run
   ```

## 2. AdMob テストIDの切り替え箇所

現状はGoogle公式の**テストID**です。公開前に必ず本番IDへ差し替えてください（テストID以外で開発中に自分の広告をタップすると規約違反になります）。

| 箇所 | 内容 |
|---|---|
| `android/app/src/main/AndroidManifest.xml` | `com.google.android.gms.ads.APPLICATION_ID`（`ca-app-pub-3940256099942544~3347511713` → 本番アプリID） |
| `lib/screens/magnifier_screen.dart` 冒頭 | `kUseTestAds` を `false` に変更 |
| `lib/screens/magnifier_screen.dart` 冒頭 | `_kProdBannerAndroid`（`_kProdBannerIos`）を本番バナー広告ユニットIDへ置き換え |

## 3. アプリ内課金（広告非表示）の設定

1. Google Play Console で本アプリを作成し、**管理対象アイテム（アプリ内商品）** を登録します。
   - 商品ID：`remove_ads`（`lib/services/iap_service.dart` の `productId`）
2. 内部テスト版をアップロードし、ライセンステスターに自分のアカウントを追加して購入フローを検証します。
3. 購入状態は `shared_preferences` の `ads_removed` に保存され、起動のたびに「購入を復元」で再取得できます。

## 4. AAB（Android App Bundle）のビルド手順

1. 署名キーを作成します。
   ```bash
   keytool -genkey -v -keystore ~/upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
   ```
2. `android/key.properties` を作成します（**Gitに含めないこと**）。
   ```properties
   storePassword=＜パスワード＞
   keyPassword=＜パスワード＞
   keyAlias=upload
   storeFile=/Users/＜you＞/upload-keystore.jks
   ```
3. `android/app/build.gradle(.kts)` の `signingConfigs.release` で上記ファイルを読み込み、`buildTypes.release` に `signingConfig` を設定します（公式手順：https://docs.flutter.dev/deployment/android）。
4. `pubspec.yaml` の `version`（例：`1.0.0+1`）を更新し、ビルドします。
   ```bash
   flutter build appbundle --release
   ```
5. 出力：`build/app/outputs/bundle/release/app-release.aab` を Play Console にアップロードします。

## 5. ストア掲載の準備

- 掲載文：`store_listing/pattern1_utility.md` / `pattern2_mirror.md`
- 画像：`assets/icon_512.svg`（アイコン、PNG 512x512へ書き出して提出）、`assets/feature_graphic_1024.svg`（1024x500のPNG/JPEGへ書き出し）
- プライバシーポリシー：`PRIVACY_POLICY.md` を公開URLにホストして登録（運営者名・連絡先を記入）
- Play Consoleの「データセーフティ」で、広告ID利用（AdMob）を申告してください。

## 6. 動作メモ

- 起動時は権限確認後すぐにプレビューを表示します。広告SDK・IAPの初期化は並行実行され、バナーは読み込み完了まで高さ0です。
- 全画面広告（インタースティシャル／リワード）は実装していません。広告は最上部バナーのみです。
- インカメラのプレビュー反転は `CameraService.mirrorFrontPreview` で切り替えられます。端末で既に鏡像表示になる場合は `false` にしてください。
- ズーム中のフリーズ画像は、フリーズ時点のズーム倍率で撮影された高解像度画像です。ピンチ（最大10倍）とドラッグで観察できます。
- LEDライトはアウトカメラ専用です。インカメラでは画面のリングライトが点灯します。