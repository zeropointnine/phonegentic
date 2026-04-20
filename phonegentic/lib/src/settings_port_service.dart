import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'agent_config_service.dart';
import 'conference/conference_config.dart';
import 'db/call_history_db.dart';
import 'models/inbound_call_flow.dart';
import 'models/job_function.dart';
import 'settings_crypto.dart';
import 'user_config_service.dart';

enum ExportFormat { json, zip, tar }

enum SettingsSection {
  sipSettings,
  agentSettings,
  jobFunctions,
  inboundWorkflows,
}

extension SettingsSectionLabel on SettingsSection {
  String get label {
    switch (this) {
      case SettingsSection.sipSettings:
        return 'sip_settings';
      case SettingsSection.agentSettings:
        return 'agent_settings';
      case SettingsSection.jobFunctions:
        return 'job_functions';
      case SettingsSection.inboundWorkflows:
        return 'inbound_workflows';
    }
  }

  String get displayName {
    switch (this) {
      case SettingsSection.sipSettings:
        return 'SIP Settings';
      case SettingsSection.agentSettings:
        return 'Agent Settings';
      case SettingsSection.jobFunctions:
        return 'Job Functions';
      case SettingsSection.inboundWorkflows:
        return 'Inbound Workflows';
    }
  }
}

class SettingsPortService {
  SettingsPortService._();

  // ---------------------------------------------------------------------------
  // Export
  // ---------------------------------------------------------------------------

  static Future<File?> exportSection(
    SettingsSection section,
    ExportFormat format,
    BuildContext context,
  ) async {
    final data = await _gatherData(section);
    final envelope = {
      'app': 'phonegentic',
      'version': 1,
      'section': section.label,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'data': data,
    };
    final rawJsonBytes =
        utf8.encode(const JsonEncoder.withIndent('  ').convert(envelope));

    final outputBytes = await _maybeEncrypt(rawJsonBytes, context);
    if (outputBytes == null) return null;

    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final baseName = 'phonegentic_${section.label}_$timestamp';

    final downloadsDir = await getDownloadsDirectory();
    if (downloadsDir == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not access Downloads folder'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return null;
    }

    File outputFile;
    switch (format) {
      case ExportFormat.json:
        outputFile = File('${downloadsDir.path}/$baseName.json');
        await outputFile.writeAsBytes(outputBytes);
        break;
      case ExportFormat.zip:
        final archive = Archive();
        archive.addFile(ArchiveFile('$baseName.json', outputBytes.length,
            Uint8List.fromList(outputBytes)));
        final encoded = ZipEncoder().encode(archive);
        outputFile = File('${downloadsDir.path}/$baseName.zip');
        await outputFile.writeAsBytes(encoded);
        break;
      case ExportFormat.tar:
        final archive = Archive();
        archive.addFile(ArchiveFile('$baseName.json', outputBytes.length,
            Uint8List.fromList(outputBytes)));
        final tarBytes = TarEncoder().encode(archive);
        final gzBytes = GZipEncoder().encode(tarBytes);
        outputFile = File('${downloadsDir.path}/$baseName.tar.gz');
        await outputFile.writeAsBytes(gzBytes);
        break;
    }

    await Process.run('open', [downloadsDir.path]);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Exported ${section.displayName} to Downloads'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    return outputFile;
  }

  // ---------------------------------------------------------------------------
  // Export all (full backup)
  // ---------------------------------------------------------------------------

