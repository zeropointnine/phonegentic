#!/usr/bin/env bash
# Downloads on-device ML models for Kokoro TTS, WhisperKit STT, and Pocket TTS.
# Models are stored in phonegentic/models/ (git-ignored).
#
# Usage:
#   ./scripts/download_models.sh             # download all for current platform
#   ./scripts/download_models.sh kokoro      # Kokoro TTS only
#   ./scripts/download_models.sh whisper     # WhisperKit STT only
#   ./scripts/download_models.sh pocket-tts  # Pocket TTS only (Linux only)
#   ./scripts/download_models.sh status      # show model status
#
# Prerequisites: pip3 install huggingface_hub

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODELS_DIR="$PROJECT_DIR/models"

KOKORO_DIR="$MODELS_DIR/kokoro"
WHISPER_DIR="$MODELS_DIR/whisperkit"
WHISPER_GGML_DIR="$MODELS_DIR/whisper-ggml"
POCKET_TTS_DIR="$MODELS_DIR/pocket-tts-onnx"

WHISPER_MODELS="openai_whisper-tiny openai_whisper-base openai_whisper-small openai_whisper-large-v3_turbo"
WHISPER_GGML_MODELS="ggml-tiny.en.bin ggml-base.en.bin ggml-small.en.bin ggml-large-v3-turbo.bin"

OS="$(uname -s)"

# ─── Helpers ───────────────────────────────────────────────────────────

color_red='\033[0;31m'
color_green='\033[0;32m'
color_yellow='\033[0;33m'
color_cyan='\033[0;36m'
color_reset='\033[0m'

info()  { printf "${color_cyan}==> %s${color_reset}\n" "$*"; }
ok()    { printf "${color_green} ✓  %s${color_reset}\n" "$*"; }
warn()  { printf "${color_yellow} ⚠  %s${color_reset}\n" "$*"; }
err()   { printf "${color_red} ✗  %s${color_reset}\n" "$*" >&2; }

file_size_bytes() {
    local path="$1"
    if [ "$OS" = "Darwin" ]; then
        stat -f%z "$path" 2>/dev/null || echo 0
    else
        stat -c %s "$path" 2>/dev/null || echo 0
    fi
}

dir_size_kb() {
    du -sk "$1" 2>/dev/null | cut -f1 || echo 0
}

dir_size_human() {
    du -sh "$1" 2>/dev/null | cut -f1 || echo "?"
}

# ─── Dependency checks ────────────────────────────────────────────────

check_python() {
    if ! command -v python3 &>/dev/null; then
        err "python3 not found. Please install Python 3."
        exit 1
    fi
}

check_huggingface() {
    check_python
    if ! python3 -c "import huggingface_hub" &>/dev/null; then
        err "huggingface_hub not found."
        echo "    Install with: pip3 install huggingface_hub"
        exit 1
    fi
}

check_metal_toolchain() {
    if [ "$OS" != "Darwin" ]; then return 0; fi
    if ! xcrun metal --version &>/dev/null 2>&1; then
        warn "Metal Toolchain not installed (needed for mlx-swift / Kokoro)."
        echo "    Install with: xcodebuild -downloadComponent MetalToolchain"
        return 1
    fi
    return 0
}

# ─── macOS: Kokoro TTS (MLX bf16 via SPM) ─────────────────────────────

download_kokoro_macos() {
    info "Downloading Kokoro TTS model (MLX bf16, ~327 MB + voices)..."
    mkdir -p "$KOKORO_DIR"

    local fsize=0
    if [ -f "$KOKORO_DIR/kokoro-v1_0.safetensors" ]; then
        fsize=$(file_size_bytes "$KOKORO_DIR/kokoro-v1_0.safetensors")
    fi

    if [ "$fsize" -gt 1000000 ]; then
        ok "kokoro-v1_0.safetensors already exists ($(( fsize / 1048576 ))MB), skipping."
    else
        echo "    Source: mlx-community/Kokoro-82M-bf16"
        python3 -c "
from huggingface_hub import snapshot_download
snapshot_download(
    'mlx-community/Kokoro-82M-bf16',
    local_dir=r'''$KOKORO_DIR''',
    allow_patterns=['kokoro-v1_0.safetensors', 'config.json', 'voices/*.safetensors'],
)
print('Download complete.')
"
    fi
    ok "Kokoro TTS model ready at $KOKORO_DIR"
}

