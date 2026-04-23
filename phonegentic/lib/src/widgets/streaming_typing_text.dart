import 'dart:async';

import 'package:flutter/material.dart';

import '../theme_provider.dart';

/// Reveals [fullText] with a smooth typewriter cadence while [isStreaming],
/// and continues to drain any unrevealed text after streaming ends.
///
/// When [voiceSync] is true (TTS active), the reveal is slow (~12 chars/sec)
/// to match speech pace. When false (muted / text-only), it reveals much
/// faster so the text doesn't feel artificially delayed.
///
/// The output is rendered via [Text.rich] so light markdown-ish bolding
/// (`**…**`) renders as actual bold. A handful of "section labels"
/// (`**Calls:**`, `**Messages:**`, `**Calendar:**`, `**Notes:**`) also
/// pick up a leading icon tinted with the app accent so the agent's
/// recap reads as a themed list rather than a wall of prose.
class StreamingTypingText extends StatefulWidget {
  final String fullText;
  final bool isStreaming;
  final bool voiceSync;
  final TextStyle style;

  const StreamingTypingText({
    super.key,
    required this.fullText,
    required this.isStreaming,
    this.voiceSync = false,
    required this.style,
  });

  @override
  State<StreamingTypingText> createState() => _StreamingTypingTextState();
}

class _StreamingTypingTextState extends State<StreamingTypingText> {
  int _revealed = 0;
  Timer? _timer;
  Timer? _pauseTimer;
  bool _frozenByInterrupt = false;

  static const _tickMs = 40;
  static const _boundaryPauseMs = 2000;

  int get _streamRate => widget.voiceSync ? 1 : 4;
  int get _drainRate => widget.voiceSync ? 2 : 8;
  int get _effectiveTickMs => widget.voiceSync ? 80 : _tickMs;

  @override
  void initState() {
    super.initState();
    if (widget.isStreaming) {
      _revealed = 0;
      _ensureTimer();
    } else {
      _revealed = widget.fullText.length;
    }
  }

  @override
  void didUpdateWidget(covariant StreamingTypingText oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.fullText.length < oldWidget.fullText.length) {
      _revealed = widget.fullText.length;
    }

    // Voice-sync turned off (e.g. TTS playback ended or barge-in interrupt)
    // while we were still draining — freeze at the current reveal position
    // so the user only sees text that was actually spoken.
    if (!widget.voiceSync && oldWidget.voiceSync && !widget.isStreaming) {
      _frozenByInterrupt = true;
      _stopTimer();
      _cancelPause();
      return;
    }

    // New streaming message resets the interrupt freeze.
    if (widget.isStreaming && !oldWidget.isStreaming) {
      _frozenByInterrupt = false;
    }

    if (_frozenByInterrupt) return;

    // voiceSync changed — restart timer at new cadence.
    if (widget.voiceSync != oldWidget.voiceSync) {
      _cancelPause();
      if (_timer != null) _stopTimer();
    }

    if (!widget.isStreaming && _revealed >= widget.fullText.length) {
      _stopTimer();
      return;
    }

    if (_revealed < widget.fullText.length) {
      _ensureTimer();
    }
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _cancelPause() {
    _pauseTimer?.cancel();
    _pauseTimer = null;
  }

  void _ensureTimer() {
    if (_timer != null) return;
    _timer = Timer.periodic(
      Duration(milliseconds: _effectiveTickMs),
      (_) {
        if (!mounted) {
          _stopTimer();
          return;
        }
        final target = widget.fullText.length;
        if (_revealed >= target) {
          _stopTimer();
          return;
        }
        final step = widget.isStreaming ? _streamRate : _drainRate;
        final oldRevealed = _revealed;
        final newRevealed = (_revealed + step).clamp(0, target);
        setState(() {
          _revealed = newRevealed;
        });
        if (widget.voiceSync &&
            _hitsSentenceBoundary(widget.fullText, oldRevealed, newRevealed)) {
          _stopTimer();
          _pauseTimer = Timer(
            const Duration(milliseconds: _boundaryPauseMs),
            () {
              _pauseTimer = null;
              if (mounted && _revealed < widget.fullText.length) {
                _ensureTimer();
              }
            },
          );
        }
      },
    );
  }

  /// True if the text between [from] (exclusive) and [to] (inclusive) contains
  /// a sentence-ending punctuation mark followed by a space or newline.
  static bool _hitsSentenceBoundary(String text, int from, int to) {
    for (var i = from; i < to && i + 1 < text.length; i++) {
      final ch = text[i];
      if (ch == '.' || ch == '?' || ch == '!') {
        final next = text.codeUnitAt(i + 1);
        if (next == 0x20 || next == 0x0A) return true;
      }
    }
    return false;
  }

  @override
  void dispose() {
    _stopTimer();
    _cancelPause();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final len = _revealed.clamp(0, widget.fullText.length);
    var text = widget.fullText.substring(0, len);
    final truncated = _frozenByInterrupt && len < widget.fullText.length;
    if (truncated) text = '$text…';
    return Text.rich(
      TextSpan(
        style: widget.style,
        children: _buildSpans(text, widget.style),
      ),
    );
  }

  // --- lightweight markdown parser ------------------------------------------

  /// Section labels the agent uses in recap responses. When the agent
  /// writes `**Calls:**` we replace it with a tinted icon + bold run so
  /// the text reads as a themed list. Matched case-insensitively on the
  /// stripped label (no colon, no whitespace).
  static final Map<String, IconData> _sectionLabelIcons = {
    'calls': Icons.call_outlined,
    'messages': Icons.chat_bubble_outline,
    'calendar': Icons.calendar_today_outlined,
    'notes': Icons.sticky_note_2_outlined,
  };

  static final RegExp _boldRe = RegExp(r'\*\*(.+?)\*\*', dotAll: true);

  /// Convert `text` into a flat list of inline spans. Recognised `**…**`
  /// runs become either a section-label span (icon + tinted bold) or a
  /// plain bold span. Any trailing unterminated `**` is kept inline so
  /// the streaming reveal doesn't flash raw asterisks — the final `**`
  /// will close once the next tick lands it.
  static List<InlineSpan> _buildSpans(String text, TextStyle baseStyle) {
    final accent = AppColors.accent;
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final m in _boldRe.allMatches(text)) {
      if (m.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, m.start)));
      }
      final inner = m.group(1) ?? '';
      final labelKey =
          inner.replaceAll(':', '').trim().toLowerCase();
      final icon = _sectionLabelIcons[labelKey];
      if (icon != null) {
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(right: 5, left: 1),
            child: Icon(icon, size: 13, color: accent),
          ),
        ));
        spans.add(TextSpan(
          text: inner,
          style: baseStyle.copyWith(
            fontWeight: FontWeight.w700,
            color: accent,
          ),
        ));
      } else {
        spans.add(TextSpan(
          text: inner,
          style: baseStyle.copyWith(fontWeight: FontWeight.w700),
        ));
      }
      cursor = m.end;
    }
    if (cursor < text.length) {
      // Handle a half-typed `**` at the tail so streaming doesn't
      // surface raw asterisks. If an odd number of `**` starts remain,
      // strip the last unterminated opener for now.
      var tail = text.substring(cursor);
      final openIdx = tail.lastIndexOf('**');
      if (openIdx != -1 && !tail.substring(openIdx + 2).contains('**')) {
        tail = tail.substring(0, openIdx);
      }
      if (tail.isNotEmpty) {
        spans.add(TextSpan(text: tail));
      }
    }
    return spans;
  }
}
