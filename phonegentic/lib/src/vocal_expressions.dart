/// Vocal expression system for human-like agent speech.
///
/// The agent embeds `{expression}` markers in its text output. Before TTS
/// synthesis these are replaced with phonetic text that ElevenLabs / Kokoro
/// render as natural vocal sounds. For UI display the markers are stripped
/// or converted to italic annotations.
class VocalExpression {
  final String tag;
  final String ttsText;
  final String displayText;

  const VocalExpression({
    required this.tag,
    required this.ttsText,
    required this.displayText,
  });
}

class VocalExpressionRegistry {
  VocalExpressionRegistry._();

  static const List<VocalExpression> expressions = [
    VocalExpression(
      tag: 'laugh',
      ttsText: 'Ha ha ha! ',
      displayText: '*laughs*',
    ),
    VocalExpression(
      tag: 'chuckle',
      ttsText: 'Heh heh. ',
      displayText: '*chuckles*',
    ),
    VocalExpression(
      tag: 'sigh',
      ttsText: 'Haaah... ',
      displayText: '*sighs*',
    ),
    VocalExpression(
      tag: 'gasp',
      ttsText: 'Oh! ',
      displayText: '*gasps*',
    ),
    VocalExpression(
      tag: 'hmm',
      ttsText: 'Hmmmm... ',
      displayText: '*hmm*',
    ),
    VocalExpression(
      tag: 'awe',
      ttsText: 'Awww... ',
      displayText: '*aww*',
    ),
    VocalExpression(
      tag: 'groan',
      ttsText: 'Uuugh... ',
      displayText: '*groans*',
    ),
    VocalExpression(
      tag: 'wow',
      ttsText: 'Woooow! ',
      displayText: '*wow*',
    ),
    VocalExpression(
      tag: 'yawn',
      ttsText: 'Ahhh-haaa... ',
      displayText: '*yawns*',
    ),
    VocalExpression(
      tag: 'scoff',
      ttsText: 'Pfff! ',
      displayText: '*scoffs*',
    ),
    VocalExpression(
      tag: 'excited',
      ttsText: 'Ooh! ',
      displayText: '*excited*',
    ),
    VocalExpression(
      tag: 'nervous-laugh',
      ttsText: 'Heh... ',
      displayText: '*nervous laugh*',
    ),
    VocalExpression(
      tag: 'tsk',
      ttsText: 'Tsk tsk. ',
      displayText: '*tsk*',
    ),
    VocalExpression(
      tag: 'whew',
      ttsText: 'Phew! ',
      displayText: '*whew*',
    ),
    VocalExpression(
      tag: 'snicker',
      ttsText: 'Heh heh heh! ',
      displayText: '*snickers*',
    ),
  ];

  static final Map<String, VocalExpression> _byTag = {
    for (final e in expressions) e.tag: e,
  };

  /// All available tag names for prompt documentation.
  static List<String> get availableTags =>
      expressions.map((e) => e.tag).toList();

  static const String _emphasisOpen = 'emphasis';
  static const String _emphasisClose = '/emphasis';

  // ---------------------------------------------------------------------------
  // Non-streaming (full-text) helpers
  // ---------------------------------------------------------------------------

  static final RegExp _tagPattern =
      RegExp(r'\{(' + expressions.map((e) => RegExp.escape(e.tag)).join('|') + r')\}');

  static final RegExp _emphasisPattern =
      RegExp(r'\{emphasis\}(.*?)\{/emphasis\}', dotAll: true);

  /// Replace all `{tag}` markers in [text] with their TTS phonetic text,
  /// and uppercase `{emphasis}...{/emphasis}` wrapped content.
  static String processForTts(String text) {
    var result = text.replaceAllMapped(
        _emphasisPattern, (m) => m.group(1)!.toUpperCase());
    result = result.replaceAllMapped(_tagPattern, (m) {
      final expr = _byTag[m.group(1)];
      return expr?.ttsText ?? m.group(0)!;
    });
    return result;
  }

  /// Strip `{tag}` and `{emphasis}/{/emphasis}` markers from [text] for
  /// clean UI display. Emphasized content is kept as-is (the emphasis is
  /// a vocal delivery cue, the words themselves are still meaningful).
  static String stripForDisplay(String text) {
    var result = text.replaceAllMapped(_emphasisPattern, (m) => m.group(1)!);
    result = result.replaceAllMapped(_tagPattern, (m) => '');
    return result;
  }

  // ---------------------------------------------------------------------------
  // Streaming-safe delta processor
  // ---------------------------------------------------------------------------

  /// Processes a single streaming text delta, handling expression tags that
  /// may be split across multiple deltas.
  ///
  /// Returns a record with `ttsText` (phonetic replacements applied) and
  /// `displayText` (tags stripped). The caller must keep the returned
  /// [StreamingExpressionState] and pass it back on the next delta.
  static ({String ttsText, String displayText, StreamingExpressionState state})
      processDelta(String delta, StreamingExpressionState state) {
    final ttsBuf = StringBuffer();
    final displayBuf = StringBuffer();
    var pending = state.pending;
    var emphasisActive = state.emphasisActive;

    for (int i = 0; i < delta.length; i++) {
      final ch = delta[i];

      if (pending != null) {
        // We're inside a `{...}` accumulation.
        pending += ch;
        if (ch == '}') {
          // Tag closed — resolve it.
          final tagName = pending.substring(1, pending.length - 1);
          if (tagName == _emphasisOpen) {
            emphasisActive = true;
          } else if (tagName == _emphasisClose) {
            emphasisActive = false;
          } else {
            final expr = _byTag[tagName];
            if (expr != null) {
              ttsBuf.write(expr.ttsText);
            } else {
              // Not a known expression — emit the raw text.
              ttsBuf.write(pending);
              displayBuf.write(pending);
            }
          }
          pending = null;
        } else if (pending.length > _maxTagLength) {
          // Too long to be a valid tag — flush as literal text.
          final flushed = emphasisActive ? pending.toUpperCase() : pending;
          ttsBuf.write(flushed);
          displayBuf.write(pending);
          pending = null;
        }
      } else if (ch == '{') {
        pending = '{';
      } else {
        ttsBuf.write(emphasisActive ? ch.toUpperCase() : ch);
        displayBuf.write(ch);
      }
    }

    return (
      ttsText: ttsBuf.toString(),
      displayText: displayBuf.toString(),
      state: StreamingExpressionState(
        pending: pending,
        emphasisActive: emphasisActive,
      ),
    );
  }

  /// Flush any remaining pending buffer (e.g. an incomplete `{tag` at
  /// end-of-stream). Returns both TTS and display versions.
  static ({String ttsText, String displayText}) flushPending(
      StreamingExpressionState state) {
    if (state.pending == null || state.pending!.isEmpty) {
      return (ttsText: '', displayText: '');
    }
    return (ttsText: state.pending!, displayText: state.pending!);
  }

  // Longest tag name + braces: `{/emphasis}` = 11 chars; `{nervous-laugh}` = 15.
  static const _maxTagLength = 20;
}

/// Mutable state carried across streaming deltas for expression parsing.
class StreamingExpressionState {
  String? pending;
  bool emphasisActive;
  StreamingExpressionState({this.pending, this.emphasisActive = false});
}
