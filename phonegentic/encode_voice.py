#!/usr/bin/env python3
"""
Encode a reference WAV file into default_voice.bin using mimi_encoder.onnx.

Usage:
  python3 encode_voice.py <reference.wav> [output_voice.bin]

Output format (matches C++ loader in pocket_tts_onnx_engine.cc):
  int32  n_frames
  int32  n_dims   (1024)
  float32[n_frames * n_dims]
"""
import sys
import struct
import numpy as np
import onnxruntime as ort

MODELS_DIR = "/d/p/phonegentic/phonegentic/models/pocket-tts-onnx"
SAMPLE_RATE = 24000

def load_wav_mono_f32(path: str) -> np.ndarray:
    """Load WAV, convert to mono float32 at SAMPLE_RATE."""
    try:
        import soundfile as sf
        audio, sr = sf.read(path, dtype="float32", always_2d=False)
    except ImportError:
        import wave, array
        with wave.open(path, "rb") as wf:
            sr = wf.getframerate()
            nch = wf.getnchannels()
            sw = wf.getsampwidth()
            raw = wf.readframes(wf.getnframes())
        fmt = {1: "b", 2: "h", 4: "i"}[sw]
        samples = np.array(array.array(fmt, raw), dtype=np.float32)
        samples /= float(1 << (8 * sw - 1))
        if nch > 1:
            samples = samples.reshape(-1, nch).mean(axis=1)
        audio = samples

    if audio.ndim > 1:
        audio = audio.mean(axis=1)

    if sr != SAMPLE_RATE:
        print(f"[encode_voice] Resampling {sr}Hz → {SAMPLE_RATE}Hz")
        try:
            import resampy
            audio = resampy.resample(audio, sr, SAMPLE_RATE)
        except ImportError:
            try:
                import librosa
                audio = librosa.resample(audio, orig_sr=sr, target_sr=SAMPLE_RATE)
            except ImportError:
                raise RuntimeError(
                    f"Audio is {sr}Hz but need {SAMPLE_RATE}Hz. "
                    "Install resampy or librosa: pip install resampy"
                )

    return audio.astype(np.float32)


def encode_voice(wav_path: str, out_path: str):
    encoder_path = f"{MODELS_DIR}/onnx/mimi_encoder.onnx"
    print(f"[encode_voice] Loading encoder: {encoder_path}")
    sess = ort.InferenceSession(encoder_path)

    # Inspect I/O
    in_names  = [i.name for i in sess.get_inputs()]
    out_names = [o.name for o in sess.get_outputs()]
    in_shapes = [i.shape for i in sess.get_inputs()]
    print(f"[encode_voice] Inputs:  {list(zip(in_names, in_shapes))}")
    print(f"[encode_voice] Outputs: {out_names}")

    audio = load_wav_mono_f32(wav_path)
    print(f"[encode_voice] Audio: {len(audio)} samples ({len(audio)/SAMPLE_RATE:.2f}s) at {SAMPLE_RATE}Hz")

    # mimi_encoder expects [1, 1, T] float32
    audio_tensor = audio.reshape(1, 1, -1)

    feed = {in_names[0]: audio_tensor}
    outputs = sess.run(None, feed)
    embeddings: np.ndarray = np.asarray(outputs[0])  # [1, T, 1024] or [1, 1024, T]

    print(f"[encode_voice] Raw output shape: {embeddings.shape}")

    # Normalize to [T, 1024]. Detect layout by which axis is 1024.
    if embeddings.ndim == 3:
        if embeddings.shape[2] == 1024:
            emb = embeddings[0]       # [1, T, 1024] → [T, 1024]
        elif embeddings.shape[1] == 1024:
            emb = embeddings[0].T     # [1, 1024, T] → [T, 1024]
        else:
            raise RuntimeError(f"Neither axis is 1024: {embeddings.shape}")
    elif embeddings.ndim == 2:
        if embeddings.shape[1] == 1024:
            emb = embeddings          # [T, 1024]
        elif embeddings.shape[0] == 1024:
            emb = embeddings.T        # [1024, T] → [T, 1024]
        else:
            raise RuntimeError(f"Neither axis is 1024: {embeddings.shape}")
    else:
        raise RuntimeError(f"Unexpected embedding shape: {embeddings.shape}")

    n_frames, n_dims = emb.shape
    print(f"[encode_voice] Embeddings: {n_frames} frames × {n_dims} dims")

    if n_dims != 1024:
        print(f"[encode_voice] WARNING: expected 1024 dims, got {n_dims}")

    # Write binary: int32 n_frames, int32 n_dims, float32 data
    with open(out_path, "wb") as f:
        f.write(struct.pack("<ii", n_frames, n_dims))
        f.write(emb.astype(np.float32).tobytes())

    size_kb = (8 + n_frames * n_dims * 4) / 1024
    print(f"[encode_voice] Saved → {out_path}  ({size_kb:.0f} KB)")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    wav  = sys.argv[1]
    out  = sys.argv[2] if len(sys.argv) > 2 else f"{MODELS_DIR}/default_voice.bin"
    encode_voice(wav, out)