  static Future<File?> exportAll(
    ExportFormat format,
    BuildContext context,
  ) async {
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final baseName = 'phonegentic_all_settings_$timestamp';

    final downloadsDir = await getDownloadsDirectory();
    if (downloadsDir == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not access Downloads folder'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return null;
    }

    // Ask once whether to encrypt the entire backup
    if (!context.mounted) return null;
    final password = await _askExportPassword(context);

    final archive = Archive();
    for (final section in SettingsSection.values) {
      final data = await _gatherData(section);
      final envelope = {
        'app': 'phonegentic',
        'version': 1,
        'section': section.label,
        'exported_at': DateTime.now().toUtc().toIso8601String(),
        'data': data,
      };
      final rawJsonBytes = utf8
          .encode(const JsonEncoder.withIndent('  ').convert(envelope));

      List<int> fileBytes;
      if (password != null) {
        final encrypted = await SettingsCrypto.encrypt(
          Uint8List.fromList(rawJsonBytes),
          password,
        );
        fileBytes = utf8
            .encode(const JsonEncoder.withIndent('  ').convert(encrypted));
      } else {
        fileBytes = rawJsonBytes;
      }

      archive.addFile(ArchiveFile(
        '${section.label}.json',
        fileBytes.length,
        Uint8List.fromList(fileBytes),
      ));
    }

    File outputFile;
    switch (format) {
      case ExportFormat.json:
      case ExportFormat.zip:
        final encoded = ZipEncoder().encode(archive);
        outputFile = File('${downloadsDir.path}/$baseName.zip');
        await outputFile.writeAsBytes(encoded);
        break;
      case ExportFormat.tar:
        final tarBytes = TarEncoder().encode(archive);
        final gzBytes = GZipEncoder().encode(tarBytes);
        outputFile = File('${downloadsDir.path}/$baseName.tar.gz');
        await outputFile.writeAsBytes(gzBytes);
        break;
    }

    await Process.run('open', [downloadsDir.path]);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Exported all settings to Downloads'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    return outputFile;
  }

  // ---------------------------------------------------------------------------
  // Import all (full restore)
  // ---------------------------------------------------------------------------

  static Future<bool> importAll(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip', 'gz', 'tar'],
    );
    if (result == null ||
        result.files.isEmpty ||
        result.files.first.path == null) {
      return false;
    }

    final file = File(result.files.first.path!);
    final bytes = await file.readAsBytes();

