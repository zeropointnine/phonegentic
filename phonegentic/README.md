# Phonegentic AI

Retro-future SIP phone with AI voice agent.

See the [root README](../README.md) for full documentation, architecture diagrams, and setup instructions.

## Themes

Three built-in themes — see the [Theme Guide](docs/THEMES.md) for color swatches, role reference, and how to add your own.

## Quick reference

```bash
make preflight         # verify environment (python, Metal Toolchain, etc.)
make download-models   # download ML models (~480 MB, git-ignored)
make model-status      # check model download status

make run               # run with on-device models enabled
make run-lite          # run without on-device models (cloud-only)
make build             # release build with on-device models
make build-lite        # release build without on-device models
make clean             # flutter clean
```
