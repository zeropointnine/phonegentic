#!/usr/bin/env bash
# Downloads on-device ML models for Kokoro TTS and WhisperKit STT.
# Models are stored in phonegentic/models/ (git-ignored).
#
# Usage:
#   ./scripts/download_models.sh          # download all for current platform
#   ./scripts/download_models.sh kokoro   # Kokoro TTS only
#   ./scripts/download_models.sh whisper  # WhisperKit STT only
#   ./scripts/download_models.sh status   # show model status
#
# Prerequisites: pip3 install huggingface_hub

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODELS_DIR="$PROJECT_DIR/models"

KOKORO_DIR="$MODELS_DIR/kokoro"
WHISPER_DIR="$MODELS_DIR/whisperkit"
WHISPER_GGML_DIR="$MODELS_DIR/whisper-ggml"

WHISPER_MODEL="openai_whisper-base"
WHISPER_GGML_MODEL="ggml-base.en.bin"

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
    info "Downloading WhisperKit STT model ($WHISPER_MODEL, ~140 MB)..."
    mkdir -p "$WHISPER_DIR"

    local target_dir="$WHISPER_DIR/$WHISPER_MODEL"
    local dsize=0
    if [ -d "$target_dir" ]; then
        dsize=$(dir_size_kb "$target_dir")
    fi

    if [ "$dsize" -gt 1000 ]; then
        ok "$WHISPER_MODEL already exists ($(dir_size_human "$target_dir")), skipping."
    else
        echo "    Source: argmaxinc/whisperkit-coreml"
        python3 -c "
from huggingface_hub import snapshot_download
snapshot_download(
    'argmaxinc/whisperkit-coreml',
    local_dir=r'''$WHISPER_DIR''',
    allow_patterns=['$WHISPER_MODEL/**'],
)
print('Download complete.')
"
    fi
    ok "WhisperKit STT model ready at $target_dir"
}

# ─── Linux: whisper.cpp GGML model ────────────────────────────────────

download_whisper_linux() {
    info "Downloading whisper.cpp GGML model ($WHISPER_GGML_MODEL, ~140 MB)..."
    mkdir -p "$WHISPER_GGML_DIR"

    local target="$WHISPER_GGML_DIR/$WHISPER_GGML_MODEL"
    local fsize=0
    if [ -f "$target" ]; then
        fsize=$(file_size_bytes "$target")
    fi

    if [ "$fsize" -gt 1000000 ]; then
        ok "$WHISPER_GGML_MODEL already exists ($(( fsize / 1048576 ))MB), skipping."
    else
        echo "    Source: ggerganov/whisper.cpp (HuggingFace)"
        python3 -c "
from huggingface_hub import hf_hub_download
hf_hub_download(
    'ggerganov/whisper.cpp',
    filename='$WHISPER_GGML_MODEL',
    local_dir=r'''$WHISPER_GGML_DIR''',
)
print('Download complete.')
"
    fi
    ok "whisper.cpp GGML model ready at $target"
}

# ─── Linux: Kokoro TTS (ONNX for future TTS.cpp) ─────────────────────

download_kokoro_linux() {
    info "Downloading Kokoro TTS model (ONNX, for TTS.cpp)..."
    mkdir -p "$KOKORO_DIR"

    local target="$KOKORO_DIR/kokoro-v0_19.onnx"
    local fsize=0
    if [ -f "$target" ]; then
        fsize=$(file_size_bytes "$target")
    fi

    if [ "$fsize" -gt 1000000 ]; then
        ok "kokoro-v0_19.onnx already exists ($(( fsize / 1048576 ))MB), skipping."
    else
        echo "    Source: hexgrad/Kokoro-82M (ONNX)"
        python3 -c "
from huggingface_hub import snapshot_download
snapshot_download(
    'hexgrad/Kokoro-82M',
    local_dir=r'''$KOKORO_DIR''',
    allow_patterns=['kokoro-v0_19.onnx', 'config.json', 'voices/*.bin'],
)
print('Download complete.')
"
    fi
    ok "Kokoro TTS (ONNX) model ready at $KOKORO_DIR"
}

# ─── Platform dispatch ────────────────────────────────────────────────

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
    elif [ "$OS" = "Linux" ] && [ -f "$KOKORO_DIR/kokoro-v0_19.onnx" ]; then
        local fsize
        fsize=$(file_size_bytes "$KOKORO_DIR/kokoro-v0_19.onnx")
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
        local wdir="$WHISPER_DIR/$WHISPER_MODEL"
        if [ -d "$wdir" ]; then
            local dsize
            dsize=$(dir_size_kb "$wdir")
            if [ "$dsize" -gt 1000 ]; then
                ok "WhisperKit STT (CoreML): READY ($(dir_size_human "$wdir"))"
            else
                warn "WhisperKit STT (CoreML): CORRUPT (re-run download)"
            fi
        else
            echo "      WhisperKit STT:      NOT DOWNLOADED"
        fi
    fi

    # whisper.cpp — Linux GGML
    if [ "$OS" = "Linux" ]; then
        local wpath="$WHISPER_GGML_DIR/$WHISPER_GGML_MODEL"
        if [ -f "$wpath" ]; then
            local fsize
            fsize=$(file_size_bytes "$wpath")
            if [ "$fsize" -gt 1000000 ]; then
                ok "whisper.cpp STT (GGML): READY ($(( fsize / 1048576 ))MB)"
            else
                warn "whisper.cpp STT (GGML): CORRUPT (re-run download)"
            fi
        else
            echo "      whisper.cpp STT:     NOT DOWNLOADED"
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
    all)
        check_huggingface
        download_kokoro
        download_whisper
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
        echo "Usage: $0 [kokoro|whisper|all|status|preflight]"
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
