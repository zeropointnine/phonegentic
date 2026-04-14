import 'dart:async';

import 'package:flutter/material.dart';

/// Reveals [fullText] with a smooth typewriter cadence while [isStreaming],
/// and continues to drain any unrevealed text after streaming ends.
///
/// When [voiceSync] is true (TTS active), the reveal is slow (~12 chars/sec)
/// to match speech pace. When false (muted / text-only), it reveals much
/// faster so the text doesn't feel artificially delayed.
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
    final text = widget.fullText.substring(0, len);
    final truncated = _frozenByInterrupt && len < widget.fullText.length;
    return Text(
      truncated ? '$text…' : text,
      style: widget.style,
    );
  }
}