    Archive? arch;
    try {
      if (file.path.endsWith('.zip')) {
        arch = ZipDecoder().decodeBytes(bytes);
      } else if (file.path.endsWith('.tar.gz') || file.path.endsWith('.gz')) {
        arch = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
      } else if (file.path.endsWith('.tar')) {
        arch = TarDecoder().decodeBytes(bytes);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to read archive: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return false;
    }

    if (arch == null || arch.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Archive is empty or unreadable'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return false;
    }

    // Parse each JSON inside the archive, handling encrypted entries
    final sectionData = <String, Map<String, dynamic>>{};
    String? cachedPassword;
    bool passwordPrompted = false;

    for (final entry in arch) {
      if (!entry.name.endsWith('.json')) continue;
      try {
        var envelope =
            jsonDecode(utf8.decode(entry.content as List<int>))
                as Map<String, dynamic>;

        if (SettingsCrypto.isEncrypted(envelope)) {
          if (!passwordPrompted) {
            if (!context.mounted) return false;
            cachedPassword = await _askImportPassword(context);
            passwordPrompted = true;
            if (cachedPassword == null || cachedPassword.isEmpty) return false;
          }
          try {
            final plainBytes =
                await SettingsCrypto.decrypt(envelope, cachedPassword!);
            envelope =
                jsonDecode(utf8.decode(plainBytes)) as Map<String, dynamic>;
          } catch (_) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Decryption failed — wrong password or corrupted file',
                  ),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
            return false;
          }
        }

        if (envelope['app'] != 'phonegentic') continue;
        final section = envelope['section'] as String?;
        if (section != null) {
          sectionData[section] = envelope['data'] as Map<String, dynamic>;
        }
      } catch (_) {
        // skip malformed entries
      }
    }

    if (sectionData.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No valid settings found in archive'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return false;
    }

    final sectionNames =
        sectionData.keys.map((k) {
          final match = SettingsSection.values.where((s) => s.label == k);
          return match.isNotEmpty ? match.first.displayName : k;
        }).join(', ');

    final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Import All Settings?'),
            content: Text(
              'This will replace the following with imported values:\n\n'
              '$sectionNames\n\n'
              'Contacts and call history are not affected. '
              'This cannot be undone.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Import'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return false;

    // Apply in dependency order: job functions before inbound workflows
    const applyOrder = [
      'sip_settings',
      'agent_settings',
      'job_functions',
      'inbound_workflows',
    ];

    try {
      for (final key in applyOrder) {
        if (!sectionData.containsKey(key)) continue;
        final section =
            SettingsSection.values.firstWhere((s) => s.label == key);
        await _applyData(section, sectionData[key]!);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Import failed: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return false;
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('All settings imported successfully'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // Import (single section)
  // ---------------------------------------------------------------------------

  static Future<bool> importSection(
    SettingsSection section,
    BuildContext context,
  ) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json', 'zip', 'gz', 'tar'],
    );
    if (result == null || result.files.isEmpty || result.files.first.path == null) {
      return false;
    }

    final file = File(result.files.first.path!);
    final bytes = await file.readAsBytes();

    Map<String, dynamic> envelope;
    try {
      envelope = _decodeFile(bytes, file.path);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to read file: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return false;
    }

    // Handle encrypted single-section files
    if (SettingsCrypto.isEncrypted(envelope)) {
      final decrypted = await _maybeDecrypt(envelope, context);
      if (decrypted == null) return false;
      envelope = decrypted;
    }

    if (envelope['app'] != 'phonegentic') {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Not a Phonegentic settings file'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return false;
    }

    final fileSection = envelope['section'] as String?;
    if (fileSection != section.label) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Wrong section: file contains "$fileSection" but expected "${section.label}"'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return false;
    }

    final confirmed = await _confirmImport(context, section);
    if (!confirmed) return false;

    try {
      await _applyData(section, envelope['data'] as Map<String, dynamic>);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Import failed: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return false;
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Imported ${section.displayName} successfully'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // File decoding (JSON / ZIP / TAR)
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> _decodeFile(Uint8List bytes, String path) {
    if (path.endsWith('.json')) {
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    }

    Archive? archive;
    if (path.endsWith('.zip')) {
      archive = ZipDecoder().decodeBytes(bytes);
    } else if (path.endsWith('.tar.gz') || path.endsWith('.gz')) {
      final decompressed = GZipDecoder().decodeBytes(bytes);
      archive = TarDecoder().decodeBytes(decompressed);
    } else if (path.endsWith('.tar')) {
      archive = TarDecoder().decodeBytes(bytes);
    }

    if (archive != null) {
      for (final file in archive) {
        if (file.name.endsWith('.json')) {
          return jsonDecode(utf8.decode(file.content as List<int>))
              as Map<String, dynamic>;
        }
      }
      throw const FormatException('No JSON file found inside archive');
    }

    // Try parsing as raw JSON as fallback
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  // ---------------------------------------------------------------------------
  // Password dialogs for encryption
  // ---------------------------------------------------------------------------

  /// Shows a password dialog for export. Returns the password, or `null` to
  /// skip encryption (plaintext export).
  static Future<String?> _askExportPassword(BuildContext context) async {
    final controller = TextEditingController();
    final confirmController = TextEditingController();
    String? error;

    final password = await showDialog<String?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Encrypt export?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Enter a password to encrypt sensitive data. '
                'You will need this password to import the file later.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: confirmController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Confirm password',
                  border: const OutlineInputBorder(),
                  errorText: error,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Skip (no encryption)'),
            ),
            TextButton(
              onPressed: () {
                final pw = controller.text;
                if (pw.isEmpty) {
                  setState(() => error = 'Password cannot be empty');
                  return;
                }
                if (pw != confirmController.text) {
                  setState(() => error = 'Passwords do not match');
                  return;
                }
                Navigator.of(ctx).pop(pw);
              },
              child: const Text('Encrypt'),
            ),
          ],
        ),
      ),
    );

    controller.dispose();
    confirmController.dispose();
    return password;
  }

  /// Shows a password dialog for importing encrypted files.
  /// Returns the password, or `null` if the user cancels.
  static Future<String?> _askImportPassword(BuildContext context) async {
    final controller = TextEditingController();

    final password = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Encrypted file'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'This settings file is encrypted. '
              'Enter the password that was used during export.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Password',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Decrypt'),
          ),
        ],
      ),
    );

    controller.dispose();
    return password;
  }

  /// Optionally encrypt [jsonBytes] based on user choice.
  /// Returns the bytes to write to disk (either encrypted envelope or original).
  static Future<List<int>?> _maybeEncrypt(
    List<int> jsonBytes,
    BuildContext context,
  ) async {
    if (!context.mounted) return jsonBytes;
    final password = await _askExportPassword(context);
    if (password == null) return jsonBytes; // plaintext

    final envelope = await SettingsCrypto.encrypt(
      Uint8List.fromList(jsonBytes),
      password,
    );
    return utf8.encode(const JsonEncoder.withIndent('  ').convert(envelope));
  }

  /// If [envelope] is encrypted, prompt for password and decrypt.
  /// Returns the decrypted envelope, or `null` on cancel / failure.
  static Future<Map<String, dynamic>?> _maybeDecrypt(
    Map<String, dynamic> envelope,
    BuildContext context,
  ) async {
    if (!SettingsCrypto.isEncrypted(envelope)) return envelope;

    if (!context.mounted) return null;
    final password = await _askImportPassword(context);
    if (password == null || password.isEmpty) return null;

    try {
      final plainBytes = await SettingsCrypto.decrypt(envelope, password);
      return jsonDecode(utf8.decode(plainBytes)) as Map<String, dynamic>;
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Decryption failed — wrong password or corrupted file',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Confirmation dialog
  // ---------------------------------------------------------------------------

  static Future<bool> _confirmImport(
      BuildContext context, SettingsSection section) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Import ${section.displayName}?'),
            content: const Text(
                'This will replace your current settings with the imported ones. This cannot be undone.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Import'),
              ),
            ],
          ),
        ) ??
        false;
  }

  // ---------------------------------------------------------------------------
  // Data gathering (export)
  // ---------------------------------------------------------------------------

  static Future<Map<String, dynamic>> _gatherData(
      SettingsSection section) async {
    switch (section) {
      case SettingsSection.sipSettings:
        return _gatherSip();
      case SettingsSection.agentSettings:
        return _gatherAgent();
      case SettingsSection.jobFunctions:
        return _gatherJobFunctions();
      case SettingsSection.inboundWorkflows:
        return _gatherInboundWorkflows();
    }
  }

  static Future<Map<String, dynamic>> _gatherSip() async {
    final prefs = await SharedPreferences.getInstance();
    final conf = await AgentConfigService.loadConferenceConfig();
    return {
      'port': prefs.getString('port') ?? '',
      'ws_uri': prefs.getString('ws_uri') ?? '',
      'sip_uri': prefs.getString('sip_uri') ?? '',
      'display_name': prefs.getString('display_name') ?? '',
      'password': prefs.getString('password') ?? '',
      'auth_user': prefs.getString('auth_user') ?? '',
      'require_hd_codecs': prefs.getBool('require_hd_codecs') ?? false,
      'conference': {
        'provider': conf.provider.index,
        'basic_supports_update': conf.basicSupportsUpdate,
        'basic_renegotiate_media': conf.basicRenegotiateMedia,
      },
    };
  }

  static Future<Map<String, dynamic>> _gatherAgent() async {
    final voice = await AgentConfigService.loadVoiceConfig();
    final text = await AgentConfigService.loadTextConfig();
    final tts = await AgentConfigService.loadTtsConfig();
    final stt = await AgentConfigService.loadSttConfig();
    final rec = await AgentConfigService.loadCallRecordingConfig();
    final mute = await AgentConfigService.loadMutePolicy();
    final cn = await AgentConfigService.loadComfortNoiseConfig();
    final mgr = await UserConfigService.loadAgentManagerConfig();
    return {
      'voice': {
        'enabled': voice.enabled,
        'api_key': voice.apiKey,
        'model': voice.model,
        'voice': voice.voice,
        'instructions': voice.instructions,
        'target': voice.target.index,
        'echo_guard_ms': voice.echoGuardMs,
      },
      'text': {
        'enabled': text.enabled,
        'provider': text.provider.index,
        'openai_api_key': text.openaiApiKey,
        'claude_api_key': text.claudeApiKey,
        'openai_model': text.openaiModel,
        'claude_model': text.claudeModel,
        'custom_api_key': text.customApiKey,
        'custom_endpoint_url': text.customEndpointUrl,
        'custom_model': text.customModel,
        'system_prompt': text.systemPrompt,
      },
      'tts': {
        'provider': tts.provider.index,
        'elevenlabs_api_key': tts.elevenLabsApiKey,
        'elevenlabs_voice_id': tts.elevenLabsVoiceId,
        'elevenlabs_model_id': tts.elevenLabsModelId,
        'kokoro_voice_style': tts.kokoroVoiceStyle,
      },
      'stt': {
        'provider': stt.provider.index,
        'whisperkit_model_size': stt.whisperKitModelSize,
        'whisperkit_use_gpu': stt.whisperKitUseGpu,
      },
      'recording': {
        'auto_record': rec.autoRecord,
      },
      'mute_policy': mute.index,
      'comfort_noise': {
        'enabled': cn.enabled,
        'volume': cn.volume,
        'selected_path': cn.selectedPath,
      },
      'manager': {
        'phone_number': mgr.phoneNumber,
        'name': mgr.name,
        'brand_name': mgr.brandName,
        'brand_website': mgr.brandWebsite,
      },
    };
  }

  static Future<Map<String, dynamic>> _gatherJobFunctions() async {
    final rows = await CallHistoryDb.getAllJobFunctions();
    final items = rows.map((r) => JobFunction.fromMap(r)).toList();
    final prefs = await SharedPreferences.getInstance();
    final selectedId = prefs.getInt('agent_job_function_id');
    String? selectedTitle;
    if (selectedId != null) {
      final match = items.where((j) => j.id == selectedId);
      if (match.isNotEmpty) selectedTitle = match.first.title;
    }
    return {
      'selected_title': selectedTitle,
      'items': items.map((jf) {
        final m = jf.toMap();
        m.remove('id');
        return m;
      }).toList(),
    };
  }

  static Future<Map<String, dynamic>> _gatherInboundWorkflows() async {
    final rows = await CallHistoryDb.getAllInboundCallFlows();
    final flows = rows.map((r) => InboundCallFlow.fromMap(r)).toList();
    final jfRows = await CallHistoryDb.getAllJobFunctions();
    final jfItems = jfRows.map((r) => JobFunction.fromMap(r)).toList();

    // Replace numeric job_function_id with title for portability
    return {
      'items': flows.map((f) {
        final rulesExport = f.rules.map((r) {
          final jfMatch = jfItems.where((j) => j.id == r.jobFunctionId);
          return {
            'job_function_title': jfMatch.isNotEmpty ? jfMatch.first.title : null,
            'job_function_id': r.jobFunctionId,
            'phone_patterns': r.phonePatterns,
          };
        }).toList();
        return {
          'name': f.name,
          'enabled': f.enabled,
          'rules': rulesExport,
        };
      }).toList(),
    };
  }

  // ---------------------------------------------------------------------------
  // Data application (import)
  // ---------------------------------------------------------------------------

  static Future<void> _applyData(
      SettingsSection section, Map<String, dynamic> data) async {
    switch (section) {
      case SettingsSection.sipSettings:
        await _applySip(data);
        break;
      case SettingsSection.agentSettings:
        await _applyAgent(data);
        break;
      case SettingsSection.jobFunctions:
        await _applyJobFunctions(data);
        break;
      case SettingsSection.inboundWorkflows:
        await _applyInboundWorkflows(data);
        break;
    }
  }

  static Future<void> _applySip(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('port', data['port'] as String? ?? '');
    await prefs.setString('ws_uri', data['ws_uri'] as String? ?? '');
    await prefs.setString('sip_uri', data['sip_uri'] as String? ?? '');
    await prefs.setString('display_name', data['display_name'] as String? ?? '');
    await prefs.setString('password', data['password'] as String? ?? '');
    await prefs.setString('auth_user', data['auth_user'] as String? ?? '');
    await prefs.setBool(
        'require_hd_codecs', data['require_hd_codecs'] as bool? ?? false);

    final conf = data['conference'] as Map<String, dynamic>?;
    if (conf != null) {
      final providerIdx = conf['provider'] as int? ?? 0;
      await AgentConfigService.saveConferenceConfig(ConferenceConfig(
        provider: ConferenceProviderType
            .values[providerIdx.clamp(0, ConferenceProviderType.values.length - 1)],
        basicSupportsUpdate: conf['basic_supports_update'] as bool? ?? false,
        basicRenegotiateMedia: conf['basic_renegotiate_media'] as bool? ?? false,
      ));
    }
  }

  static Future<void> _applyAgent(Map<String, dynamic> data) async {
    final v = data['voice'] as Map<String, dynamic>? ?? {};
    await AgentConfigService.saveVoiceConfig(VoiceAgentConfig(
      enabled: v['enabled'] as bool? ?? false,
      apiKey: v['api_key'] as String? ?? '',
      model: v['model'] as String? ?? 'gpt-4o-mini-realtime-preview',
      voice: v['voice'] as String? ?? 'coral',
      instructions: v['instructions'] as String? ?? '',
      target: TranscriptionTarget
          .values[(v['target'] as int? ?? 0).clamp(0, TranscriptionTarget.values.length - 1)],
      echoGuardMs: v['echo_guard_ms'] as int? ?? 2500,
    ));

    final t = data['text'] as Map<String, dynamic>? ?? {};
    await AgentConfigService.saveTextConfig(TextAgentConfig(
      enabled: t['enabled'] as bool? ?? false,
      provider: TextAgentProvider
          .values[(t['provider'] as int? ?? 0).clamp(0, TextAgentProvider.values.length - 1)],
      openaiApiKey: t['openai_api_key'] as String? ?? '',
      claudeApiKey: t['claude_api_key'] as String? ?? '',
      openaiModel: t['openai_model'] as String? ?? 'gpt-4o',
      claudeModel: t['claude_model'] as String? ?? 'claude-sonnet-4-20250514',
      customApiKey: t['custom_api_key'] as String? ?? '',
      customEndpointUrl: t['custom_endpoint_url'] as String? ?? '',
      customModel: t['custom_model'] as String? ?? '',
      systemPrompt: t['system_prompt'] as String? ?? '',
    ));

    final tts = data['tts'] as Map<String, dynamic>? ?? {};
    await AgentConfigService.saveTtsConfig(TtsConfig(
      provider: TtsProvider
          .values[(tts['provider'] as int? ?? 0).clamp(0, TtsProvider.values.length - 1)],
      elevenLabsApiKey: tts['elevenlabs_api_key'] as String? ?? '',
      elevenLabsVoiceId: tts['elevenlabs_voice_id'] as String? ?? '',
      elevenLabsModelId:
          tts['elevenlabs_model_id'] as String? ?? 'eleven_flash_v2_5',
      kokoroVoiceStyle: tts['kokoro_voice_style'] as String? ?? 'af_heart',
    ));

    final stt = data['stt'] as Map<String, dynamic>? ?? {};
    await AgentConfigService.saveSttConfig(SttConfig(
      provider: SttProvider
          .values[(stt['provider'] as int? ?? 0).clamp(0, SttProvider.values.length - 1)],
      whisperKitModelSize:
          stt['whisperkit_model_size'] as String? ?? 'base',
      whisperKitUseGpu: stt['whisperkit_use_gpu'] as bool? ?? true,
    ));

    final rec = data['recording'] as Map<String, dynamic>? ?? {};
    await AgentConfigService.saveCallRecordingConfig(
      CallRecordingConfig(autoRecord: rec['auto_record'] as bool? ?? false),
    );

    final muteIdx = data['mute_policy'] as int? ?? 0;
    await AgentConfigService.saveMutePolicy(
      AgentMutePolicy.values[muteIdx.clamp(0, AgentMutePolicy.values.length - 1)],
    );

    final cn = data['comfort_noise'] as Map<String, dynamic>?;
    if (cn != null) {
      await AgentConfigService.saveComfortNoiseConfig(ComfortNoiseConfig(
        enabled: cn['enabled'] as bool? ?? false,
        volume: (cn['volume'] as num?)?.toDouble() ?? 0.3,
        selectedPath: cn['selected_path'] as String?,
      ));
    }

    final mgr = data['manager'] as Map<String, dynamic>?;
    if (mgr != null) {
      await UserConfigService.saveAgentManagerConfig(AgentManagerConfig(
        phoneNumber: mgr['phone_number'] as String? ?? '',
        name: mgr['name'] as String? ?? '',
        brandName: mgr['brand_name'] as String? ?? '',
        brandWebsite: mgr['brand_website'] as String? ?? '',
      ));
    }
  }

  static Future<void> _applyJobFunctions(Map<String, dynamic> data) async {
    final items = (data['items'] as List?) ?? [];
    final selectedTitle = data['selected_title'] as String?;

    // Delete existing job functions
    final existing = await CallHistoryDb.getAllJobFunctions();
    for (final row in existing) {
      await CallHistoryDb.deleteJobFunction(row['id'] as int);
    }

    // Insert imported ones
    int? newSelectedId;
    for (final item in items) {
      final map = Map<String, dynamic>.from(item as Map);
      map.remove('id');
      final jf = JobFunction.fromMap(map);
      final newId = await CallHistoryDb.insertJobFunction(jf);
      if (selectedTitle != null && jf.title == selectedTitle) {
        newSelectedId = newId;
      }
    }

    // Restore selection
    final prefs = await SharedPreferences.getInstance();
    if (newSelectedId != null) {
      await prefs.setInt('agent_job_function_id', newSelectedId);
    } else {
      await prefs.remove('agent_job_function_id');
    }
  }

  static Future<void> _applyInboundWorkflows(Map<String, dynamic> data) async {
    final items = (data['items'] as List?) ?? [];

    // Build a title->id lookup from current job functions
    final jfRows = await CallHistoryDb.getAllJobFunctions();
    final titleToId = <String, int>{};
    for (final row in jfRows) {
      final jf = JobFunction.fromMap(row);
      if (jf.id != null) titleToId[jf.title] = jf.id!;
    }

    // Delete existing flows
    final existing = await CallHistoryDb.getAllInboundCallFlows();
    for (final row in existing) {
      await CallHistoryDb.deleteInboundCallFlow(row['id'] as int);
    }

    // Insert imported ones, remapping job function IDs by title
    for (final item in items) {
      final map = item as Map<String, dynamic>;
      final rulesRaw = (map['rules'] as List?) ?? [];
      final rules = rulesRaw.map((r) {
        final rMap = r as Map<String, dynamic>;
        final title = rMap['job_function_title'] as String?;
        int jfId = rMap['job_function_id'] as int? ?? 0;
        if (title != null && titleToId.containsKey(title)) {
          jfId = titleToId[title]!;
        }
        return InboundRule(
          jobFunctionId: jfId,
          phonePatterns:
              (rMap['phone_patterns'] as List?)?.cast<String>() ?? const ['*'],
        );
      }).toList();

      final flow = InboundCallFlow(
        name: map['name'] as String? ?? '',
        enabled: map['enabled'] as bool? ?? true,
        rules: rules,
      );
      await CallHistoryDb.insertInboundCallFlow(flow);
    }
  }
}