# ─── macOS: WhisperKit STT (CoreML via SPM) ───────────────────────────

download_whisper_macos() {
    info "Downloading WhisperKit STT models (tiny/base/small)..."
    mkdir -p "$WHISPER_DIR"

    for model in $WHISPER_MODELS; do
        local target_dir="$WHISPER_DIR/$model"
        local dsize=0
        if [ -d "$target_dir" ]; then
            dsize=$(dir_size_kb "$target_dir")
        fi

        if [ "$dsize" -gt 1000 ]; then
            ok "$model already exists ($(dir_size_human "$target_dir")), skipping."
        else
            echo "    Downloading $model from argmaxinc/whisperkit-coreml..."
            python3 -c "
from huggingface_hub import snapshot_download
snapshot_download(
    'argmaxinc/whisperkit-coreml',
    local_dir=r'''$WHISPER_DIR''',
    allow_patterns=['$model/**'],
)
print('Download complete.')
"
            ok "WhisperKit STT model ready at $target_dir"
        fi
    done
}

# ─── Linux: whisper.cpp GGML model ────────────────────────────────────

download_whisper_linux() {
    info "Downloading whisper.cpp GGML models (tiny/base/small)..."
    mkdir -p "$WHISPER_GGML_DIR"

    for model in $WHISPER_GGML_MODELS; do
        local target="$WHISPER_GGML_DIR/$model"
        local fsize=0
        if [ -f "$target" ]; then
            fsize=$(file_size_bytes "$target")
        fi

        if [ "$fsize" -gt 1000000 ]; then
            ok "$model already exists ($(( fsize / 1048576 ))MB), skipping."
        else
            echo "    Downloading $model from ggerganov/whisper.cpp..."
            python3 -c "
from huggingface_hub import hf_hub_download
hf_hub_download(
    'ggerganov/whisper.cpp',
    filename='$model',
    local_dir=r'''$WHISPER_GGML_DIR''',
)
print('Download complete.')
"
            ok "$model ready at $target"
        fi
    done
}

# ─── Linux: Kokoro TTS (ONNX via PyTorch export) ──────────────────────
#
# The HuggingFace repo hexgrad/Kokoro-82M only ships PyTorch .pth weights.
# We must export to ONNX locally using the kokoro Python package.
#
# Prerequisites: pip install kokoro torch onnxruntime
# (kokoro pulls in huggingface_hub, misaki, numpy, transformers)

# Default voices to download (English voices for en-us pipeline).
# Full list: https://huggingface.co/hexgrad/Kokoro-82M/tree/main/voices
KOKORO_VOICES="${KOKORO_VOICES:-af_heart af_bella af_nicole af_nova af_river af_sky af_sarah af_kore af_alloy af_aoede af_jessica am_adam am_echo am_eric am_fenrir am_liam am_michael am_onyx am_puck am_santa}"

