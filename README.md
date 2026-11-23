# Music Structure Lab

macOS 向けの音楽解析・作曲支援アプリケーションです。音源を読み込み、解析し、結果を編集・保存・出力できる実用的なアプリを目指しています。

## 現在の実装状況

| 機能 | 状態 |
| --- | --- |
| 音源ファイルの読み込み (AVFoundation) | ✅ 実装済み |
| 波形表示 (チャンネル別 / ミックス、拡大・縮小・スクロール) | ✅ 実装済み |
| 時間軸・カーソル位置・全体ミニマップ | ✅ 実装済み |
| 再生 (波形の再生位置と連動) | ✅ 実装済み |
| テンポ・拍 解析 | ⬜ 未実装 |
| キー・コード解析 | ⬜ 未実装 |
| 楽曲構造 (セクション) 解析 | ⬜ 未実装 |
| 解析結果の編集・保存・書き出し | ⬜ 未実装 |

未実装の機能は UI にも表示していません。

### 音源の読み込み

- 対応形式: WAV / AIFF / CAF / MP3 / AAC (M4A) / Apple Lossless / FLAC など、macOS の Core Audio が読める形式
- 開き方: 「開く…」ボタン、メニューの ファイル > 開く… (⌘O)、ウィンドウへのドラッグ&ドロップ、Finder の「このアプリケーションで開く」
- 読み込みはバックグラウンドで行い、進捗表示と中止ができます。別のファイルを開くと前の読み込みは中止されます。
- デコードしたサンプルは 32bit float でチャンネルごとに保持し、全チャンネル平均 (モノラル) も作ります。今後の解析はこのデータを入力にします。

### 再生

- AVAudioEngine で、デコード済みのサンプルをそのまま再生します。再生位置はサンプル単位で取得し、波形上の再生位置 (オレンジの線) が追従します。
- 再生位置が表示範囲の外に出ると、自動でページ送りします。
- 3 チャンネル以上の音源は、モノラルミックスで再生します。
- 出力デバイスが変わった時は、その位置で一時停止します。

### 波形表示

- 多段解像度のピーク (min/max) を読み込み時に作るので、長い曲でも全体表示・拡大表示が軽く動きます。
- 1 画素に 1 サンプル未満まで拡大すると、個々のサンプルを結ぶ線 (さらに拡大すると点) で表示します。

| 操作 | 動作 |
| --- | --- |
| クリック | 再生位置を移動 (再生中はその位置から再生を続ける) |
| スペース | 再生 / 一時停止 |
| ドラッグ / 横スクロール / マウスホイール | 左右に移動 |
| ⌘ または ⌥ + スクロール、ピンチ | ポインタ位置を中心に拡大・縮小 |
| ⌘+ / ⌘- / ⌘0 | 拡大 / 縮小 / 全体表示 |
| 下部ミニマップのクリック・ドラッグ | その位置へ移動 |

## ビルドと起動

必要環境: macOS 13 以降、Xcode 15 以降 (Swift 5.9 以降)

### Swift Package として (いちばん手軽)

```sh
swift run MusicStructureLab   # アプリを起動
swift test                    # テストを実行
```

Xcode で `Package.swift` を開き、`MusicStructureLab` スキームを実行することもできます。

### .app バンドルとして (サンドボックス付き)

[XcodeGen](https://github.com/yonaskolb/XcodeGen) で Xcode プロジェクトを生成します。

```sh
brew install xcodegen
xcodegen generate
open MusicStructureLab.xcodeproj
```

署名は Xcode の Signing & Capabilities で自分のチームを選んでください。

## プロジェクト構成

```
Sources/
  MSLCore/            プラットフォーム非依存のモデルと解析ロジック
    Audio/            DecodedAudio, AudioFileInfo
    Waveform/         多段解像度の波形ピーク (WaveformBuilder / WaveformOverview)
    Timeline/         表示範囲の計算 (WaveformViewport)、時間の書式
  MSLAudio/           AVFoundation による音源デコード (AudioFileLoader) と再生 (AudioPlayer)
  MusicStructureLab/  SwiftUI アプリ本体
    Models/           AudioDocumentModel (読み込み状態・カーソル等)
    Views/            画面 (ContentView, WaveformPanel, 描画ビュー)
Tests/
  MSLCoreTests/       波形ピーク・表示範囲・時間書式のテスト
  MSLAudioTests/      実際に WAV を書き出して読み込むテスト、再生バッファのテスト
project.yml           XcodeGen 用の .app 定義
```

今後の解析機能 (テンポ、キー、構造など) は `MSLCore` に `Analysis/` として追加し、UI は `MusicStructureLab/Views` に追加する想定です。解析ロジックを UI や AVFoundation から切り離しておくことで、単体テストしやすくしています。

## CI

GitHub Actions (macOS ランナー) で `swift build` / `swift test` と、XcodeGen で生成した .app のビルドを実行します。
