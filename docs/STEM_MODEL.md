# パート分離用の機械学習モデル

Music Structure Lab のパート分離には 2 つの方法があります。

| 方法 | 必要なもの | 品質 |
| --- | --- | --- |
| 近似分離(信号処理) | なし(標準で使える) | 粗い。パート間の漏れが大きい |
| 機械学習モデル | 利用者が用意した Core ML モデル | モデル次第(Demucs 系なら実用的) |

モデルはアプリに同梱していません。サイズが大きく(数十〜数百 MB)、利用者が自分で選んで入れる形にしています。
モデルを読み込んでいない時に「機械学習モデル」を選ぶと、近似分離で分離します(画面にもそう表示されます)。

## モデルに求める形

- 入力: Float32 の MultiArray を 1 つ。形は `[1, 2, L]` または `[2, L]`(ステレオ・L サンプル固定)。
- 出力: MultiArray を 1 つ。形は `[1, S, 2, L]` または `[S, 2, L]`(S = パート数)。
- メタデータ(Core ML の user defined metadata):
  - `sources`: パートの並び。例 `drums,bass,other,vocals`。無ければこの Demucs の順とみなします。
  - `sample_rate`: モデルのサンプルレート。無ければ 44100。

アプリ側の処理:

1. 再生と同じチャンネルを使う(モノラルなら左右に同じ音を入れる)。サンプルレートが違えば変換する。
2. 曲全体の平均・標準偏差で正規化する(Demucs の推論と同じ)。
3. L サンプルごとに 25% 重ねて推論し、重なりは直線でつなぐ。
4. 正規化を戻し、元のサンプルレート・チャンネル数に戻す。
5. パートの対応: `drums` → ドラム、`bass` → ベース、`vocals` → ボーカル、それ以外(`other`, `guitar`, `piano` など)→ コード(伴奏)。
6. モデルはメロディを出力しないので、コード(伴奏) から音高追跡(近似分離と同じ方法)でメロディを取り出し、残りをコード(伴奏) にします。メロディの品質は近似分離と同程度です。

## Demucs から作る

`tools/convert_demucs_to_coreml.py` で、Meta が MIT ライセンスで公開している Demucs (HTDemucs) を変換できます。

```
python3.11 -m venv .venv
source .venv/bin/activate
pip install "demucs==4.0.1" "coremltools==8.1" numpy
python tools/convert_demucs_to_coreml.py --model htdemucs --output ~/Desktop/StemSeparator.mlpackage
```

HTDemucs は内部で複素数の STFT を使っていて、そのままでは Core ML に変換できません。スクリプトでは変換の前に次の置き換えをします(計算結果は同じです)。

- STFT / 逆 STFT を、DFT の基底を重みにした畳み込みに置き換える
- 複素数のテンソルを、実部・虚部を並べた実数のテンソルに置き換える
- 入力の長さを固定する
- coremltools 8.1 が NumPy 2 で `int` 演算の変換に失敗する問題を回避する
- Transformer の推論用の高速経路を使わずにトレースする

スクリプトは、置き換え前後の PyTorch の出力が一致するかを確かめてから変換します。macOS では、変換した Core ML モデルの出力も元のモデルと比べて表示します。

確認済みの範囲:

- Linux 上で、同じ構造の HTDemucs(学習済みの重みではなくランダムな重み)を使い、置き換え前後の出力の差が 1e-7 程度であることを確かめた
- 変換が最後まで通り、入力 `[1, 2, 343980]`・出力 `[1, 4, 2, 343980]` の .mlpackage(約 275MB)ができることを確かめた
- Core ML での推論は macOS でしか動かせないため、まだ確かめていない(スクリプトが macOS で自動的に比べる)

計算装置: Neural Engine は内部で 16bit 浮動小数点を使うため、Demucs では値があふれて出力が壊れることがあります
(macOS での試行では、HTDemucs は CPU だけで一致し(差 1.3e-5)、CPU+GPU と Neural Engine では出力が大きくずれた。GPU も 16bit で計算する部分があるためと考えられる)。
スクリプトは CPU / CPU+GPU / すべて の順に出力を比べ、一致した計算装置をモデルのメタデータ `compute_units` に記録します。
アプリはこの値を使い、記録が無いモデルは CPU+GPU で動かします。

変換したモデルは、インスペクタの「パート」→「機械学習モデル」→「モデルを読み込む…」で選びます。
読み込んだモデルはコンパイルしてアプリのコンテナ(Application Support/Music Structure Lab/StemModels)に保存します。
