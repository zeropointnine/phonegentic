/// Streaming sentence boundary detector for TTS chunking.
///
/// Accumulates streaming text deltas (e.g. from Claude SSE) and emits
/// complete sentences/phrases suitable for incremental TTS synthesis.
///
/// Inspired by tts-toy's text_segmenter.py + sentence_segmenter.py:
///   - Detects sentence endings (. ? ! …) while skipping abbreviations
///   - Splits long sentences (>maxWords) at phrase boundaries (, ; :)
///
/// Usage:
///   final seg = TextSegmenter();
///   for (final delta in claudeDeltas) {
///     for (final sentence in seg.addText(delta)) {
///       tts.synthesize(sentence);
///     }
///   }
///   final remainder = seg.flush();
///   if (remainder != null) tts.synthesize(remainder);
class TextSegmenter {
  String _buffer = '';
  final int maxWords;

  TextSegmenter({this.maxWords = 25});

  static final _abbreviations = RegExp(
    r'(?:Mr|Mrs|Ms|Dr|Prof|Sr|Jr|St|vs|etc|e\.g|i\.e|[A-Z])\.$',
  );

  /// Feed a streaming text chunk. Returns any complete sentences/phrases
  /// detected so far (may be empty if the buffer is still mid-sentence).
  List<String> addText(String chunk) {
    if (chunk.isEmpty) return const [];
    _buffer += chunk;
    return _extractSentences();
  }

  /// Return and clear any remaining buffered text. Call this when the
  /// LLM stream is finished (endGeneration). Returns null if empty.
  String? flush() {
    final text = _buffer.trim();
    _buffer = '';
    return text.isEmpty ? null : text;
  }

  /// Reset the segmenter, discarding any buffered text.
  void reset() {
    _buffer = '';
  }

  // ─────────────────────── sentence extraction ───────────────────────

  List<String> _extractSentences() {
    final results = <String>[];

    while (true) {
      final idx = _findSentenceEnd(_buffer);
      if (idx < 0) break;

      final sentence = _buffer.substring(0, idx + 1).trim();
      _buffer = _buffer.substring(idx + 1);

      if (sentence.isEmpty) continue;

      // Split long sentences into phrases for lower TTS latency.
      final phrases = _splitLongSentence(sentence);
      results.addAll(phrases);
    }

    // Overflow: if the buffer exceeds maxWords without a sentence terminator,
    // force-flush at the nearest phrase boundary so TTS doesn't stall.
    if (_buffer.split(RegExp(r'\s+')).length > maxWords) {
      final splitIdx = _findPhraseSplitPoint(_buffer);
      if (splitIdx > 0 && splitIdx < _buffer.length) {
        final phrase = _buffer.substring(0, splitIdx).trim();
        _buffer = _buffer.substring(splitIdx).trimLeft();
        if (phrase.isNotEmpty) results.add(phrase);
      }
    }

    return results;
  }

  /// Find the character index of the end of the first complete sentence
  /// in [text], or -1 if none found. A sentence ends at a terminator
  /// (. ? ! or …) followed by whitespace (proving the next token started),
  /// unless the terminator is part of a known abbreviation.
  int _findSentenceEnd(String text) {
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];

      // Ellipsis (Unicode character)
      if (ch == '\u2026') {
        if (_hasFollowingWhitespace(text, i)) return i;
        continue;
      }

      // Three-dot ellipsis
      if (ch == '.' &&
          i + 2 < text.length &&
          text[i + 1] == '.' &&
          text[i + 2] == '.') {
        if (_hasFollowingWhitespace(text, i + 2)) return i + 2;
        i += 2;
        continue;
      }

      if (ch == '.' || ch == '?' || ch == '!') {
        // Must have something after the terminator to confirm it's a boundary
        // (otherwise we might be mid-sentence at the buffer edge).
        if (!_hasFollowingWhitespace(text, i)) continue;

        // Skip abbreviations like "Mr." "Dr." "e.g." etc.
        if (ch == '.' && _isAbbreviation(text, i)) continue;

        return i;
      }
    }
    return -1;
  }

  /// True if position [i] is followed by at least one whitespace character.
  bool _hasFollowingWhitespace(String text, int i) {
    if (i + 1 >= text.length) return false;
    final next = text.codeUnitAt(i + 1);
    // space, \n, \r, \t
    return next == 0x20 || next == 0x0A || next == 0x0D || next == 0x09;
  }

  /// Check whether the period at [dotIndex] is part of a known abbreviation.
  bool _isAbbreviation(String text, int dotIndex) {
    // Grab up to 10 chars before the dot + the dot itself for matching.
    final start = (dotIndex - 10).clamp(0, dotIndex);
    final prefix = text.substring(start, dotIndex + 1);
    return _abbreviations.hasMatch(prefix);
  }

  // ───────────────────────── phrase splitting ─────────────────────────

  /// Split a sentence into phrases if it exceeds [maxWords].
  /// Prefers splitting at punctuation (, ; :) near the midpoint.
  List<String> _splitLongSentence(String sentence) {
    final words = sentence.split(RegExp(r'\s+'));
    if (words.length <= maxWords) return [sentence];

    final results = <String>[];
    var remaining = sentence;

    while (remaining.split(RegExp(r'\s+')).length > maxWords) {
      final splitIdx = _findPhraseSplitPoint(remaining);
      if (splitIdx <= 0 || splitIdx >= remaining.length) {
        break;
      }
      final phrase = remaining.substring(0, splitIdx).trimRight();
      if (phrase.isNotEmpty) results.add(phrase);
      remaining = remaining.substring(splitIdx).trimLeft();
    }

    if (remaining.trim().isNotEmpty) {
      results.add(remaining.trim());
    }

    return results.isEmpty ? [sentence] : results;
  }

  /// Find the best character index to split [text] that's too long.
  /// Prioritizes , ; : near the middle, then any space near the middle,
  /// then falls back to the space after [maxWords] words.
  int _findPhraseSplitPoint(String text) {
    final mid = text.length ~/ 2;
    final radius = (text.length ~/ 4).clamp(20, text.length ~/ 2);
    final searchStart = (mid - radius).clamp(0, text.length);
    final searchEnd = (mid + radius).clamp(0, text.length);

    // 1. Look for , ; : nearest to the midpoint
    int bestPunc = -1;
    int bestPuncDist = text.length;
    for (var i = searchStart; i < searchEnd; i++) {
      final ch = text[i];
      if (ch == ',' || ch == ';' || ch == ':') {
        final splitAt = i + 1;
        final dist = (splitAt - mid).abs();
        if (dist < bestPuncDist) {
          bestPuncDist = dist;
          bestPunc = splitAt;
        }
      }
    }
    if (bestPunc > 0) return bestPunc;

    // 2. Look for whitespace nearest to the midpoint
    int bestSpace = -1;
    int bestSpaceDist = text.length;
    for (var i = searchStart; i < searchEnd; i++) {
      if (text[i] == ' ') {
        final splitAt = i + 1;
        final dist = (splitAt - mid).abs();
        if (dist < bestSpaceDist) {
          bestSpaceDist = dist;
          bestSpace = splitAt;
        }
      }
    }
    if (bestSpace > 0) return bestSpace;

    // 3. Fallback: split after maxWords words
    var wordCount = 0;
    var inWord = false;
    for (var i = 0; i < text.length; i++) {
      final isSpace = text[i] == ' ' || text[i] == '\t' || text[i] == '\n';
      if (!isSpace && !inWord) {
        inWord = true;
        wordCount++;
        if (wordCount > maxWords) return i;
      } else if (isSpace) {
        inWord = false;
      }
    }

    return -1;
  }
}
