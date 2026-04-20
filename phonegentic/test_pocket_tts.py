#!/usr/bin/env python3
"""
Compare Python ONNX inference with C++ output.
Run: python3 test_pocket_tts.py
Play output: aplay -r 24000 -f S16_LE -c 1 /tmp/py_pocket_tts.raw
"""
import numpy as np
import onnxruntime as ort
import sentencepiece as spm
import sys, os

MODELS_DIR = os.path.expanduser(
    "~/phonegentic/build/linux/x64/debug/bundle/data/flutter_assets/models/pocket-tts-onnx"
)
# fallback to absolute path
if not os.path.exists(MODELS_DIR):
    MODELS_DIR = "/d/p/phonegentic/phonegentic/build/linux/x64/debug/bundle/data/flutter_assets/models/pocket-tts-onnx"

TEXT       = "Testing confirmed."
LSD_STEPS  = 10
FRAMES_AFTER_EOS = 3
EOS_THRESHOLD    = -4.0
TEMPERATURE      = 0.7   # reference uses 0.7; 0.0 = zeros, 1.0 = full noise

# Voice conditioning: reference runs mimi_encoder on audio FIRST, then text.
# We don't have mimi_encoder.onnx, so test with small zero voice embedding.
# Set to None to skip the voice pass (our old behavior), or set a shape like (1, 4, 1024).
VOICE_EMB_FRAMES = 4    # try 4 frames of zero voice embedding; None to skip

def init_state(sess):
    state = {}
    type_map = {"tensor(float)": np.float32, "tensor(int64)": np.int64, "tensor(bool)": np.bool_}
    for inp in sess.get_inputs():
        if inp.name.startswith("state_"):
            shape = [s if isinstance(s, int) else 0 for s in inp.shape]
            state[inp.name] = np.zeros(shape, dtype=type_map.get(inp.type, np.float32))
    return state

def update_state(state, result, sess):
    for i, out in enumerate(sess.get_outputs()):
        if out.name.startswith("out_state_"):
            idx = int(out.name.replace("out_state_", ""))
            state[f"state_{idx}"] = result[i]

# ── Load ─────────────────────────────────────────────────────────────────────
print(f"[PY] Models dir: {MODELS_DIR}")
text_cond = ort.InferenceSession(f"{MODELS_DIR}/onnx/text_conditioner.onnx")
flow_main = ort.InferenceSession(f"{MODELS_DIR}/onnx/flow_lm_main_int8.onnx")
flow_flow = ort.InferenceSession(f"{MODELS_DIR}/onnx/flow_lm_flow_int8.onnx")
mimi_dec  = ort.InferenceSession(f"{MODELS_DIR}/onnx/mimi_decoder_int8.onnx")
sp = spm.SentencePieceProcessor()
sp.Load(f"{MODELS_DIR}/tokenizer.model")
print(f"[PY] All models loaded")

# ── Tokenize ─────────────────────────────────────────────────────────────────
token_ids = np.array([sp.EncodeAsIds(TEXT)], dtype=np.int64)
print(f"[PY] Tokens ({token_ids.shape[1]}): {token_ids[0].tolist()}")

# ── Text conditioner ─────────────────────────────────────────────────────────
text_emb = text_cond.run(None, {"token_ids": token_ids})[0]
print(f"[PY] text_emb shape: {text_emb.shape}")

# ── Init flow_lm_main state ───────────────────────────────────────────────────
state = init_state(flow_main)
print(f"[PY] flow_lm_main states: {len(state)}")

# ── Voice conditioning pass (reference script does this FIRST with mimi_encoder output) ──
# We don't have mimi_encoder.onnx, so use dummy zero voice embeddings.
# Skip by setting VOICE_EMB_FRAMES = None to reproduce old (broken) behavior.
empty_seq  = np.zeros((1, 0, 32), dtype=np.float32)
if VOICE_EMB_FRAMES:
    dummy_voice = np.zeros((1, VOICE_EMB_FRAMES, 1024), dtype=np.float32)
    res_voice = flow_main.run(None, {"sequence": empty_seq, "text_embeddings": dummy_voice, **state})
    update_state(state, res_voice, flow_main)
    pos_v = state.get("state_2")
    print(f"[PY] After voice cond: state_2(pos)={pos_v.flat[0] if pos_v is not None else 'N/A'}")

