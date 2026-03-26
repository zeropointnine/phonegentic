import 'package:flutter/services.dart';

class AudioDevice {
  final int id;
  final String name;
  final String type;
  final bool isDefaultInput;
  final bool isDefaultOutput;
  final String uid;
  final String manufacturer;
  final String transportType;

  const AudioDevice({
    required this.id,
    required this.name,
    required this.type,
    required this.isDefaultInput,
    required this.isDefaultOutput,
    required this.uid,
    required this.manufacturer,
    required this.transportType,
  });

  bool get isInput => type == 'input' || type == 'both';
  bool get isOutput => type == 'output' || type == 'both';

  factory AudioDevice.fromMap(Map<dynamic, dynamic> map) {
    return AudioDevice(
      id: map['id'] as int,
      name: map['name'] as String,
      type: map['type'] as String,
      isDefaultInput: map['isDefaultInput'] as bool? ?? false,
      isDefaultOutput: map['isDefaultOutput'] as bool? ?? false,
      uid: map['uid'] as String? ?? '',
      manufacturer: map['manufacturer'] as String? ?? '',
      transportType: map['transportType'] as String? ?? 'unknown',
    );
  }
}

class AudioDeviceService {
  static const _channel = MethodChannel('com.agentic_ai/audio_devices');

  static Future<List<AudioDevice>> getAudioDevices() async {
    final List<dynamic> result =
        await _channel.invokeMethod('getAudioDevices');
    return result
        .cast<Map<dynamic, dynamic>>()
        .map(AudioDevice.fromMap)
        .toList();
  }

  static Future<void> setDefaultInputDevice(int deviceId) async {
    await _channel.invokeMethod('setDefaultInputDevice', {
      'deviceId': deviceId,
    });
  }

  static Future<void> setDefaultOutputDevice(int deviceId) async {
    await _channel.invokeMethod('setDefaultOutputDevice', {
      'deviceId': deviceId,
    });
  }
}
