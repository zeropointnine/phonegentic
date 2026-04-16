import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RingtoneInfo {
  final String assetPath;
  final String displayName;
  const RingtoneInfo(this.assetPath, this.displayName);
}

class RingtoneService extends ChangeNotifier {
  static const _ringEnabledKey = 'agent_ring_enabled';
  static const _ringtoneKey = 'agent_ringtone';
  static const _autoAnswerKey = 'agent_auto_answer';

  static const bundledRingtones = <RingtoneInfo>[
    RingtoneInfo(
      'assets/80s_digital_telephon_4-1776301525611.wav',
      '80s Digital',
    ),
    RingtoneInfo(
      'assets/80s_telephone_ring_3-1776301545127.wav',
      '80s Classic',
    ),
    RingtoneInfo(
      'assets/old_fashioned_paypho_2-1776301537305.wav',
      'Payphone',
    ),
  ];

  bool _ringEnabled = true;
  String _selectedRingtone = bundledRingtones.first.assetPath;
  bool _agentAutoAnswer = false;
  bool _loaded = false;

  AudioPlayer? _player;
  bool _ringing = false;

  /// Custom ringtone file paths stored in app documents.
  final List<RingtoneInfo> _customRingtones = [];

  bool get ringEnabled => _ringEnabled;
  String get selectedRingtone => _selectedRingtone;
  bool get agentAutoAnswer => _agentAutoAnswer;
  bool get isRinging => _ringing;

  List<RingtoneInfo> get availableRingtones => [
        ...bundledRingtones,
        ..._customRingtones,
      ];

  String displayNameFor(String path) {
    for (final r in availableRingtones) {
      if (r.assetPath == path) return r.displayName;
    }
    return p.basenameWithoutExtension(path);
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    _ringEnabled = prefs.getBool(_ringEnabledKey) ?? true;
    _selectedRingtone =
        prefs.getString(_ringtoneKey) ?? bundledRingtones.first.assetPath;
    _agentAutoAnswer = prefs.getBool(_autoAnswerKey) ?? false;
    await _loadCustomRingtones();
    notifyListeners();
  }

  Future<void> toggleRing() async {
    _ringEnabled = !_ringEnabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_ringEnabledKey, _ringEnabled);
    notifyListeners();
  }

  Future<void> setRingtone(String assetPath) async {
    _selectedRingtone = assetPath;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ringtoneKey, assetPath);
    notifyListeners();
  }

  Future<void> toggleAutoAnswer() async {
    _agentAutoAnswer = !_agentAutoAnswer;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoAnswerKey, _agentAutoAnswer);
    notifyListeners();
  }

  Future<void> startRinging() async {
    if (_ringing || !_ringEnabled) return;
    _ringing = true;
    notifyListeners();

    try {
      _player ??= AudioPlayer();
      final isCustom = !bundledRingtones.any((r) => r.assetPath == _selectedRingtone);
      if (isCustom) {
        await _player!.setFilePath(_selectedRingtone);
      } else {
        await _player!.setAsset(_selectedRingtone);
      }
      await _player!.setLoopMode(LoopMode.one);
      await _player!.setVolume(1.0);
      _player!.play();
    } catch (e) {
      debugPrint('[RingtoneService] Failed to start ringing: $e');
      _ringing = false;
      notifyListeners();
    }
  }

  Future<void> stopRinging() async {
    if (!_ringing) return;
    _ringing = false;
    notifyListeners();
    try {
      await _player?.stop();
    } catch (e) {
      debugPrint('[RingtoneService] Failed to stop ringing: $e');
    }
  }

  /// Preview a ringtone briefly (plays once without looping).
  Future<void> preview(String assetPath) async {
    try {
      _player ??= AudioPlayer();
      await _player!.stop();
      final isCustom = !bundledRingtones.any((r) => r.assetPath == assetPath);
      if (isCustom) {
        await _player!.setFilePath(assetPath);
      } else {
        await _player!.setAsset(assetPath);
      }
      await _player!.setLoopMode(LoopMode.off);
      await _player!.setVolume(1.0);
      _player!.play();
    } catch (e) {
      debugPrint('[RingtoneService] Failed to preview: $e');
    }
  }

  Future<void> stopPreview() async {
    try {
      await _player?.stop();
    } catch (_) {}
  }

  Future<void> pickCustomRingtone() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['wav', 'mp3', 'aac', 'm4a'],
    );
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.first;
    if (picked.path == null) return;

    final dir = await getApplicationDocumentsDirectory();
    final ringDir = Directory(p.join(dir.path, 'phonegentic', 'ringtones'));
    await ringDir.create(recursive: true);

    final dest = p.join(ringDir.path, picked.name);
    await File(picked.path!).copy(dest);

    _customRingtones.add(RingtoneInfo(dest, p.basenameWithoutExtension(picked.name)));
    _selectedRingtone = dest;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ringtoneKey, dest);
    notifyListeners();
  }

  Future<void> _loadCustomRingtones() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final ringDir = Directory(p.join(dir.path, 'phonegentic', 'ringtones'));
      if (!await ringDir.exists()) return;
      final files = ringDir.listSync().whereType<File>();
      for (final f in files) {
        _customRingtones.add(RingtoneInfo(
          f.path,
          p.basenameWithoutExtension(f.path),
        ));
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }
}