# ── Text conditioning pass ────────────────────────────────────────────────────
res = flow_main.run(None, {"sequence": empty_seq, "text_embeddings": text_emb, **state})
update_state(state, res, flow_main)
pos = state.get("state_2")
print(f"[PY] After text cond: state_2(pos)={pos.flat[0] if pos is not None else 'N/A'}")

# ── Autoregressive generation ─────────────────────────────────────────────────
curr     = np.full((1, 1, 32), np.nan, dtype=np.float32)
dt       = 1.0 / LSD_STEPS
latents  = []
eos_step = None
rng      = np.random.default_rng(42)  # fixed seed for reproducibility

for step in range(500):
    empty_text = np.zeros((1, 0, 1024), dtype=np.float32)
    res = flow_main.run(None, {"sequence": curr, "text_embeddings": empty_text, **state})
    update_state(state, res, flow_main)

    cond    = res[0]       # [1, 1024]
    eos_val = float(res[1].flat[0])

    if step < 5:
        print(f"[PY] Gen step {step}: eos={eos_val:.4f}  cond[0]={cond.flat[0]:.4f}")

    if eos_val > EOS_THRESHOLD and eos_step is None:
        eos_step = step
    if eos_step is not None and step >= eos_step + FRAMES_AFTER_EOS:
        break

    # Flow matching: init x from noise or zeros
    std = np.sqrt(TEMPERATURE)
    # Use per-step seeded RNG to match C++ behavior (step * prime)
    step_rng = np.random.default_rng(step * 2654435761 & 0xFFFFFFFF)
    if TEMPERATURE > 0:
        x = step_rng.standard_normal((1, 32)).astype(np.float32) * std
    else:
        x = np.zeros((1, 32), dtype=np.float32)

    if step == 0:
        print(f"[PY] x_init[0..3]: {x[0, :4]}")

    for j in range(LSD_STEPS):
        s_val = j / LSD_STEPS
        t_val = (j + 1) / LSD_STEPS
        s_arr = np.array([[s_val]], dtype=np.float32)
        t_arr = np.array([[t_val]], dtype=np.float32)
        flow_dir = flow_flow.run(None, {"c": cond, "s": s_arr, "t": t_arr, "x": x})[0]
        x = x + flow_dir * dt

    if step == 0:
        print(f"[PY] x_final[0..3]: {x[0, :4]}")

    latents.append(x[0].copy())
    curr = x.reshape(1, 1, 32)

print(f"[PY] Generated {len(latents)} latent frames")

# ── Mimi decode ───────────────────────────────────────────────────────────────
CHUNK = 12
mimi_state = init_state(mimi_dec)
all_audio  = []

lat_arr = np.stack(latents, axis=0)[np.newaxis]  # [1, T, 32]
for i in range(0, len(latents), CHUNK):
    chunk = lat_arr[:, i:i+CHUNK, :]
    mi_res = mimi_dec.run(None, {"latent": chunk, **mimi_state})
    update_state(mimi_state, mi_res, mimi_dec)
    audio_chunk = mi_res[0].flatten()
    if i == 0:
        print(f"[PY] Mimi chunk0: {len(audio_chunk)} samples  range=[{audio_chunk.min():.6f}, {audio_chunk.max():.6f}]")
    all_audio.append(audio_chunk)

all_audio = np.concatenate(all_audio)
print(f"[PY] Total audio: {len(all_audio)} samples  range=[{all_audio.min():.6f}, {all_audio.max():.6f}]")

# ── Normalize amplitude (match C++ logic) ────────────────────────────────────
rms = np.sqrt(np.mean(all_audio**2))
peak = np.abs(all_audio).max()
if rms > 1e-7:
    gain = 0.15 / rms
    if peak * gain > 0.95:
        gain = 0.95 / peak
    all_audio *= gain
    print(f"[PY] Amplitude: rms={rms:.5f}  peak={peak:.5f}  gain={gain:.1f}x")

# ── Save PCM16 ────────────────────────────────────────────────────────────────
pcm16 = np.clip(all_audio, -1, 1)
pcm16 = (pcm16 * 32767).astype(np.int16)
out_path = "/tmp/py_pocket_tts.raw"
pcm16.tofile(out_path)
print(f"[PY] Saved {len(pcm16)} PCM16 samples → {out_path}")
print(f"[PY] Play: aplay -r 24000 -f S16_LE -c 1 {out_path}")
