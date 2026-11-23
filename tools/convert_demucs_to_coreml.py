#!/usr/bin/env python3
"""Demucs (HTDemucs) の学習済みモデルを、Music Structure Lab で使える Core ML 形式に変換する。

注意: このスクリプトは開発環境(Linux、モデルのダウンロード不可)では実行・検証できていません。
coremltools や PyTorch / demucs のバージョンによっては、STFT などの演算が変換できずに失敗します。
失敗した場合はアプリの「近似分離(信号処理)」を使うか、docs/STEM_MODEL.md の形式に合う
別のモデルを用意してください。

使い方(macOS 推奨):
    python3 -m venv .venv && source .venv/bin/activate
    pip install "torch==2.2.*" "demucs==4.0.1" "coremltools==8.1" numpy
    python3 tools/convert_demucs_to_coreml.py --model htdemucs --output StemSeparator.mlpackage

モデルの重みは Meta が MIT ライセンスで公開しているもので、初回実行時に demucs が自動でダウンロードします。
"""

import argparse
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", default="htdemucs", help="demucs の学習済みモデル名(既定: htdemucs)")
    parser.add_argument("--output", default="StemSeparator.mlpackage", help="書き出す .mlpackage のパス")
    parser.add_argument("--seconds", type=float, default=None,
                        help="1 回の推論で扱う長さ(秒)。既定はモデルの学習時の長さ")
    args = parser.parse_args()

    try:
        import coremltools as ct
        import numpy as np
        import torch
        from demucs.pretrained import get_model
    except ImportError as error:
        print(f"必要なパッケージがありません: {error}", file=sys.stderr)
        return 1

    bag = get_model(args.model)
    # get_model は複数モデルの平均 (BagOfModels) を返すことがある。最初のモデルだけを使う。
    model = bag.models[0] if hasattr(bag, "models") else bag
    model.eval()
    sample_rate = int(model.samplerate)
    seconds = args.seconds or float(getattr(model, "segment", 7.8))
    length = int(seconds * sample_rate)
    sources = list(model.sources)
    print(f"model={args.model} sources={sources} sample_rate={sample_rate} segment={length} samples")

    class Wrapper(torch.nn.Module):
        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, mix):
            # mix: [1, 2, L](曲全体の平均・標準偏差で正規化済み。アプリ側で行う)
            return self.inner(mix)

    wrapper = Wrapper(model).eval()
    example = torch.zeros(1, 2, length)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example, check_trace=False)
        reference = traced(torch.randn(1, 2, length) * 0.1)
    print(f"traced output shape: {tuple(reference.shape)}")

    try:
        mlmodel = ct.convert(
            traced,
            inputs=[ct.TensorType(name="mix", shape=(1, 2, length), dtype=np.float32)],
            outputs=[ct.TensorType(name="sources", dtype=np.float32)],
            minimum_deployment_target=ct.target.macOS13,
            compute_precision=ct.precision.FLOAT32,
        )
    except Exception as error:  # noqa: BLE001 - 失敗理由をそのまま表示する
        print("Core ML への変換に失敗しました。", file=sys.stderr)
        print(f"{type(error).__name__}: {error}", file=sys.stderr)
        print("coremltools / torch のバージョンを変えるか、アプリの近似分離を使ってください。", file=sys.stderr)
        return 2

    mlmodel.short_description = f"Demucs ({args.model}) stem separation for Music Structure Lab"
    mlmodel.user_defined_metadata["sources"] = ",".join(sources)
    mlmodel.user_defined_metadata["sample_rate"] = str(sample_rate)
    mlmodel.user_defined_metadata["license"] = "Demucs weights: MIT (Meta Platforms, Inc.)"
    mlmodel.save(args.output)
    print(f"saved: {args.output}")
    print("アプリのインスペクタ「パート」→「機械学習モデル」→「モデルを読み込む…」で選んでください。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