download_kokoro_linux() {
    info "Setting up Kokoro TTS model (ONNX export + voice conversion)..."
    mkdir -p "$KOKORO_DIR/voices"

    # ── Step 1: Export ONNX model ──────────────────────────────────────
    local onnx_target="$KOKORO_DIR/kokoro-v1_0.onnx"
    local fsize=0
    if [ -f "$onnx_target" ]; then
        fsize=$(file_size_bytes "$onnx_target")
    fi

    if [ "$fsize" -gt 1000000 ]; then
        ok "kokoro-v1_0.onnx already exists ($(( fsize / 1048576 ))MB), skipping export."
    else
        echo "    Exporting PyTorch → ONNX (this may take a few minutes)..."
        echo "    Source: hexgrad/Kokoro-82M (kokoro-v1_0.pth)"
        python3 -c "
import os, warnings, torch
os.environ['TF_CPP_MIN_LOG_LEVEL'] = '3'
warnings.filterwarnings('ignore')

print('  Note: AttributeError: MessageFactory warnings below are harmless protobuf compatibility noise.')
from kokoro import KModel
from kokoro.model import KModelForONNX

print('  Loading KModel with disable_complex=True (ONNX-safe iSTFT)...')
model = KModel(repo_id='hexgrad/Kokoro-82M', disable_complex=True).to('cpu').eval()

onnx_model = KModelForONNX(model)
onnx_model.eval()

# Dummy inputs for tracing
N = 50
dummy_input_ids = torch.randint(1, 150, (1, N), dtype=torch.long)
dummy_ref_s = torch.randn(1, 256, dtype=torch.float32)
dummy_speed = torch.tensor(1.0, dtype=torch.float64)

print('  Testing forward pass...')
with torch.no_grad():
    audio, dur = onnx_model(dummy_input_ids, dummy_ref_s, dummy_speed)
    print(f'  Forward pass OK: audio={audio.shape}, dur={dur.shape}')

print('  Exporting to ONNX (opset 17)...')
print('  Note: shape_type_inference warnings below are harmless; ONNX export still works correctly.')
torch.onnx.export(
    onnx_model,
    (dummy_input_ids, dummy_ref_s, dummy_speed),
    r'''$onnx_target''',
    input_names=['input_ids', 'ref_s', 'speed'],
    output_names=['audio', 'duration'],
    dynamic_axes={
        'input_ids': {1: 'seq_len'},
        'audio': {0: 'audio_len'},
        'duration': {0: 'dur_len'},
    },
    opset_version=17,
    do_constant_folding=True,
)
print('  ONNX export complete!')
" || { err "ONNX export failed. Install deps: pip install kokoro torch"; exit 1; }
    fi

    # ── Step 2: Convert voice .pt → .npy ──────────────────────────────
    local voices_converted=0
    for voice in $KOKORO_VOICES; do
        local npy_file="$KOKORO_DIR/voices/${voice}.npy"
        if [ -f "$npy_file" ]; then
            voices_converted=$((voices_converted + 1))
        else
            if [ "$voices_converted" -eq 0 ]; then
                echo "    Converting voice .pt files → .npy..."
            fi
            python3 -c "
import os, warnings, torch, numpy as np
os.environ['TF_CPP_MIN_LOG_LEVEL'] = '3'
warnings.filterwarnings('ignore')
from huggingface_hub import hf_hub_download

voice = '$voice'
npy_path = r'''$npy_file'''
pt_path = hf_hub_download(repo_id='hexgrad/Kokoro-82M', filename=f'voices/{voice}.pt')
pack = torch.load(pt_path, weights_only=True)
np.save(npy_path, pack.numpy())
print(f'  Converted {voice}: {pack.shape} → {npy_path}')
" || warn "Failed to convert voice: $voice"
            voices_converted=$((voices_converted + 1))
        fi
    done

    ok "Kokoro TTS (ONNX) model ready at $KOKORO_DIR ($voices_converted voices)"
}

# ─── Linux: Pocket TTS (ONNX INT8) ───────────────────────────────────
#
# Source: KevinAHM/pocket-tts-onnx (ungated, CC-BY 4.0)
# Downloads INT8-quantized synthesis models (~180 MB), the tokenizer, encoder, and reference voice sample.

