# Kokoro TTS Model Conversion: PyTorch → ONNX for Linux

This document describes the process of converting the Kokoro-82M TTS model from its native PyTorch format (distributed on HuggingFace) into the ONNX format consumed by the phonegentic Linux app.

## Background

The phonegentic app uses [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) for on-device text-to-speech. On macOS, the model runs via Apple's MLX framework through the `KokoroSwift` SPM package. On Linux, we use ONNX Runtime for inference.

**Problem**: The HuggingFace repository `hexgrad/Kokoro-82M` only distributes PyTorch `.pth` weight files. No pre-exported ONNX model exists. We must export it ourselves.

## Source Format (HuggingFace)

The repository contains:

| File | Description |
|---|---|
| `kokoro-v1_0.pth` | PyTorch model weights (~82M parameters) |
| `config.json` | Model configuration (vocab, dimensions, etc.) |
| `voices/*.pt` | Voice embedding tensors, shape `[510, 1, 256]` each |

### Model Architecture

The model (`KModel` in `kokoro/model.py`) consists of:

1. **CustomAlbert** (ALBERT encoder) — text encoder with 178-token vocabulary
2. **ProsodyPredictor** — predicts duration, F0, and noise
3. **TextEncoder** — conv-based phoneme encoder
4. **Decoder** (iSTFTNet) — generates audio via inverse STFT

The `forward()` signature is:
```python
forward_with_tokens(
    input_ids: LongTensor [1, N],   # phoneme token IDs
    ref_s: FloatTensor [1, 256],    # style vector from voice pack
    speed: float                     # speech speed multiplier
) -> (audio: FloatTensor [1, M], duration: LongTensor [N])
```

### Voice Pack Format

Each voice file (`voices/af_heart.pt`, etc.) is a PyTorch tensor with shape `[510, 1, 256]`:
- **510 rows** — one style vector per possible phoneme sequence length
- **256 dimensions** — split into two parts:
  - `ref_s[:, :128]` → decoder conditioning (timbre/prosody)
  - `ref_s[:, 128:]` → predictor conditioning (duration/F0)

At inference, the Python code selects: `pack[len(phonemes) - 1]` to get a single `[1, 256]` style vector.

## Step 1: ONNX Export

### Prerequisites

```bash
pip install kokoro torch onnxruntime
# kokoro pulls in: huggingface_hub, misaki, numpy, transformers
```

### The `disable_complex` Flag

The default Kokoro model uses `torch.istft()` which involves complex number operations (`ComplexFloat` tensors). ONNX's `torch.onnx.export()` does not support complex number types and fails with:

```
RuntimeError: Unknown number type: complex
```

The kokoro package provides a `disable_complex=True` flag on `KModel` that replaces the `TorchSTFT` (which uses `torch.stft`/`torch.istft` with complex numbers) with `CustomSTFT` (which uses `conv1d`/`conv_transpose1d` to avoid complex ops entirely). This is explicitly designed for ONNX export.

### Export Script

```python
import torch
import os
import warnings
warnings.filterwarnings("ignore")
os.environ["TF_CPP_MIN_LOG_LEVEL"] = "3"

from kokoro import KModel
from kokoro.model import KModelForONNX

# Load model with disable_complex=True for ONNX-safe iSTFT
model = KModel(repo_id='hexgrad/Kokoro-82M', disable_complex=True).to('cpu').eval()

# Wrap in ONNX-friendly forward (exposes forward_with_tokens directly)
onnx_model = KModelForONNX(model)
onnx_model.eval()

# Create dummy inputs matching the model's expected signature
N = 50  # sequence length for tracing
dummy_input_ids = torch.randint(1, 150, (1, N), dtype=torch.long)
dummy_ref_s = torch.randn(1, 256, dtype=torch.float32)
dummy_speed = torch.tensor(1.0, dtype=torch.float64)  # NOTE: must be double

# Verify forward pass works
with torch.no_grad():
    audio, dur = onnx_model(dummy_input_ids, dummy_ref_s, dummy_speed)
    print(f"Forward pass OK: audio={audio.shape}, dur={dur.shape}")

# Export to ONNX
torch.onnx.export(
    onnx_model,
    (dummy_input_ids, dummy_ref_s, dummy_speed),
    "kokoro-v1_0.onnx",
    input_names=['input_ids', 'ref_s', 'speed'],
    output_names=['audio', 'duration'],
    dynamic_axes={
        'input_ids': {1: 'seq_len'},    # variable-length token sequences
        'audio': {0: 'audio_len'},       # variable-length audio output
        'duration': {0: 'dur_len'},      # variable-length duration output
    },
    opset_version=17,
    do_constant_folding=True,
)
print("ONNX export complete!")
```

