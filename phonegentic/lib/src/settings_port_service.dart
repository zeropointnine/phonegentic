import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'agent_config_service.dart';
import 'conference/conference_config.dart';
import 'db/call_history_db.dart';
import 'db/pocket_tts_voice_db.dart';
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
  appSettings,
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
      case SettingsSection.appSettings:
        return 'app_settings';
    }
  }

  String get displayName {
    switch (this) {
      case SettingsSection.sipSettings:
        return 'Phone Settings';
      case SettingsSection.agentSettings:
        return 'Agent Settings';
      case SettingsSection.jobFunctions:
        return 'Agent Job Functions';
      case SettingsSection.inboundWorkflows:
        return 'Inbound Call Workflows';
      case SettingsSection.appSettings:
        return 'App Settings';
    }
  }

  IconData get icon {
    switch (this) {
      case SettingsSection.sipSettings:
        return Icons.phone_rounded;
      case SettingsSection.agentSettings:
        return Icons.auto_awesome;
      case SettingsSection.jobFunctions:
        return Icons.work_rounded;
      case SettingsSection.inboundWorkflows:
        return Icons.call_received_rounded;
      case SettingsSection.appSettings:
        return Icons.widgets_rounded;
    }
  }
}

/// Collects the set of audio files to include in an export archive,
/// *without* reading their bytes. Reading is deferred to the export
/// isolate ([_runExportInIsolate]) so the UI thread never blocks on
/// large WAV reads or the final ZIP/TAR encode.
class _AudioManifest {
  /// `(archivePath, absoluteDiskPath)` pairs.
  final List<({String archivePath, String diskPath})> entries = [];
  final Set<String> _seenArchivePaths = {};

  /// Adds every file in `{docs}/phonegentic/<docsSubdir>/` (or [paths] if
  /// explicit) to the manifest under `<archivePrefix>/<filename>`. Returns
  /// the basenames added (or already present) for embedding into the JSON
  /// envelope.
  Future<List<String>> attachDir(
    String archivePrefix,
    String docsSubdir, {
    Iterable<String>? paths,
  }) async {
    final sourcePaths =
        paths ?? await SettingsPortService._listAudioDir(docsSubdir);
    final names = <String>[];
    final seenLocal = <String>{};
    for (final path in sourcePaths) {
      if (path.isEmpty) continue;
      final filename = p.basename(path);
      if (!seenLocal.add(filename)) continue;
      final entryName = '$archivePrefix/$filename';
      if (_seenArchivePaths.add(entryName)) {
        entries.add((archivePath: entryName, diskPath: path));
      }
      names.add(filename);
    }
    return names;
  }
}

/// Sendable payload describing all the work to be done in the export
/// isolate. Class instances composed entirely of sendable fields (Strings,
/// bools, Lists, Uint8List, records) transfer cleanly across isolates.
class _ExportPayload {
  final List<({String name, Uint8List bytes})> jsonEntries;
  final List<({String archivePath, String diskPath})> audioEntries;
  final String outputPath;
  final bool useTar;

  _ExportPayload({
    required this.jsonEntries,
    required this.audioEntries,
    required this.outputPath,
    required this.useTar,
  });
}

