# Linux Audio Device Support

This directory contains the implementation of audio device enumeration for Linux, supporting both PulseAudio and PipeWire (via PulseAudio compatibility layer).

## Prerequisites

### Build Dependencies

Install the required development packages:

```bash
# Debian/Ubuntu/Linux Mint
sudo apt-get install libpulse-dev pkg-config

# Fedora/RHEL
sudo dnf install pulseaudio-libs-devel pkg-config

# Arch Linux
sudo pacman -S libpulse pkg-config
```

### Runtime Dependencies

The application requires the PulseAudio client library at runtime. On systems using PipeWire (like Linux Mint Cinnamon), the PipeWire PulseAudio compatibility layer provides this:

```bash
# Debian/Ubuntu/Linux Mint
sudo apt-get install libpulse0 pipewire-pulse

# Fedora/RHEL
sudo dnf install pipewire-pulseaudio

# Arch Linux
sudo pacman -S pipewire-pulse
```

## Building

From the project root directory:

```bash
cd phonegentic
flutter build linux
```

## Running

```bash
flutter run -d linux
```

## How It Works

The implementation uses the PulseAudio API to enumerate audio devices:

1. **Output Devices (Sinks)**: Retrieved via `pa_context_get_sink_info_list()`
2. **Input Devices (Sources)**: Retrieved via `pa_context_get_source_info_list()`
3. **Default Devices**: Identified by comparing device names with the system defaults
4. **Transport Type Detection**: Analyzes device properties to determine if a device is USB, Bluetooth, built-in, or HDMI

### PipeWire Compatibility

PipeWire provides a PulseAudio compatibility layer (`pipewire-pulse`), so this implementation works seamlessly with both audio systems without requiring any code changes.

## Architecture

```
Dart Layer
├── audio_device_service.dart
└── audio_device_sheet.dart
         ↓ MethodChannel: com.agentic_ai/audio_devices
Native Layer (C++)
├── audio_device_channel.h
├── audio_device_channel.cc
└── my_application.cc
         ↓ PulseAudio API
Audio Subsystem
├── PulseAudio (legacy)
└── PipeWire (modern, with PulseAudio compatibility)
```

## Troubleshooting

### "Could not load audio devices" Error

If you see this error, check:

1. **PulseAudio/PipeWire is running**:
   ```bash
   pactl info  # For PulseAudio
   # or
   pw-cli info  # For PipeWire
   ```

2. **Development libraries are installed**:
   ```bash
   pkg-config --modversion libpulse
   ```

3. **Application has audio permissions**: Ensure the application can access the audio system.

### Build Errors

If you encounter build errors related to PulseAudio:

```bash
# Verify PulseAudio development headers are installed
dpkg -l | grep libpulse-dev

# Check pkg-config can find PulseAudio
pkg-config --cflags --libs libpulse
```

## Files Modified

- [`audio_device_channel.h`](audio_device_channel.h) - Header file for the audio device channel
- [`audio_device_channel.cc`](audio_device_channel.cc) - Implementation using PulseAudio API
- [`CMakeLists.txt`](CMakeLists.txt) - Build configuration with PulseAudio dependencies
- [`my_application.cc`](my_application.cc) - Application initialization with channel registration

## Testing

To test the audio device enumeration:

1. Build and run the application
2. Open the Audio Devices bottom sheet
3. Verify that:
   - Output devices are listed in the "Output" tab
   - Input devices are listed in the "Input" tab
   - Default devices are marked with a checkmark
   - Switching between devices works correctly

## Future Enhancements

- Direct PipeWire API support for better integration
- Device hotplug notifications via event channels
- Volume control and mute functionality
- More detailed device information
