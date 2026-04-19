# Phonegentic AI

Retro-future SIP phone with AI voice agent.

See the [root README](../README.md) for full documentation, architecture diagrams, and setup instructions.

## Themes

Three built-in themes — see the [Theme Guide](docs/THEMES.md) for color swatches, role reference, and how to add your own.

## Quick reference

```bash
cp build.env.example build.env  # one-time: create local build config
                                # edit build.env to enable features

make preflight         # verify environment (python, Metal Toolchain, etc.)
make download-models   # download ML models (~480 MB, git-ignored)
make model-status      # check model download status

make run               # run with build.env flags applied
make run-lite          # run without build.env (all flags off, cloud-only)
make build             # release build with build.env flags
make build-lite        # release build without build.env
make clean             # flutter clean
```