/// Runs entirely inside a background isolate spawned by [Isolate.run]. Reads
/// every audio file from disk, assembles an [Archive], encodes to ZIP or
/// TAR+GZip, and writes the result to [_ExportPayload.outputPath]. Keeping
/// all of this off the main isolate prevents the UI from hanging during
/// large exports (multi-megabyte recordings, hours of audio, etc.).
Future<void> _runExportInIsolate(_ExportPayload payload) async {
  final archive = Archive();

  for (final ae in payload.audioEntries) {
    try {
      final f = File(ae.diskPath);
      if (!f.existsSync()) continue;
      final bytes = f.readAsBytesSync();
      archive.addFile(ArchiveFile(ae.archivePath, bytes.length, bytes));
    } catch (_) {
      // Skip unreadable files rather than failing the whole export.
    }
  }

  for (final je in payload.jsonEntries) {
    archive.addFile(ArchiveFile(je.name, je.bytes.length, je.bytes));
  }

  final outFile = File(payload.outputPath);
  if (payload.useTar) {
    final tarBytes = TarEncoder().encode(archive);
    final gzBytes = GZipEncoder().encode(tarBytes);
    outFile.writeAsBytesSync(gzBytes);
  } else {
    final encoded = ZipEncoder().encode(archive);
    outFile.writeAsBytesSync(encoded);
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
    // Audio attachments only round-trip through .zip / .tar archives. For
    // the legacy `.json` format there's no archive to put raw bytes into,
    // so audio bundling is skipped (settings/metadata still round-trip).
    final manifest = format == ExportFormat.json ? null : _AudioManifest();
    final data = await _gatherData(section, manifest);
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
      case ExportFormat.tar:
        final isTar = format == ExportFormat.tar;
        outputFile = File(
          '${downloadsDir.path}/$baseName${isTar ? '.tar.gz' : '.zip'}',
        );
        final payload = _ExportPayload(
          jsonEntries: [
            (
              name: '$baseName.json',
              bytes: Uint8List.fromList(outputBytes),
            ),
          ],
          audioEntries: manifest!.entries,
          outputPath: outputFile.path,
          useTar: isTar,
        );
        await Isolate.run(() => _runExportInIsolate(payload));
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

    // Gather (main isolate): each section produces a JSON envelope and adds
    // its audio file paths to a shared manifest. No audio bytes are read
    // here -- the heavy file I/O + archive encode happens in [Isolate.run]
    // below so the UI stays responsive.
    final manifest = _AudioManifest();
    final jsonEntries = <({String name, Uint8List bytes})>[];
    for (final section in SettingsSection.values) {
      final data = await _gatherData(section, manifest);
      final envelope = {
        'app': 'phonegentic',
        'version': 1,
        'section': section.label,
        'exported_at': DateTime.now().toUtc().toIso8601String(),
        'data': data,
      };
      final rawJsonBytes = utf8
          .encode(const JsonEncoder.withIndent('  ').convert(envelope));

      Uint8List fileBytes;
      if (password != null) {
        final encrypted = await SettingsCrypto.encrypt(
          Uint8List.fromList(rawJsonBytes),
          password,
        );
        fileBytes = Uint8List.fromList(
          utf8.encode(const JsonEncoder.withIndent('  ').convert(encrypted)),
        );
      } else {
        fileBytes = Uint8List.fromList(rawJsonBytes);
      }

      jsonEntries.add((name: '${section.label}.json', bytes: fileBytes));
    }

    final isTar = format == ExportFormat.tar;
    final outputFile = File(
      '${downloadsDir.path}/$baseName${isTar ? '.tar.gz' : '.zip'}',
    );
    final payload = _ExportPayload(
      jsonEntries: jsonEntries,
      audioEntries: manifest.entries,
      outputPath: outputFile.path,
      useTar: isTar,
    );
    await Isolate.run(() => _runExportInIsolate(payload));

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
      'app_settings',
    ];

    try {
      for (final key in applyOrder) {
        if (!sectionData.containsKey(key)) continue;
        final section =
            SettingsSection.values.firstWhere((s) => s.label == key);
        await _applyData(section, sectionData[key]!, arch);
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
    Archive? archive;
    try {
      final decoded = _decodeFileWithArchive(bytes, file.path);
      envelope = decoded.$1;
      archive = decoded.$2;
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
      await _applyData(
          section, envelope['data'] as Map<String, dynamic>, archive);
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

  /// Decodes an export file and returns `(envelope, archive)`. The archive
  /// is non-null for .zip / .tar / .tar.gz inputs and is used to look up
  /// attached audio entries during import; for raw .json input it is null.
  static (Map<String, dynamic>, Archive?) _decodeFileWithArchive(
      Uint8List bytes, String path) {
    if (path.endsWith('.json')) {
      return (
        jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
        null,
      );
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
          return (
            jsonDecode(utf8.decode(file.content as List<int>))
                as Map<String, dynamic>,
            archive,
          );
        }
      }
      throw const FormatException('No JSON file found inside archive');
    }

    // Try parsing as raw JSON as fallback.
    return (
      jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
      null,
    );
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
      SettingsSection section, _AudioManifest? manifest) async {
    switch (section) {
      case SettingsSection.sipSettings:
        return _gatherSip(manifest);
      case SettingsSection.agentSettings:
        return _gatherAgent(manifest);
      case SettingsSection.jobFunctions:
        return _gatherJobFunctions(manifest);
      case SettingsSection.inboundWorkflows:
        return _gatherInboundWorkflows();
      case SettingsSection.appSettings:
        return _gatherApp();
    }
  }

  static Future<Map<String, dynamic>> _gatherSip(
      _AudioManifest? manifest) async {
    final prefs = await SharedPreferences.getInstance();
    final conf = await AgentConfigService.loadConferenceConfig();

    // Bundle all custom ringtones (the entire user-uploaded pool, not just
    // the selected one) so they survive export/import on a new device. The
    // selected ringtone is stored portably as either a bundled-asset path
    // (for the built-in ringtones, which ship in the app bundle) or as a
    // basename (for custom WAV/MP3/AAC/M4A files in `{docs}/.../ringtones/`).
    final selectedRingtone = prefs.getString('agent_ringtone') ?? '';
    final selectedIsAsset = selectedRingtone.startsWith('assets/');
    final ringtoneFilenames = manifest != null
        ? await manifest.attachDir('audio/ringtones', 'ringtones')
        : <String>[];
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
        'max_participants': conf.maxParticipants,
        'basic_supports_update': conf.basicSupportsUpdate,
        'basic_renegotiate_media': conf.basicRenegotiateMedia,
      },
      // Phone tones live in the Phone settings tab, so they round-trip
      // alongside the rest of the SIP/phone preferences.
      'tones': {
        'touch_enabled': prefs.getBool('tone_touch_enabled') ?? true,
        'touch_style': prefs.getString('tone_touch_style') ?? 'dtmf',
        'call_waiting_enabled':
            prefs.getBool('tone_call_waiting_enabled') ?? true,
        'call_waiting_announce':
            prefs.getBool('tone_call_waiting_announce') ?? false,
        'call_ended_enabled':
            prefs.getBool('tone_call_ended_enabled') ?? true,
        'call_ended_announce':
            prefs.getBool('tone_call_ended_announce') ?? false,
      },
      'ringtone': {
        'enabled': prefs.getBool('agent_ring_enabled') ?? true,
        'auto_answer': prefs.getBool('agent_auto_answer') ?? false,
        // Portable identifier for the selected ringtone:
        //   - `selected_asset`: bundled asset path (e.g. `assets/...wav`)
        //   - `selected_filename`: basename of a custom file
        // Importers prefer the filename (if the bundled custom WAV is found)
        // over the asset, falling back to the asset path for built-ins.
        'selected_asset': selectedIsAsset ? selectedRingtone : null,
        'selected_filename':
            (!selectedIsAsset && selectedRingtone.isNotEmpty)
                ? p.basename(selectedRingtone)
                : null,
        // Filenames whose raw bytes live in `audio/ringtones/<filename>`
        // archive entries. Empty list when audio attachments are not
        // available (e.g. legacy `.json` export format).
        'filenames': ringtoneFilenames,
      },
    };
  }

  static Future<Map<String, dynamic>> _gatherAgent(
      _AudioManifest? manifest) async {
    final voice = await AgentConfigService.loadVoiceConfig();
    final text = await AgentConfigService.loadTextConfig();
    final tts = await AgentConfigService.loadTtsConfig();
    final stt = await AgentConfigService.loadSttConfig();
    final rec = await AgentConfigService.loadCallRecordingConfig();
    final mute = await AgentConfigService.loadMutePolicy();
    final cn = await AgentConfigService.loadComfortNoiseConfig();
    final mgr = await UserConfigService.loadAgentManagerConfig();

    // Call recordings are intentionally NOT bundled into exports. They can
    // be large (hours of audio) and are tied to call-history metadata that
    // isn't part of this export anyway. The user's `auto_record` preference
    // still round-trips so new recordings keep happening on the new device.
    final voiceSampleFilenames = manifest != null
        ? await manifest.attachDir('audio/voice_samples', 'voice_samples')
        : <String>[];
    final comfortFilenames = manifest != null
        ? await manifest.attachDir('audio/comfort_noise', 'comfort_noise')
        : <String>[];
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
        // Recording WAVs are deliberately excluded from exports (see
        // _gatherAgent above). Only the user's preference round-trips.
      },
      'mute_policy': mute.index,
      'comfort_noise': {
        'enabled': cn.enabled,
        'volume': cn.volume,
        // selected_path is device-specific; store the basename and resolve
        // back to an absolute path on import.
        'selected_filename':
            cn.selectedPath != null ? p.basename(cn.selectedPath!) : null,
        // Filenames whose raw bytes live in `audio/comfort_noise/<filename>`
        // archive entries. Includes the entire user pool, not just the
        // currently-selected file.
        'filenames': comfortFilenames,
      },
      'manager': {
        'phone_number': mgr.phoneNumber,
        'name': mgr.name,
        'brand_name': mgr.brandName,
        'brand_website': mgr.brandWebsite,
      },
      // Filenames whose raw bytes live in `audio/voice_samples/<filename>`
      // archive entries. Captures the whole sample pool (incl. unattached
      // mic captures that have not yet been turned into a cloned voice).
      'voice_sample_filenames': voiceSampleFilenames,
    };
  }

  static Future<Map<String, dynamic>> _gatherJobFunctions(
      _AudioManifest? manifest) async {
    final rows = await CallHistoryDb.getAllJobFunctions();
    final items = rows.map((r) => JobFunction.fromMap(r)).toList();
    final prefs = await SharedPreferences.getInstance();
    final selectedId = prefs.getInt('agent_job_function_id');
    String? selectedTitle;
    if (selectedId != null) {
      final match = items.where((j) => j.id == selectedId);
      if (match.isNotEmpty) selectedTitle = match.first.title;
    }

    // Build name/filename replacements for the numeric voice id and absolute
    // comfort noise path so the export is portable across devices.
    final voices = await PocketTtsVoiceDb.listVoices();
    final voicesById = {for (final v in voices) if (v.id != null) v.id!: v};

    // Attach the entire user-uploaded pool to the archive (voice WAVs +
    // comfort-noise WAVs). The JSON only carries metadata + filename refs;
    // raw bytes live in `audio/.../<filename>` archive entries.
    final voiceMetas = <Map<String, dynamic>>[];
    final voiceWavPaths = <String>[];
    for (final v in voicesById.values) {
      if (v.isDefault) {
        // Defaults are matched by name on the target device (re-seeded
        // there); no audio bytes are bundled.
        voiceMetas.add({
          'name': v.name,
          'accent': v.accent,
          'gender': v.gender,
          'is_default': true,
          'audio_filename': null,
          'embedding_base64':
              v.embedding != null ? base64Encode(v.embedding!) : null,
          'created_at': v.createdAt.toIso8601String(),
        });
        continue;
      }
      String? audioFilename;
      if (v.audioPath != null && v.audioPath!.isNotEmpty) {
        audioFilename = p.basename(v.audioPath!);
        voiceWavPaths.add(v.audioPath!);
      }
      voiceMetas.add({
        'name': v.name,
        'accent': v.accent,
        'gender': v.gender,
        'is_default': false,
        'audio_filename': audioFilename,
        'embedding_base64':
            v.embedding != null ? base64Encode(v.embedding!) : null,
        'created_at': v.createdAt.toIso8601String(),
      });
    }
    if (manifest != null) {
      await manifest.attachDir(
        'audio/pocket_tts_voices',
        'pocket_tts_voices',
        paths: voiceWavPaths,
      );
    }
    final comfortFilenames = manifest != null
        ? await manifest.attachDir('audio/comfort_noise', 'comfort_noise')
        : <String>[];

    return {
      'selected_title': selectedTitle,
      'items': items.map((jf) {
        final m = jf.toMap();
        m.remove('id');
        // Replace numeric voice id with a portable voice name.
        final voice =
            jf.pocketTtsVoiceId != null ? voicesById[jf.pocketTtsVoiceId] : null;
        m['pocket_tts_voice_id'] = null;
        m['pocket_tts_voice_name'] = voice?.name;
        // Replace absolute comfort-noise path with a portable basename.
        m['comfort_noise_path'] = null;
        m['comfort_noise_filename'] = jf.comfortNoisePath != null
            ? p.basename(jf.comfortNoisePath!)
            : null;
        return m;
      }).toList(),
      'pocket_tts_voices': voiceMetas,
      'comfort_noise_filenames': comfortFilenames,
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
  // Audio file attachment / restoration via archive entries
  //
  // Audio files (ringtones, recordings, voice samples, comfort-noise WAVs,
  // pocket-TTS voice WAVs) are NOT base64-encoded into the JSON envelopes.
  // Encoding multi-megabyte WAVs into a single JSON blob blows up memory and
  // hangs the UI thread. Instead, the export side builds an [_AudioManifest]
  // of `(archivePath, diskPath)` pairs on the main isolate (no I/O), then
  // hands the manifest off to a background isolate ([_runExportInIsolate])
  // that reads each file, builds the [Archive], encodes ZIP/TAR+GZip, and
  // writes the result to disk. The JSON envelope only references files by
  // basename; raw bytes live in `audio/<subdir>/<filename>` archive entries.
  //
  // For the legacy `.json` export format (no archive), audio attachments
  // are silently skipped — only settings/metadata round-trip.
  // ---------------------------------------------------------------------------

  /// Lists every file currently in a `{docs}/phonegentic/<subdir>/` audio dir.
  static Future<List<String>> _listAudioDir(String subdir) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final audioDir = Directory(p.join(dir.path, 'phonegentic', subdir));
      if (!await audioDir.exists()) return const <String>[];
      return audioDir
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .toList();
    } catch (e) {
      debugPrint('[SettingsPort] Failed to list "$subdir" dir: $e');
      return const <String>[];
    }
  }

  /// Extracts every entry in [attach] whose name starts with
  /// `<archivePrefix>/` into `{docs}/phonegentic/<destSubdir>/`, returning
  /// `{basename: absolutePath}` for remapping portable filename references
  /// during import.
  static Future<Map<String, String>> _restoreAudioFromArchive(
    Archive? attach,
    String archivePrefix,
    String destSubdir,
  ) async {
    if (attach == null) return const {};
    final dir = await getApplicationDocumentsDirectory();
    final outDir = Directory(p.join(dir.path, 'phonegentic', destSubdir));
    await outDir.create(recursive: true);

    final result = <String, String>{};
    final prefixSlash = '$archivePrefix/';
    for (final entry in attach) {
      if (!entry.name.startsWith(prefixSlash)) continue;
      if (entry.isFile != true) continue;
      final filename = entry.name.substring(prefixSlash.length);
      if (filename.isEmpty || filename.contains('/')) continue;
      final outPath = p.join(outDir.path, filename);
      try {
        final file = File(outPath);
        if (!await file.exists()) {
          await file.writeAsBytes(
            entry.content,
            flush: true,
          );
        }
        result[filename] = outPath;
      } catch (e) {
        debugPrint(
            '[SettingsPort] Failed to restore "${entry.name}": $e');
      }
    }
    return result;
  }

  /// Backwards-compat fallback for legacy exports where audio bytes were
  /// embedded as base64 inside the JSON envelope (under either a `files`
  /// list or per-voice `audio_base64` fields). Decodes each entry and writes
  /// the bytes to `{docs}/phonegentic/<destSubdir>/<filename>`. Returns
  /// `{basename: absolutePath}`. New exports skip this path entirely; this
  /// only fires when reading an envelope produced by an older app version.
  static Future<Map<String, String>> _restoreLegacyBase64Audio(
    List<dynamic>? entries,
    String destSubdir, {
    String filenameKey = 'filename',
    String bytesKey = 'audio_base64',
  }) async {
    if (entries == null || entries.isEmpty) return const {};
    final dir = await getApplicationDocumentsDirectory();
    final outDir = Directory(p.join(dir.path, 'phonegentic', destSubdir));
    await outDir.create(recursive: true);

    final result = <String, String>{};
    for (final raw in entries) {
      if (raw is! Map) continue;
      final entry = Map<String, dynamic>.from(raw);
      final filename = entry[filenameKey] as String?;
      final b64 = entry[bytesKey] as String?;
      if (filename == null || filename.isEmpty || b64 == null) continue;
      final outPath = p.join(outDir.path, filename);
      try {
        final bytes = base64Decode(b64);
        final file = File(outPath);
        if (!await file.exists()) {
          await file.writeAsBytes(bytes, flush: true);
        }
        result[filename] = outPath;
      } catch (e) {
        debugPrint(
            '[SettingsPort] Failed to restore legacy "$destSubdir/$filename": $e');
      }
    }
    return result;
  }

  /// Inserts (or reuses by name) Pocket TTS voice rows for each metadata
  /// entry in the JSON envelope. Audio bytes are not in the JSON -- they
  /// were already restored to disk via [_restoreAudioFromArchive] and are
  /// passed in via [wavsByFilename] (basename -> absolute path on disk).
  /// Returns a map of voice name -> db id for use when remapping
  /// `pocket_tts_voice_id` references on import.
  static Future<Map<String, int>> _registerImportedVoices(
    List<dynamic>? entries,
    Map<String, String> wavsByFilename,
  ) async {
    final result = <String, int>{};

    // Pre-populate with already-present voices (defaults + prior imports) so
    // references without a bundled WAV can still be resolved.
    final existing = await PocketTtsVoiceDb.listVoices();
    for (final v in existing) {
      if (v.id != null) result[v.name] = v.id!;
    }

    if (entries == null || entries.isEmpty) return result;

    for (final raw in entries) {
      final entry = raw as Map<String, dynamic>;
      final name = entry['name'] as String?;
      if (name == null || name.isEmpty) continue;

      // Keep the existing row if a voice with this name is already present
      // (default or previously imported) rather than duplicating.
      if (result.containsKey(name)) continue;

      final audioFilename = entry['audio_filename'] as String?;
      final embeddingB64 = entry['embedding_base64'] as String?;
      final accent = entry['accent'] as String?;
      final gender = entry['gender'] as String?;
      final isDefault = entry['is_default'] as bool? ?? false;
      final createdAt =
          DateTime.tryParse(entry['created_at'] as String? ?? '') ??
              DateTime.now();

      final audioPath = (audioFilename != null && audioFilename.isNotEmpty)
          ? wavsByFilename[audioFilename]
          : null;

      if (audioPath == null && !isDefault) {
        // No bundled audio and not a default — can't recreate this voice.
        continue;
      }

      Uint8List? embedding;
      if (embeddingB64 != null) {
        try {
          embedding = base64Decode(embeddingB64);
        } catch (_) {}
      }

      final newId = await PocketTtsVoiceDb.insertVoice(PocketTtsVoice(
        name: name,
        accent: accent,
        gender: gender,
        isDefault: isDefault,
        audioPath: audioPath,
        embedding: embedding,
        createdAt: createdAt,
      ));
      result[name] = newId;
    }

    return result;
  }

  static Future<Map<String, dynamic>> _gatherApp() async {
    final prefs = await SharedPreferences.getInstance();
    final calendly = await UserConfigService.loadCalendlyConfig();
    final demo = await UserConfigService.loadDemoModeConfig();
    final awayReturn = await UserConfigService.loadAwayReturnConfig();
    return {
      'theme': prefs.getString('app_theme') ?? 'amberVt100',
      'calendly': {
        'api_key': calendly.apiKey,
        'sync_to_macos': calendly.syncToMacOS,
      },
      'demo_mode': {
        'enabled': demo.enabled,
        'fake_number': demo.fakeNumber,
      },
      'away_return_mode': awayReturn.mode.name,
    };
  }

  // ---------------------------------------------------------------------------
  // Data application (import)
  // ---------------------------------------------------------------------------

  static Future<void> _applyData(
    SettingsSection section,
    Map<String, dynamic> data,
    Archive? attach,
  ) async {
    switch (section) {
      case SettingsSection.sipSettings:
        await _applySip(data, attach);
        break;
      case SettingsSection.agentSettings:
        await _applyAgent(data, attach);
        break;
      case SettingsSection.jobFunctions:
        await _applyJobFunctions(data, attach);
        break;
      case SettingsSection.inboundWorkflows:
        await _applyInboundWorkflows(data);
        break;
      case SettingsSection.appSettings:
        await _applyApp(data);
        break;
    }
  }

  static Future<void> _applySip(
      Map<String, dynamic> data, Archive? attach) async {
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
        maxParticipants: conf['max_participants'] as int? ?? 5,
        basicSupportsUpdate: conf['basic_supports_update'] as bool? ?? false,
        basicRenegotiateMedia: conf['basic_renegotiate_media'] as bool? ?? false,
      ));
    }

    final tones = data['tones'] as Map<String, dynamic>?;
    if (tones != null) {
      await prefs.setBool(
          'tone_touch_enabled', tones['touch_enabled'] as bool? ?? true);
      final style = tones['touch_style'] as String?;
      if (style == 'blue' || style == 'dtmf') {
        await prefs.setString('tone_touch_style', style!);
      }
      await prefs.setBool('tone_call_waiting_enabled',
          tones['call_waiting_enabled'] as bool? ?? true);
      await prefs.setBool('tone_call_waiting_announce',
          tones['call_waiting_announce'] as bool? ?? false);
      await prefs.setBool('tone_call_ended_enabled',
          tones['call_ended_enabled'] as bool? ?? true);
      await prefs.setBool('tone_call_ended_announce',
          tones['call_ended_announce'] as bool? ?? false);
    }

    final ring = data['ringtone'] as Map<String, dynamic>?;
    if (ring != null) {
      await prefs.setBool(
          'agent_ring_enabled', ring['enabled'] as bool? ?? true);
      await prefs.setBool(
          'agent_auto_answer', ring['auto_answer'] as bool? ?? false);

      // Restore custom ringtone WAVs from `audio/ringtones/<filename>`
      // archive entries to `{docs}/phonegentic/ringtones/`.
      final extracted = await _restoreAudioFromArchive(
          attach, 'audio/ringtones', 'ringtones');

      String? selected;
      final filename = ring['selected_filename'] as String?;
      if (filename != null && extracted.containsKey(filename)) {
        selected = extracted[filename];
      } else if (ring['selected_asset'] is String &&
          (ring['selected_asset'] as String).isNotEmpty) {
        selected = ring['selected_asset'] as String;
      }
      if (selected != null) {
        await prefs.setString('agent_ringtone', selected);
      }
    }
  }

  static Future<void> _applyAgent(
      Map<String, dynamic> data, Archive? attach) async {
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
      openaiModel: t['openai_model'] as String? ?? 'gpt-5.4-mini',
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
    // Newer exports do not include call recordings. Older backups (pre-
    // exclusion) may still carry `audio/recordings/*` entries; restore them
    // so legacy archives keep importing cleanly even though we no longer
    // produce them.
    await _restoreAudioFromArchive(attach, 'audio/recordings', 'recordings');

    // Restore voice samples from `audio/voice_samples/*` archive entries.
    await _restoreAudioFromArchive(
        attach, 'audio/voice_samples', 'voice_samples');

    final muteIdx = data['mute_policy'] as int? ?? 0;
    await AgentConfigService.saveMutePolicy(
      AgentMutePolicy.values[muteIdx.clamp(0, AgentMutePolicy.values.length - 1)],
    );

    final cn = data['comfort_noise'] as Map<String, dynamic>?;
    if (cn != null) {
      // Restore comfort-noise WAVs and remap the portable selected filename
      // back to an absolute path on this device. Fall back to legacy
      // base64-in-JSON `files` (older app versions) and to the legacy
      // `selected_path` field for ancient exports.
      final extracted = <String, String>{
        ...await _restoreLegacyBase64Audio(
          cn['files'] as List?,
          'comfort_noise',
        ),
        ...await _restoreAudioFromArchive(
            attach, 'audio/comfort_noise', 'comfort_noise'),
      };
      final filename = cn['selected_filename'] as String?;
      String? selectedPath;
      if (filename != null && extracted.containsKey(filename)) {
        selectedPath = extracted[filename];
      } else if (cn['selected_path'] is String) {
        selectedPath = cn['selected_path'] as String;
      }
      await AgentConfigService.saveComfortNoiseConfig(ComfortNoiseConfig(
        enabled: cn['enabled'] as bool? ?? false,
        volume: (cn['volume'] as num?)?.toDouble() ?? 0.3,
        selectedPath: selectedPath,
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

  static Future<void> _applyJobFunctions(
      Map<String, dynamic> data, Archive? attach) async {
    final items = (data['items'] as List?) ?? [];
    final selectedTitle = data['selected_title'] as String?;

    // Restore audio from archive entries first, then register voices, then
    // touch job-function rows -- so portable name/filename references can be
    // remapped back to local ids/absolute paths. Older exports (pre-archive-
    // entry format) embedded audio as base64 in the JSON; fall back to that
    // path when present so legacy backups still import cleanly.
    final comfortNoiseByFilename = <String, String>{
      ...await _restoreLegacyBase64Audio(
        data['comfort_noise_files'] as List?,
        'comfort_noise',
      ),
      ...await _restoreAudioFromArchive(
          attach, 'audio/comfort_noise', 'comfort_noise'),
    };
    final voiceWavsByFilename = <String, String>{
      ...await _restoreLegacyBase64Audio(
        data['pocket_tts_voices'] as List?,
        'pocket_tts_voices',
        filenameKey: 'audio_filename',
      ),
      ...await _restoreAudioFromArchive(
          attach, 'audio/pocket_tts_voices', 'pocket_tts_voices'),
    };
    final voiceIdsByName = await _registerImportedVoices(
      data['pocket_tts_voices'] as List?,
      voiceWavsByFilename,
    );

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

      // Remap portable voice name -> local id (fallback to legacy numeric
      // field if the export predates phase 2).
      final voiceName = map.remove('pocket_tts_voice_name') as String?;
      if (voiceName != null && voiceIdsByName.containsKey(voiceName)) {
        map['pocket_tts_voice_id'] = voiceIdsByName[voiceName];
      } else if (voiceName != null) {
        map['pocket_tts_voice_id'] = null;
      }

      // Remap portable comfort-noise filename -> local absolute path.
      final cnFilename = map.remove('comfort_noise_filename') as String?;
      if (cnFilename != null &&
          comfortNoiseByFilename.containsKey(cnFilename)) {
        map['comfort_noise_path'] = comfortNoiseByFilename[cnFilename];
      } else if (cnFilename != null) {
        map['comfort_noise_path'] = null;
      }

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

  static Future<void> _applyApp(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    final theme = data['theme'] as String?;
    if (theme != null) {
      await prefs.setString('app_theme', theme);
    }

    final cal = data['calendly'] as Map<String, dynamic>?;
    if (cal != null) {
      await UserConfigService.saveCalendlyConfig(CalendlyConfig(
        apiKey: cal['api_key'] as String? ?? '',
        syncToMacOS: cal['sync_to_macos'] as bool? ?? false,
      ));
    }

    final demo = data['demo_mode'] as Map<String, dynamic>?;
    if (demo != null) {
      await UserConfigService.saveDemoModeConfig(DemoModeConfig(
        enabled: demo['enabled'] as bool? ?? false,
        fakeNumber: demo['fake_number'] as String? ?? '',
      ));
    }

    final awayMode = data['away_return_mode'] as String?;
    if (awayMode != null) {
      final mode = AwayReturnMode.values.firstWhere(
        (m) => m.name == awayMode,
        orElse: () => AwayReturnMode.quietBadge,
      );
      await UserConfigService.saveAwayReturnConfig(AwayReturnConfig(mode: mode));
    }
  }

  // ---------------------------------------------------------------------------
  // Selective export (chosen sections only)
  // ---------------------------------------------------------------------------

  static Future<File?> exportSelected(
    Set<SettingsSection> sections,
    ExportFormat format,
    BuildContext context,
  ) async {
    if (sections.isEmpty) return null;

    if (sections.length == 1) {
      return exportSection(sections.first, format, context);
    }

    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final baseName = 'phonegentic_settings_$timestamp';

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

    if (!context.mounted) return null;
    final password = await _askExportPassword(context);

    // Gather (main isolate). Audio bytes are NOT read here; instead the
    // shared manifest collects file paths and the heavy archive encode +
    // write happens in [Isolate.run] below.
    final manifest = _AudioManifest();
    final jsonEntries = <({String name, Uint8List bytes})>[];
    for (final section in SettingsSection.values) {
      if (!sections.contains(section)) continue;
      final data = await _gatherData(section, manifest);
      final envelope = {
        'app': 'phonegentic',
        'version': 1,
        'section': section.label,
        'exported_at': DateTime.now().toUtc().toIso8601String(),
        'data': data,
      };
      final rawJsonBytes =
          utf8.encode(const JsonEncoder.withIndent('  ').convert(envelope));

      Uint8List fileBytes;
      if (password != null) {
        final encrypted = await SettingsCrypto.encrypt(
          Uint8List.fromList(rawJsonBytes),
          password,
        );
        fileBytes = Uint8List.fromList(
          utf8.encode(const JsonEncoder.withIndent('  ').convert(encrypted)),
        );
      } else {
        fileBytes = Uint8List.fromList(rawJsonBytes);
      }

      jsonEntries.add((name: '${section.label}.json', bytes: fileBytes));
    }

    final isTar = format == ExportFormat.tar;
    final outputFile = File(
      '${downloadsDir.path}/$baseName${isTar ? '.tar.gz' : '.zip'}',
    );
    final payload = _ExportPayload(
      jsonEntries: jsonEntries,
      audioEntries: manifest.entries,
      outputPath: outputFile.path,
      useTar: isTar,
    );
    await Isolate.run(() => _runExportInIsolate(payload));

    await Process.run('open', [downloadsDir.path]);

    if (context.mounted) {
      final names = sections.map((s) => s.displayName).join(', ');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Exported $names to Downloads'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    return outputFile;
  }
}
