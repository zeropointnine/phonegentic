/// Answering Machine / IVR detection for outbound calls.
///
/// Classifies incoming transcripts as human speech, automated IVR/voicemail
/// greeting, or ambiguous. Used by the settle-phase logic in [AgentService]
/// to decide when the agent should start speaking.

enum CallPartyType { human, ivr, ambiguous }

class IvrConfidence {
  final CallPartyType type;

  /// 0.0–1.0 confidence in the classification.
  final double score;

  /// If [type] is [CallPartyType.ivr], whether the message indicates a
  /// mailbox-full / undeliverable state where leaving a voicemail is pointless.
  final bool mailboxFull;

  /// If [type] is [CallPartyType.ivr], whether the transcript contains a
  /// "final sentence" signaling the greeting is about to end (e.g.
  /// "leave a message after the beep").
  final bool ivrEnding;

  const IvrConfidence({
    required this.type,
    required this.score,
    this.mailboxFull = false,
    this.ivrEnding = false,
  });

  @override
  String toString() =>
      'IvrConfidence(${type.name}, score=${score.toStringAsFixed(2)}, '
      'full=$mailboxFull, ending=$ivrEnding)';
}

class IvrDetector {
  IvrDetector._();

  // ---------------------------------------------------------------------------
  // Keyword / phrase tables
  // ---------------------------------------------------------------------------

  static const List<String> _ivrPhrases = <String>[
    'leave a message',
    'leave your message',
    'record your message',
    'after the tone',
    'after the beep',
    'at the tone',
    'at the beep',
    'not available',
    'currently unavailable',
    'is not available',
    'cannot come to the phone',
    "can't come to the phone",
    'please leave',
    'press 1',
    'press 2',
    'press 3',
    'press pound',
    'press star',
    'for english',
    'para espanol',
    'para español',
    'your call is important',
    'your call has been forwarded',
    'please hold',
    'please try again',
    'the person you are calling',
    'the number you have dialed',
    'the person you have called',
    'the mailbox',
    'voicemail',
    'voice mail',
    'the subscriber',
    'greeting',
    'extension',
    'automated attendant',
    'auto attendant',
    'directory',
    'if you know your party',
    "you've reached",
    'you have reached',
    'thank you for calling',
    'has not set up',
    'is not set up',
    'cannot be completed',
    'is not in service',
    'has been disconnected',
    'been changed',
    'new number is',
    'office hours',
    'business hours',
    'we are closed',
    'we are currently closed',
    'dial by name',
    'main menu',
    'hang up and try',
    'hang up and dial',
  ];

  static const List<String> _mailboxFullPhrases = <String>[
    'mailbox is full',
    'mailbox full',
    'memory is full',
    'cannot accept',
    'no longer accepting',
    'not accepting messages',
    'has not been set up',
    'is not set up',
    'has not set up their voicemail',
    'has not set up their voice mail',
    'not been set up',
    'cannot be completed as dialed',
    'is not in service',
    'has been disconnected',
    'been temporarily disconnected',
  ];

  static const List<String> _ivrEndingPhrases = <String>[
    'leave a message',
    'leave your message',
    'record your message',
    'after the tone',
    'after the beep',
    'at the tone',
    'at the beep',
    'begin speaking',
    'start speaking',
    'please leave a detailed message',
    'and we will get back',
    "and we'll get back",
    "and i'll get back",
    'and i will get back',
    'and someone will',
    'and we will return',
    "and we'll return",
  ];

  /// Short single-word or very short phrases that are strong human signals.
  static const List<String> _humanGreetings = <String>[
    'hello',
    'hi',
    'hey',
    'yo',
    'yeah',
    'yes',
    'yep',
    'yello',
    "what's up",
    'whats up',
    'sup',
    'good morning',
    'good afternoon',
    'good evening',
    'this is',
    'speaking',
    'go ahead',
    'uh huh',
  ];

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Quick boolean check — returns true if the transcript looks like an
  /// IVR / voicemail greeting. This is the legacy API used by existing
  /// call sites in AgentService.
  static bool isIvr(String text) {
    final IvrConfidence c = confidence(text);
    return c.type == CallPartyType.ivr;
  }

  /// Returns true if the text looks like a short human greeting.
  static bool isHumanGreeting(String text) {
    final IvrConfidence c = confidence(text);
    return c.type == CallPartyType.human;
  }

