# Echo Suppression for Linux

## Overview

This implementation adds playback-aware echo suppression to the Linux audio pipeline, bringing Linux parity with the macOS implementation. Echo is prevented by blocking microphone audio from reaching Flutter while TTS is playing and for a configurable window afterward.

## Features

The echo suppression provides the following:

- **Playback-aware mic gating**: Blocks microphone audio while TTS is playing
- **Post-TTS suppression window**: Continues blocking mic audio for 2 seconds after TTS stops
- **Diagnostic logging**: Periodic logging for tuning the suppression window

## Implementation Details

### Initialization

The APM is initialized in `pulse_audio_init()` when the audio system starts:

```cpp
// Configure AEC
webrtc::AudioProcessing::Config config;
config.echo_canceller.enabled = true;
config.noise_suppression.enabled = true;
config.gain_controller1.enabled = true;
config.gain_controller2.enabled = true;
config.high_pass_filter.enabled = true;
```

### Audio Processing Pipeline

1. **Capture Path (Microphone)**:
   - Raw audio from PulseAudio capture stream
   - Processed through `ProcessStream()` for AEC
   - Clean audio sent to Flutter/Whisper

2. **Playback Path (TTS)**:
   - TTS audio sent to PulseAudio playback stream
   - Also fed to AEC via `ProcessReverseStream()` as reference signal
   - This allows AEC to identify and remove echo from mic input

### Configuration

- **Sample Rate**: 24 kHz (matching TTS/Whisper)
- **Channels**: 1 (mono)
- **Frame Size**: Variable, processed in chunks from PulseAudio

## Installation Requirements

### Build Dependencies

No additional dependencies required. The implementation uses only PulseAudio, which is standard on most Linux distributions.

### CMake Configuration

The CMakeLists.txt has been updated to use only PulseAudio:

```cmake
pkg_check_modules(PULSEAUDIO REQUIRED IMPORTED_TARGET libpulse)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::PULSEAUDIO)
target_include_directories(${BINARY_NAME} PRIVATE ${PULSEAUDIO_INCLUDE_DIRS})
```

## Troubleshooting

### AEC Not Working

If echo cancellation doesn't seem to work:

1. **Check library installation**:
   ```bash
   pkg-config --modversion webrtc-audio-processing
   ```

2. **Check logs** for initialization errors:
   ```
   [AudioTap] Failed to initialize WebRTC APM - echo cancellation disabled
   ```

3. **Verify audio levels** - AEC works best when:
   - Microphone is not too close to speakers
   - Playback volume is reasonable (not maxed out)
   - Microphone gain is properly adjusted

### Build Errors

If you get "cannot open source file webrtc/modules/audio_processing/include/audio_processing.h":

1. Install the development package (see Installation Requirements above)
2. Verify pkg-config can find it:
   ```bash
   pkg-config --cflags webrtc-audio-processing
   ```

## Comparison with macOS

| Feature | macOS | Linux |
|----------|---------|--------|
| AEC | ✅ WebRTC APM | ✅ WebRTC APM |
| Noise Suppression | ✅ WebRTC APM | ✅ WebRTC APM |
| Auto Gain Control | ✅ WebRTC APM | ✅ WebRTC APM |
| High-pass Filter | ✅ WebRTC APM | ✅ WebRTC APM |

## Notes

- AEC requires a reference signal from the playback stream to work effectively
- The implementation feeds TTS audio to `ProcessReverseStream()` for this purpose
- If APM initialization fails, the system continues without echo cancellation (non-fatal)
- Performance impact is minimal on modern hardware