download_pocket_tts_linux() {
    if [ "$OS" != "Linux" ]; then
        warn "Pocket TTS ONNX is Linux-only (use MLX on macOS). Skipping."
        return 0
    fi

    info "Downloading Pocket TTS model (ONNX INT8, ~180 MB)..."
    mkdir -p "$POCKET_TTS_DIR/onnx"

    local required_files=(
        "onnx/flow_lm_main_int8.onnx"
        "onnx/flow_lm_flow_int8.onnx"
        "onnx/mimi_decoder_int8.onnx"
        "onnx/text_conditioner.onnx"
        "onnx/mimi_encoder.onnx"
        "tokenizer.model"
        "reference_sample.wav"
    )

    local missing=0
    for f in "${required_files[@]}"; do
        local fpath="$POCKET_TTS_DIR/$f"
        local fsize=0
        if [ -f "$fpath" ]; then fsize=$(file_size_bytes "$fpath"); fi
        if [ "$fsize" -gt 1000 ]; then
            ok "$f already exists, skipping."
        else
            missing=$((missing + 1))
        fi
    done

    if [ "$missing" -gt 0 ]; then
        echo "    Source: KevinAHM/pocket-tts-onnx"
        python3 -c "
from huggingface_hub import snapshot_download
snapshot_download(
    'KevinAHM/pocket-tts-onnx',
    local_dir=r'''$POCKET_TTS_DIR''',
    allow_patterns=[
        'tokenizer.model',
        'reference_sample.wav',
        'onnx/flow_lm_main_int8.onnx',
        'onnx/flow_lm_flow_int8.onnx',
        'onnx/mimi_decoder_int8.onnx',
        'onnx/text_conditioner.onnx',
        'onnx/mimi_encoder.onnx',
    ],
)
print('Download complete.')
" || { err "Pocket TTS download failed."; exit 1; }
    fi
    ok "Pocket TTS model ready at $POCKET_TTS_DIR"
}

# ─── Platform dispatch ────────────────────────────────────────────────

download_pocket_tts() {
    case "$OS" in
        Linux)  download_pocket_tts_linux ;;
        Darwin) warn "Pocket TTS ONNX is Linux-only. Skipping on macOS." ;;
        *)      err "Unsupported OS: $OS"; exit 1 ;;
    esac
}

download_kokoro() {
    case "$OS" in
        Darwin) download_kokoro_macos ;;
        Linux)  download_kokoro_linux ;;
        *)      err "Unsupported OS: $OS"; exit 1 ;;
    esac
}

download_whisper() {
    case "$OS" in
        Darwin) download_whisper_macos ;;
        Linux)  download_whisper_linux ;;
        *)      err "Unsupported OS: $OS"; exit 1 ;;
    esac
}

# ─── Status ───────────────────────────────────────────────────────────

show_status() {
    echo ""
    echo "=== Model Status ($(uname -s)/$(uname -m)) ==="

    # Kokoro TTS — macOS MLX
    if [ "$OS" = "Darwin" ] && [ -f "$KOKORO_DIR/kokoro-v1_0.safetensors" ]; then
        local fsize
        fsize=$(file_size_bytes "$KOKORO_DIR/kokoro-v1_0.safetensors")
        if [ "$fsize" -gt 1000000 ]; then
            ok "Kokoro TTS (MLX):      READY ($(dir_size_human "$KOKORO_DIR"))"
        else
            warn "Kokoro TTS (MLX):      CORRUPT (re-run download)"
        fi
    elif [ "$OS" = "Linux" ] && [ -f "$KOKORO_DIR/kokoro-v1_0.onnx" ]; then
        local fsize
        fsize=$(file_size_bytes "$KOKORO_DIR/kokoro-v1_0.onnx")
        if [ "$fsize" -gt 1000000 ]; then
            ok "Kokoro TTS (ONNX):     READY ($(dir_size_human "$KOKORO_DIR"))"
        else
            warn "Kokoro TTS (ONNX):     CORRUPT (re-run download)"
        fi
    else
        echo "      Kokoro TTS:          NOT DOWNLOADED"
    fi

    # WhisperKit STT — macOS CoreML
    if [ "$OS" = "Darwin" ]; then
        for model in $WHISPER_MODELS; do
            local wdir="$WHISPER_DIR/$model"
            if [ -d "$wdir" ]; then
                local dsize
                dsize=$(dir_size_kb "$wdir")
                if [ "$dsize" -gt 1000 ]; then
                    ok "WhisperKit STT ($model): READY ($(dir_size_human "$wdir"))"
                else
                    warn "WhisperKit STT ($model): CORRUPT (re-run download)"
                fi
            else
                echo "      WhisperKit STT ($model): NOT DOWNLOADED"
            fi
        done
    fi

    # whisper.cpp — Linux GGML
    if [ "$OS" = "Linux" ]; then
        for model in $WHISPER_GGML_MODELS; do
            local wpath="$WHISPER_GGML_DIR/$model"
            if [ -f "$wpath" ]; then
                local fsize
                fsize=$(file_size_bytes "$wpath")
                if [ "$fsize" -gt 1000000 ]; then
                    ok "whisper.cpp STT ($model): READY ($(( fsize / 1048576 ))MB)"
                else
                    warn "whisper.cpp STT ($model): CORRUPT (re-run download)"
                fi
            else
                echo "      whisper.cpp STT ($model): NOT DOWNLOADED"
            fi
        done
    fi

    # Pocket TTS — Linux ONNX
    if [ "$OS" = "Linux" ]; then
        local ptpath="$POCKET_TTS_DIR/onnx/flow_lm_main_int8.onnx"
        if [ -f "$ptpath" ]; then
            local fsize
            fsize=$(file_size_bytes "$ptpath")
            if [ "$fsize" -gt 1000000 ]; then
                ok "Pocket TTS (ONNX INT8): READY ($(dir_size_human "$POCKET_TTS_DIR"))"
            else
                warn "Pocket TTS (ONNX INT8): CORRUPT (re-run download)"
            fi
        else
            echo "      Pocket TTS:          NOT DOWNLOADED"
        fi
    fi

    echo ""
}

