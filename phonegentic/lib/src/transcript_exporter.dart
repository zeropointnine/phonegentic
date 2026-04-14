import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'models/chat_message.dart';

class TranscriptExporter {
  TranscriptExporter._();

  static String formatCallTranscript({
    required List<Map<String, dynamic>> transcripts,
    String? remoteIdentity,
    String? remoteDisplayName,
    String? direction,
    String? status,
    String? startedAt,
    int? durationSeconds,
  }) {
    final buf = StringBuffer();

    buf.writeln('═══════════════════════════════════════');
    buf.writeln('  CALL TRANSCRIPT');
    buf.writeln('═══════════════════════════════════════');
    buf.writeln();

    if (remoteDisplayName != null && remoteDisplayName.isNotEmpty) {
      buf.writeln('Party:     $remoteDisplayName');
    }
    if (remoteIdentity != null && remoteIdentity.isNotEmpty) {
      buf.writeln('Number:    $remoteIdentity');
    }
    if (direction != null) {
      buf.writeln('Direction: ${direction[0].toUpperCase()}${direction.substring(1)}');
    }
    if (status != null) {
      buf.writeln('Status:    ${status[0].toUpperCase()}${status.substring(1)}');
    }
    if (startedAt != null) {
      try {
        final dt = DateTime.parse(startedAt).toLocal();
        buf.writeln('Date:      ${_formatDate(dt)}');
        buf.writeln('Time:      ${_formatTimeFull(dt)}');
      } catch (_) {
        buf.writeln('Started:   $startedAt');
      }
    }
    if (durationSeconds != null) {
      final m = durationSeconds ~/ 60;
      final s = durationSeconds % 60;
      buf.writeln('Duration:  ${m}m ${s}s');
    }
    buf.writeln();
    buf.writeln('───────────────────────────────────────');
    buf.writeln();

    for (final t in transcripts) {
      final role = t['role'] as String? ?? 'unknown';
      final speaker = t['speaker_name'] as String?;
      final text = t['text'] as String? ?? '';
      final ts = t['timestamp'] as String?;

      String label;
      if (speaker != null && speaker.isNotEmpty) {
        label = speaker;
      } else {
        switch (role) {
          case 'agent':
            label = 'AI';
            break;
          case 'host':
            label = 'Host';
            break;
          case 'remote':
            label = 'Remote';
            break;
          case 'whisper':
            label = 'Whisper';
            break;
          default:
            label = role;
        }
      }

      String timePrefix = '';
      if (ts != null) {
        try {
          final dt = DateTime.parse(ts).toLocal();
          timePrefix = '[${_formatTimeShort(dt)}] ';
        } catch (_) {}
      }

      buf.writeln('$timePrefix$label: $text');
    }

    buf.writeln();
    buf.writeln('───────────────────────────────────────');
    buf.writeln('  End of transcript');
    buf.writeln('═══════════════════════════════════════');

    return buf.toString();
  }

  static String formatSessionTranscript({
    required List<ChatMessage> messages,
    String? sessionLabel,
  }) {
    final buf = StringBuffer();

    buf.writeln('═══════════════════════════════════════');
    buf.writeln('  SESSION TRANSCRIPT');
    if (sessionLabel != null) buf.writeln('  $sessionLabel');
    buf.writeln('═══════════════════════════════════════');
    buf.writeln();
    buf.writeln('Exported: ${_formatDate(DateTime.now())} ${_formatTimeFull(DateTime.now())}');
    buf.writeln();
    buf.writeln('───────────────────────────────────────');
    buf.writeln();

    for (final msg in messages) {
      if (msg.type == MessageType.callState) {
        buf.writeln('  --- ${msg.text} ---');
        continue;
      }

      final isPrevious = msg.metadata?['isPreviousCall'] == true;
      if (msg.metadata?['isPreviousCallHeader'] == true) {
        buf.writeln('  ── Previous call ──');
        continue;
      }
      if (msg.metadata?['isPreviousCallFooter'] == true) {
        buf.writeln('  ── End of previous call ──');
        continue;
      }

      String label;
      switch (msg.role) {
        case ChatRole.user:
          label = msg.type == MessageType.whisper ? 'Whisper' : 'You';
          break;
        case ChatRole.agent:
          label = 'AI';
          break;
        case ChatRole.host:
          label = msg.speakerName ?? 'Host';
          break;
        case ChatRole.remoteParty:
          label = msg.speakerName ?? 'Remote';
          break;
        case ChatRole.system:
          label = 'System';
          break;
      }

      final prefix = isPrevious ? '(prev) ' : '';
      final time = _formatTimeShort(msg.timestamp);
      buf.writeln('[$time] $prefix$label: ${msg.text}');
    }

    buf.writeln();
    buf.writeln('───────────────────────────────────────');
    buf.writeln('  End of transcript');
    buf.writeln('═══════════════════════════════════════');

    return buf.toString();
  }

  static Future<File?> saveToDownloads(
    String content, {
    required String filenamePrefix,
    required BuildContext context,
  }) async {
    try {
      final downloadsDir = await getDownloadsDirectory();
      if (downloadsDir == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not access Downloads folder'),
              duration: Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return null;
      }

      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final filename = '${filenamePrefix}_$timestamp.txt';
      final file = File('${downloadsDir.path}/$filename');
      await file.writeAsString(content);

      await Process.run('open', [downloadsDir.path]);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved to Downloads/$filename'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return file;
    } catch (e) {
      debugPrint('[TranscriptExporter] Save failed: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save transcript: $e'),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return null;
    }
  }

  static String _formatDate(DateTime dt) =>
      '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

  static String _formatTimeFull(DateTime dt) {
    final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')} $ampm';
  }

  static String _formatTimeShort(DateTime dt) {
    final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:${dt.minute.toString().padLeft(2, '0')} $ampm';
  }
}