### Resulting ONNX Model

| Property | Value |
|---|---|
| File size | ~310 MB |
| Opset version | 17 |

**Inputs:**

| Name | Shape | Type | Description |
|---|---|---|---|
| `input_ids` | `[1, seq_len]` | `int64` | Phoneme token IDs (0-padded) |
| `ref_s` | `[1, 256]` | `float32` | Style vector from voice pack |
| `speed` | `[]` (scalar) | `double` | Speech speed (1.0 = normal) |

**Outputs:**

| Name | Shape | Type | Description |
|---|---|---|---|
| `audio` | `[audio_len]` | `float32` | Audio waveform at 24 kHz |
| `duration` | `[dur_len]` | `int64` | Predicted phoneme durations |

### Verification

```python
import onnxruntime as ort
import numpy as np

sess = ort.InferenceSession("kokoro-v1_0.onnx")

# Print model I/O
for inp in sess.get_inputs():
    print(f"Input: {inp.name} shape={inp.shape} type={inp.type}")
for out in sess.get_outputs():
    print(f"Output: {out.name} shape={out.shape} type={out.type}")

# Test inference
input_ids = np.array([[0, 5, 10, 15, 20, 0]], dtype=np.int64)
ref_s = np.random.randn(1, 256).astype(np.float32)
speed = np.array(1.0, dtype=np.float64)

audio, dur = sess.run(None, {
    'input_ids': input_ids,
    'ref_s': ref_s,
    'speed': speed,
})
print(f"Audio: {audio.shape}, Duration: {dur.shape}")
```

## Step 2: Voice File Conversion

Voice files must be converted from PyTorch `.pt` tensors to NumPy `.npy` format for the C++ engine to load.

```python
import torch
import numpy as np
from huggingface_hub import hf_hub_download

voice_name = "af_heart"  # or any voice from the repo

# Download .pt file from HuggingFace
pt_path = hf_hub_download(
    repo_id='hexgrad/Kokoro-82M',
    filename=f'voices/{voice_name}.pt'
)

# Load PyTorch tensor
pack = torch.load(pt_path, weights_only=True)
# Shape: [510, 1, 256], dtype: float32

# Save as NumPy .npy
np.save(f"voices/{voice_name}.npy", pack.numpy())
```

The `.npy` file preserves the `[510, 1, 256]` shape. The C++ engine reads it as flat float data (510 × 1 × 256 = 130,560 floats) and indexes into it at `row * 256` to extract a 256-dim style vector.

### Available Voices

English voices from `hexgrad/Kokoro-82M`:

| Prefix | Voices |
|---|---|
| `af_` (American female) | alloy, aoede, bella, heart, jessica, kore, nicole, nova, river, sarah, sky |
| `am_` (American male) | adam, echo, eric, fenrir, liam, michael, onyx, puck, santa |
| `bf_` (British female) | alice, emma, isabella, lily |
| `bm_` (British male) | daniel, fable, george, lewis |

## Step 3: Phoneme Pipeline (espeak-ng → Misaki format)

The ONNX model expects token IDs from Misaki's phoneme vocabulary (178 tokens). The phonemization pipeline is:

### 3a. espeak-ng IPA Output

The C++ engine calls `espeak_TextToPhonemes()` with `phonememode=0x02` (bit 1 = IPA mode) to get Unicode IPA:

```
Input:  "Just let me know"
Output: "dʒˈʌst lˈɛt mˌiː nˈoʊ"
```

### 3b. IPA → Misaki Remapping

espeak-ng's IPA differs from what Misaki's G2P produces (which is what the model was trained on). A remapping step converts between them:

| espeak-ng IPA | Misaki | Rule |
|---|---|---|
| `oʊ` | `O` | Diphthong: know, go |
| `aɪ` | `I` | Diphthong: like, my |
| `aʊ` | `W` | Diphthong: brown, how |
| `eɪ` | `A` | Diphthong: say, day |
| `ɔɪ` | `Y` | Diphthong: boy, toy |
| `dʒ` | `ʤ` (U+02A4) | Affricate: just, join |
| `tʃ` | `ʧ` (U+02A7) | Affricate: church |
| `ɜː` | `ɜɹ` | American rhotic |
| `ɚ` | `əɹ` | American rhotic schwa |
| `o` | `ɔ` | espeak < 1.52 compat |
| `ɾ` | `T` | Flapped T (American) |
| `ː` | *(removed)* | No length marks in en-us |

**Order matters**: Diphthongs must be replaced before single-char substitutions (e.g., `oʊ` → `O` before `o` → `ɔ`).

After remapping:
```
Before: "dʒˈʌst lˈɛt mˌiː nˈoʊ"
After:  "ʤˈʌst lˈɛt mˌi nˈO"
```

### 3c. Token Mapping

Each Unicode codepoint of the remapped IPA string is looked up in the 178-token vocabulary (`config.json` → `vocab` key). Unknown codepoints are silently skipped. The token sequence is wrapped with `0` at both ends:

```
IPA:     ʤ  ˈ  ʌ  s  t     l  ˈ  ɛ  t
Tokens:  82 156 138 61 62   60 156 86 62
Wrapped: [0, 82, 156, 138, 61, 62, 60, 156, 86, 62, 0]
```

## Step 4: Integration into the Build

### File Layout

```
phonegentic/models/kokoro/
├── kokoro-v1_0.onnx          # ONNX model (310 MB)
├── config.json               # Model config (for reference)
└── voices/
    ├── af_heart.npy           # Voice embeddings (510 KB each)
    ├── af_bella.npy
    ├── af_nicole.npy
    └── ...
```

### Build System

The `linux/CMakeLists.txt` installs model files into the bundle:

```cmake
install(
    DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../models/kokoro/
    DESTINATION data/flutter_assets/models/kokoro
)
```

The C++ channel code resolves paths relative to the executable:

```cpp
static const char* kModelRelPath =
    "data/flutter_assets/models/kokoro/kokoro-v1_0.onnx";
static const char* kVoicesRelPath =
    "data/flutter_assets/models/kokoro/voices";
```

### Automated Download

The `scripts/download_models.sh` script handles the full pipeline:

```bash
./scripts/download_models.sh kokoro    # download + export + convert voices
```

For Linux, it:
1. Checks if `kokoro-v1_0.onnx` exists (skips if >1MB)
2. Runs the PyTorch → ONNX export via embedded Python
3. Downloads each voice `.pt` file and converts to `.npy`

## Troubleshooting

### "Unknown number type: complex"

The model was exported without `disable_complex=True`. Re-export with the flag.

### "RuntimeError: Opset 17 does not support complex"

Same as above. Use `KModel(disable_complex=True)`.

### Audio sounds like scrambled/garbled speech

The phoneme remapping is missing or incorrect. Verify:
1. `espeak_TextToPhonemes` uses `phonememode=0x02` (not `1`)
2. The `remap_espeak_ipa()` function is applied before tokenization
3. Check stderr for `[KokoroOnnx] IPA remap:` messages

### "Model file not found"

The ONNX model hasn't been exported yet. Run:
```bash
./scripts/download_models.sh kokoro
```

### Voice files not found

Voice `.npy` files must be in `models/kokoro/voices/`. The download script creates them, or convert manually with the Python snippet in Step 2.

## References

- [hexgrad/Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) — Model repository
- [kokoro Python package](https://github.com/hexgrad/kokoro) — Inference library (v0.9.4)
- [`misaki/espeak.py`](https://github.com/hexgrad/kokoro/blob/main/misaki/espeak.py) — Phoneme remapping reference
- [`kokoro/model.py`](https://github.com/hexgrad/kokoro/blob/main/kokoro/model.py) — `KModelForONNX` wrapper
- [`kokoro/custom_stft.py`](https://github.com/hexgrad/kokoro/blob/main/kokoro/custom_stft.py) — ONNX-safe STFT implementation
