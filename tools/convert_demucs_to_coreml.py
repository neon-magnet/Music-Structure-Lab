#!/usr/bin/env python3
"""Demucs (HTDemucs) の学習済みモデルを、Music Structure Lab で使える Core ML 形式に変換する。

HTDemucs は内部で複素数の STFT / 逆 STFT を使っていて、そのままでは Core ML に変換できない。
このスクリプトでは、変換の前に次の置き換えをする(計算結果は元のモデルと同じ)。

- STFT / 逆 STFT を、DFT の基底を重みにした畳み込み (conv1d / conv_transpose1d) にする
- 複素数のテンソルを、実部・虚部を並べた実数のテンソルにする
- 入力の長さを固定し、長さから計算していた値を定数にする
- coremltools 8.1 が NumPy 2 で `int` 演算の変換に失敗する問題を回避する
- Transformer の推論用の高速経路(Core ML に変換できない)を使わずにトレースする

変換前に、置き換えたモデルと元のモデルの出力が一致することを PyTorch で確かめる。
macOS では、変換した Core ML モデルの出力も元のモデルと比べる。

使い方(macOS):
    python3.11 -m venv .venv && source .venv/bin/activate
    pip install "demucs==4.0.1" "coremltools==8.1" numpy
    python tools/convert_demucs_to_coreml.py --model htdemucs_6s --output ~/Desktop/StemSeparator6.mlpackage

htdemucs_6s はギター・ピアノも別に出力するので、アプリでメロディとコードを分けやすくなる(おすすめ)。
htdemucs(4 パート)も変換できる。

モデルの重みは Meta が MIT ライセンスで公開しているもので、初回実行時に demucs が自動でダウンロードする。
"""

import argparse
import copy
import math
import sys
import types


def build_conv_stft(torch, F):
    class ConvSTFT(torch.nn.Module):
        """torch.stft / istft(hann 窓, normalized=True, center=True, reflect)を畳み込みで行う。"""

        def __init__(self, n_fft, hop):
            super().__init__()
            self.n_fft = n_fft
            self.hop = hop
            bins = n_fft // 2 + 1
            n = torch.arange(n_fft, dtype=torch.float64)
            k = torch.arange(bins, dtype=torch.float64)
            window = torch.hann_window(n_fft, dtype=torch.float64)
            angle = 2 * math.pi * k[:, None] * n[None, :] / n_fft
            scale = 1 / math.sqrt(n_fft)
            forward = torch.cat([torch.cos(angle) * window * scale, -torch.sin(angle) * window * scale])
            self.register_buffer("forward_basis", forward[:, None, :].float())
            weights = torch.full((bins,), 2.0, dtype=torch.float64)
            weights[0] = 1
            weights[-1] = 1
            inverse_scale = math.sqrt(n_fft) / n_fft
            inverse = torch.cat([
                torch.cos(angle) * weights[:, None] * window * inverse_scale,
                -torch.sin(angle) * weights[:, None] * window * inverse_scale,
            ])
            self.register_buffer("inverse_basis", inverse[:, None, :].float())
            self.register_buffer("window_sq", (window ** 2).float())

        def stft(self, x):
            # x: [N, L] -> [N, 2 * bins, frames](前半が実部、後半が虚部)
            pad = self.n_fft // 2
            x = F.pad(x[:, None, :], (pad, pad), mode="reflect")
            return F.conv1d(x, self.forward_basis, stride=self.hop)

        def istft(self, z, length):
            # z: [N, 2 * bins, frames] -> [N, length]
            frames = z.shape[-1]
            y = F.conv_transpose1d(z, self.inverse_basis, stride=self.hop)[:, 0, :]
            total = (frames - 1) * self.hop + self.n_fft
            envelope = torch.zeros(total, dtype=torch.float64)
            window_sq = self.window_sq.double()
            for t in range(frames):
                envelope[t * self.hop: t * self.hop + self.n_fft] += window_sq
            envelope = torch.where(envelope > 1e-11, envelope, torch.ones_like(envelope))
            y = y / envelope.float()
            start = self.n_fft // 2
            return y[:, start: start + length]

    return ConvSTFT