# ─── Pre-flight summary (for CI / Makefile) ───────────────────────────

preflight() {
    local failed=0
    echo ""
    echo "=== Build Pre-flight Check ==="

    # Python
    if command -v python3 &>/dev/null; then
        ok "python3 found ($(python3 --version 2>&1 | head -1))"
    else
        err "python3 not found"
        failed=1
    fi

    # huggingface_hub
    if python3 -c "import huggingface_hub" &>/dev/null 2>&1; then
        ok "huggingface_hub installed"
    else
        err "huggingface_hub missing (pip3 install huggingface_hub)"
        failed=1
    fi

    # macOS-specific
    if [ "$OS" = "Darwin" ]; then
        # Xcode
        if command -v xcodebuild &>/dev/null; then
            ok "Xcode CLI tools found"
        else
            err "Xcode CLI tools not found"
            failed=1
        fi

        # Metal Toolchain
        if check_metal_toolchain; then
            ok "Metal Toolchain installed"
        else
            failed=1
        fi

        # Flutter
        if command -v flutter &>/dev/null; then
            ok "Flutter found ($(flutter --version 2>&1 | head -1))"
        else
            err "Flutter not found"
            failed=1
        fi
    fi

    # Linux-specific
    if [ "$OS" = "Linux" ]; then
        if command -v flutter &>/dev/null; then
            ok "Flutter found"
        else
            err "Flutter not found"
            failed=1
        fi

        if command -v cmake &>/dev/null; then
            ok "cmake found"
        else
            warn "cmake not found (needed to build whisper.cpp)"
        fi
    fi

    show_status

    if [ "$failed" -ne 0 ]; then
        err "Pre-flight checks failed. Fix the issues above before building."
        return 1
    fi
    ok "All pre-flight checks passed."
    return 0
}

# ─── Main ─────────────────────────────────────────────────────────────

target="${1:-all}"

case "$target" in
    kokoro)
        check_huggingface
        download_kokoro
        ;;
    whisper)
        check_huggingface
        download_whisper
        ;;
    pocket-tts)
        check_huggingface
        download_pocket_tts
        ;;
    all)
        check_huggingface
        download_kokoro
        download_whisper
        download_pocket_tts
        ;;
    status)
        show_status
        exit 0
        ;;
    preflight)
        preflight
        exit $?
        ;;
    *)
        echo "Usage: $0 [kokoro|whisper|pocket-tts|all|status|preflight]"
        exit 1
        ;;
esac

show_status

if [ "$OS" = "Darwin" ]; then
    echo "Add models/ to Xcode's \"Copy Bundle Resources\" build phase,"
    echo "then run: make build"
elif [ "$OS" = "Linux" ]; then
    echo "Models ready. Run: make build"
fi