  /// Full confidence result combining keyword, phrase, and length heuristics.
  static IvrConfidence confidence(String text) {
    final String lower = text.toLowerCase().trim();
    if (lower.isEmpty) {
      return const IvrConfidence(
        type: CallPartyType.ambiguous,
        score: 0.0,
      );
    }

    final bool mailboxFull = _matchesAny(lower, _mailboxFullPhrases);
    final bool ivrEnding = _matchesAny(lower, _ivrEndingPhrases);

    // --- Strong IVR signals ---
    final int ivrHits = _countHits(lower, _ivrPhrases);
    if (ivrHits >= 2) {
      return IvrConfidence(
        type: CallPartyType.ivr,
        score: 1.0,
        mailboxFull: mailboxFull,
        ivrEnding: ivrEnding,
      );
    }
    if (ivrHits == 1) {
      final int wordCount = _wordCount(lower);
      // A single IVR phrase in a long utterance is very likely IVR.
      if (wordCount >= 8) {
        return IvrConfidence(
          type: CallPartyType.ivr,
          score: 0.9,
          mailboxFull: mailboxFull,
          ivrEnding: ivrEnding,
        );
      }
      // Short text with a single IVR phrase — high but not certain.
      return IvrConfidence(
        type: CallPartyType.ivr,
        score: 0.75,
        mailboxFull: mailboxFull,
        ivrEnding: ivrEnding,
      );
    }

    // Mailbox-full on its own is a strong IVR signal even without other hits.
    if (mailboxFull) {
      return IvrConfidence(
        type: CallPartyType.ivr,
        score: 0.95,
        mailboxFull: true,
        ivrEnding: ivrEnding,
      );
    }

    // --- Strong human signals ---
    final int humanHits = _countHits(lower, _humanGreetings);
    final int wordCount = _wordCount(lower);

    // Very short utterances (1-4 words) with a human greeting keyword.
    if (humanHits > 0 && wordCount <= 4) {
      return IvrConfidence(
        type: CallPartyType.human,
        score: 0.9,
        mailboxFull: false,
        ivrEnding: false,
      );
    }

    // Single word — likely human (e.g. "Hello?" or someone's name).
    if (wordCount == 1 && lower.length <= 12) {
      return const IvrConfidence(
        type: CallPartyType.human,
        score: 0.7,
      );
    }

    // Very short (2-3 words) with no IVR signal — lean human.
    if (wordCount <= 3 && ivrHits == 0) {
      return const IvrConfidence(
        type: CallPartyType.human,
        score: 0.6,
      );
    }

    // --- Length heuristic ---
    // Long utterances with no greeting words and no IVR keywords are ambiguous,
    // NOT IVR. Only the settling phase (via accumulatedConfidence) should use
    // length as a weak IVR signal; the post-settle isIvr() filter must not
    // discard normal conversational speech just because it's long.
    if (wordCount >= 15 && humanHits == 0) {
      return const IvrConfidence(
        type: CallPartyType.ambiguous,
        score: 0.5,
      );
    }

    // Everything else is ambiguous.
    return const IvrConfidence(
      type: CallPartyType.ambiguous,
      score: 0.5,
    );
  }

  /// Analyze accumulated text from the entire settle phase, providing a
  /// higher-accuracy classification than single-transcript analysis.
  static IvrConfidence accumulatedConfidence(List<String> transcripts) {
    if (transcripts.isEmpty) {
      return const IvrConfidence(type: CallPartyType.ambiguous, score: 0.0);
    }

    final String combined = transcripts.join(' ').toLowerCase().trim();
    final int totalWords = _wordCount(combined);
    final int ivrHits = _countHits(combined, _ivrPhrases);
    final int humanHits = _countHits(combined, _humanGreetings);
    final bool mailboxFull = _matchesAny(combined, _mailboxFullPhrases);
    final bool ivrEnding = _matchesAny(combined, _ivrEndingPhrases);

    if (mailboxFull) {
      return IvrConfidence(
        type: CallPartyType.ivr,
        score: 0.95,
        mailboxFull: true,
        ivrEnding: ivrEnding,
      );
    }

    // Multiple IVR phrase hits across accumulated text — very confident.
    if (ivrHits >= 2) {
      return IvrConfidence(
        type: CallPartyType.ivr,
        score: 1.0,
        mailboxFull: false,
        ivrEnding: ivrEnding,
      );
    }

    // One IVR hit + long accumulated text = likely IVR.
    if (ivrHits == 1 && totalWords >= 10) {
      return IvrConfidence(
        type: CallPartyType.ivr,
        score: 0.85,
        mailboxFull: false,
        ivrEnding: ivrEnding,
      );
    }

    // Short total with human greeting signals — human.
    if (humanHits > 0 && totalWords <= 6) {
      return const IvrConfidence(type: CallPartyType.human, score: 0.85);
    }

    // Long accumulated text, no IVR hits, but also no human greetings.
    if (totalWords >= 20 && ivrHits == 0 && humanHits == 0) {
      return IvrConfidence(
        type: CallPartyType.ivr,
        score: 0.55,
        mailboxFull: false,
        ivrEnding: ivrEnding,
      );
    }

    return const IvrConfidence(type: CallPartyType.ambiguous, score: 0.5);
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  static bool _matchesAny(String lower, List<String> phrases) {
    for (final String phrase in phrases) {
      if (lower.contains(phrase)) return true;
    }
    return false;
  }

  static int _countHits(String lower, List<String> phrases) {
    int count = 0;
    for (final String phrase in phrases) {
      if (lower.contains(phrase)) count++;
    }
    return count;
  }

  static int _wordCount(String text) {
    if (text.isEmpty) return 0;
    return text.split(RegExp(r'\s+')).where((String w) => w.isNotEmpty).length;
  }
}
