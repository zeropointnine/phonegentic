import 'models/sms_message.dart';

/// Canonical tapback emojis we map to Apple-style verbs (iOS-to-Android
/// fallback). Anything else goes through the custom `<emoji> to "…"` form.
const Map<String, String> _emojiToVerb = {
  '❤️': 'Loved',
  '👍': 'Liked',
  '👎': 'Disliked',
  '😂': 'Laughed at',
  '‼️': 'Emphasized',
  '❓': 'Questioned',
};

const Map<String, String> _verbToEmoji = {
  'Loved': '❤️',
  'Liked': '👍',
  'Disliked': '👎',
  'Laughed at': '😂',
  'Emphasized': '‼️',
  'Questioned': '❓',
};

// iOS Messages uses curly "smart" quotes for tapback fallbacks (U+201C / U+201D
// for doubles, U+2018 / U+2019 for singles). We accept both straight and
// curly variants so taps from real iPhones round-trip cleanly.
const _openQuote = r'["\u201C\u201D]';
const _closeQuote = r'["\u201C\u201D]';

final _appleVerbPattern = RegExp(
  '^(Loved|Liked|Disliked|Laughed at|Emphasized|Questioned)\\s+$_openQuote(.+)$_closeQuote\\s*\$',
  dotAll: true,
);

final _customEmojiPattern = RegExp(
  '^(\\S+?)\\s+to\\s+$_openQuote(.+)$_closeQuote\\s*\$',
  dotAll: true,
);

final _replyQuotePattern = RegExp(
  '^→\\s+$_openQuote(.+?)$_closeQuote\\s*(?:\\n\\n|\\n)(.*)\$',
  dotAll: true,
);

/// Serialized outbound representation of a tapback.
class ReactionFallback {
  final String wireText;
  const ReactionFallback(this.wireText);
}

/// Parsed inbound detection result.
sealed class ParsedInbound {
  const ParsedInbound();
}

class PlainInbound extends ParsedInbound {
  const PlainInbound();
}

class ReactionInbound extends ParsedInbound {
  final String emoji;
  final SmsMessage target;
  const ReactionInbound({required this.emoji, required this.target});
}

class ReplyInbound extends ParsedInbound {
  final SmsMessage target;

  /// The inbound body with the `→ "…"` quote line stripped off. The raw
  /// wire body stays on disk; the UI renders the quote via chrome.
  final String stripped;

  const ReplyInbound({
    required this.target,
    required this.stripped,
  });
}

class ReactionReplyParser {
  ReactionReplyParser._();

  static const int _quoteMaxChars = 80;

  /// Build the outbound wire body for a tapback of [emoji] on [target].
  static ReactionFallback buildTapbackWire({
    required String emoji,
    required SmsMessage target,
  }) {
    final orig = _truncate(target.text, _quoteMaxChars);
    final verb = _emojiToVerb[emoji];
    if (verb != null) {
      return ReactionFallback('$verb "$orig"');
    }
    return ReactionFallback('$emoji to "$orig"');
  }

  /// Build the outbound wire body for a reply quoting [target] then the
  /// user-typed [userText].
  static String buildReplyWire({
    required SmsMessage target,
    required String userText,
  }) {
    final orig = _truncate(target.text, _quoteMaxChars);
    return '→ "$orig"\n\n$userText';
  }

  /// Look at an inbound body and try to match it against a tapback or a
  /// reply. [history] is the recent-first list of messages in the same
  /// thread (bounded; caller can cap to ~50).
  static ParsedInbound parseInbound({
    required String body,
    required List<SmsMessage> history,
  }) {
    final trimmed = body.trim();

    final appleMatch = _appleVerbPattern.firstMatch(trimmed);
    if (appleMatch != null) {
      final verb = appleMatch.group(1)!;
      final quoted = appleMatch.group(2)!.trim();
      final emoji = _verbToEmoji[verb]!;
      final target = _findByQuote(history, quoted);
      if (target != null) {
        return ReactionInbound(emoji: emoji, target: target);
      }
    }

    final replyMatch = _replyQuotePattern.firstMatch(trimmed);
    if (replyMatch != null) {
      final quoted = replyMatch.group(1)!.trim();
      final rest = (replyMatch.group(2) ?? '').trim();
      final target = _findByQuote(history, quoted);
      if (target != null) {
        return ReplyInbound(target: target, stripped: rest);
      }
    }

    final customMatch = _customEmojiPattern.firstMatch(trimmed);
    if (customMatch != null) {
      final head = customMatch.group(1)!.trim();
      final quoted = customMatch.group(2)!.trim();
      if (_looksLikeEmoji(head)) {
        final target = _findByQuote(history, quoted);
        if (target != null) {
          return ReactionInbound(emoji: head, target: target);
        }
      }
    }

    return const PlainInbound();
  }

  /// Attempt to match [quoted] against [history] (case-insensitive, trimmed;
  /// accepts a prefix match because the wire truncates to ~80 chars).
  /// Both sides are normalized so smart/straight quote mismatches don't
  /// cause false negatives (iOS sends curly quotes inside the quoted body
  /// too).
  static SmsMessage? _findByQuote(List<SmsMessage> history, String quoted) {
    final needle = _normalizeQuotes(quoted.trim()).toLowerCase();
    if (needle.isEmpty) return null;
    for (final m in history) {
      if (m.text.isEmpty) continue;
      final hay = _normalizeQuotes(m.text.trim()).toLowerCase();
      if (hay == needle || hay.startsWith(needle) || needle.startsWith(hay)) {
        return m;
      }
    }
    return null;
  }

  static String _normalizeQuotes(String s) {
    return s
        .replaceAll('\u201C', '"')
        .replaceAll('\u201D', '"')
        .replaceAll('\u2018', "'")
        .replaceAll('\u2019', "'")
        .replaceAll('\u2026', '...');
  }

  static String _truncate(String s, int max) {
    final trimmed = s.trim();
    if (trimmed.length <= max) return trimmed;
    return '${trimmed.substring(0, max - 1)}…';
  }

  /// Cheap "does this codepoint look like an emoji" guard to avoid false
  /// positives on every `word to "…"` message.
  static bool _looksLikeEmoji(String s) {
    if (s.isEmpty) return false;
    final runes = s.runes.toList();
    for (final r in runes) {
      if (r >= 0x1F000 && r <= 0x1FFFF) return true;
      if (r >= 0x2600 && r <= 0x27BF) return true;
      if (r >= 0x2700 && r <= 0x27BF) return true;
      if (r == 0x203C || r == 0x2049) return true;
    }
    return false;
  }

  /// Exposed for UI / tests.
  static Iterable<String> get canonicalTapbacks => _emojiToVerb.keys;
}