def patch_htdemucs(model, length, torch, F):
    """HTDemucs の複素数・長さに依存する処理を、長さ `length` 固定の実数の処理に置き換える。"""
    hop = model.hop_length
    nfft = model.nfft
    model.add_module("conv_stft", build_conv_stft(torch, F)(nfft, hop))
    channels = model.audio_channels
    frames = int(math.ceil(length / hop))
    pad = hop // 2 * 3
    bins = nfft // 2 + 1

    def _spec(self, x):
        batch = x.shape[0]
        x = F.pad(x, (pad, pad + frames * hop - length), mode="reflect")
        z = self.conv_stft.stft(x.reshape(batch * channels, -1))
        z = z.reshape(batch, channels, 2, bins, -1)
        return z[:, :, :, :-1, 2: 2 + frames]

    def _magnitude(self, z):
        batch, c, two, fr, t = z.shape
        return z.reshape(batch, c * 2, fr, t)

    def _mask(self, z, m):
        batch, s, c, fr, t = m.shape
        return m.reshape(batch, s, c // 2, 2, fr, t)

    def _ispec(self, z, length_unused=None, scale=0):
        batch, s, c, two, fr, t = z.shape
        z = z.reshape(batch * s * c, 2, fr, t)
        z = F.pad(z, (2, 2, 0, 1))
        z = z.reshape(batch * s * c, 2 * (fr + 1), t + 4)
        x = self.conv_stft.istft(z, hop * frames + 2 * pad)
        x = x[:, pad: pad + length]
        return x.reshape(batch, s, c, length)

    model._spec = types.MethodType(_spec, model)
    model._magnitude = types.MethodType(_magnitude, model)
    model._mask = types.MethodType(_mask, model)
    model._ispec = types.MethodType(_ispec, model)
    return model


def patch_coremltools_int_cast(np):
    """長さ 1 の定数配列を int / bool に変換する時、NumPy 2 でエラーになる問題を避ける。"""
    from coremltools.converters.mil import Builder as mb
    from coremltools.converters.mil.frontend.torch import ops

    original = ops._cast

    def _cast(context, node, dtype, dtype_name):
        x = ops._get_inputs(context, node, expected=1)[0]
        if x.can_be_folded_to_const() and np.ndim(x.val) > 0:
            value = np.asarray(x.val).reshape(-1)
            if value.size == 1:
                context.add(mb.const(val=dtype(value[0].item()), name=node.name), node.name)
                return
        return original(context, node, dtype, dtype_name)

    ops._cast = _cast


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", default="htdemucs", help="demucs の学習済みモデル名(既定: htdemucs)")
    parser.add_argument("--output", default="StemSeparator.mlpackage", help="書き出す .mlpackage のパス")
    args = parser.parse_args()

    try:
        import coremltools as ct
        import numpy as np
        import torch
        import torch.nn.functional as F
        from demucs.htdemucs import HTDemucs
        from demucs.pretrained import get_model
    except ImportError as error:
        print(f"必要なパッケージがありません: {error}", file=sys.stderr)
        return 1

    bag = get_model(args.model)
    # get_model は複数モデルの平均 (BagOfModels) を返す。最初のモデルを使う。
    model = bag.models[0] if hasattr(bag, "models") else bag
    if not isinstance(model, HTDemucs):
        print(f"{args.model} は HTDemucs ではないので、このスクリプトでは変換できません。htdemucs か htdemucs_6s を指定してください。",
              file=sys.stderr)
        return 1
    model = model.cpu().eval()
    sample_rate = int(model.samplerate)
    length = int(model.segment * model.samplerate)
    sources = list(model.sources)
    print(f"model={args.model} sources={sources} sample_rate={sample_rate} segment={length} samples")

    # 置き換え後のモデルが元のモデルと同じ結果になるかを確かめる。
    torch.manual_seed(0)
    example = torch.randn(1, 2, length) * 0.1
    patched = patch_htdemucs(copy.deepcopy(model), length, torch, F).eval()
    with torch.no_grad():
        reference = model(example)
        result = patched(example)
    difference = (reference - result).abs().max().item()
    print(f"置き換え前後の出力の差(最大): {difference:.2e}")
    if difference > 1e-3:
        print("置き換え後のモデルの出力が元と一致しません。変換を中止します。", file=sys.stderr)
        return 2

    class Wrapper(torch.nn.Module):
        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, mix):
            # mix: [1, 2, L](曲全体の平均・標準偏差で正規化済み。アプリ側で行う)
            return self.inner(mix)

    # 推論用の高速経路 (_native_multi_head_attention) は Core ML に変換できないので使わない。
    if hasattr(torch.backends, "mha") and hasattr(torch.backends.mha, "set_fastpath_enabled"):
        torch.backends.mha.set_fastpath_enabled(False)
    traced = torch.jit.trace(Wrapper(patched).eval(), example, check_trace=False)

    patch_coremltools_int_cast(np)
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
        return 3

    mlmodel.short_description = f"Demucs ({args.model}) stem separation for Music Structure Lab"
    mlmodel.user_defined_metadata["sources"] = ",".join(sources)
    mlmodel.user_defined_metadata["sample_rate"] = str(sample_rate)
    mlmodel.user_defined_metadata["license"] = "Demucs weights: MIT (Meta Platforms, Inc.)"
    mlmodel.save(args.output)
    print(f"saved: {args.output}")

    if sys.platform == "darwin":
        # 変換したモデルを計算装置ごとに動かして、元のモデルと比べる。
        # Neural Engine は内部で 16bit 浮動小数点を使うので、値の大きい層があると結果が壊れることがある。
        scale = reference.abs().max().item()
        expected = reference.numpy()
        mix = {"mix": example.numpy().astype(np.float32)}
        results = {}
        for label, units in [("CPU", ct.ComputeUnit.CPU_ONLY),
                             ("CPU+GPU", ct.ComputeUnit.CPU_AND_GPU),
                             ("すべて (Neural Engine を含む)", ct.ComputeUnit.ALL)]:
            try:
                loaded = ct.models.MLModel(args.output, compute_units=units)
                prediction = loaded.predict(mix)["sources"]
                diff = float(np.nanmax(np.abs(prediction - expected))) if np.all(np.isfinite(prediction)) else float("inf")
            except Exception as error:  # noqa: BLE001
                print(f"[{label}] 実行できませんでした: {type(error).__name__}: {error}")
                continue
            ok = diff < max(1e-3, scale * 1e-2)
            results[label] = ok
            print(f"[{label}] Core ML と PyTorch の出力の差(最大): {diff:.2e}(出力の最大値 {scale:.2e})→ {'OK' if ok else 'ずれが大きい'}")

        if results.get("CPU+GPU"):
            recommended = "cpuAndGPU"
        elif results.get("CPU"):
            recommended = "cpuOnly"
        else:
            print("CPU でも出力が一致しませんでした。変換そのものに問題があります。上の出力をすべて共有してください。",
                  file=sys.stderr)
            return 4
        if results.get("すべて (Neural Engine を含む)"):
            recommended = "all"
        # アプリはこの値を読んで、計算装置を選ぶ。
        mlmodel.user_defined_metadata["compute_units"] = recommended
        mlmodel.save(args.output)
        print(f"アプリで使う計算装置: {recommended}(モデルに記録しました)")

    print("アプリのインスペクタ「パート」→「機械学習モデル」→「モデルを読み込む…」で選んでください。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
