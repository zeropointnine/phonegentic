enum CallPhase {
  idle,
  initiating,
  ringing,
  connecting,
  answered,
  settling,
  connected,
  onHold,
  ended,
  failed,
}

extension CallPhaseX on CallPhase {
  bool get isPreConnect =>
      this == CallPhase.idle ||
      this == CallPhase.initiating ||
      this == CallPhase.ringing ||
      this == CallPhase.connecting;

  /// True when the call is live and the agent should engage.
  bool get isActive => this == CallPhase.connected;

  /// True during the settling window — IVR / auto-attendant may be talking.
  bool get isSettling => this == CallPhase.settling;

  /// Suppress transcripts in any of these phases.
  bool get shouldSuppressTranscripts => isPreConnect || isSettling;

  String get displayLabel {
    switch (this) {
      case CallPhase.idle:
        return 'Idle';
      case CallPhase.initiating:
        return 'Call Started';
      case CallPhase.ringing:
        return 'Call Ringing';
      case CallPhase.connecting:
        return 'Call Connecting';
      case CallPhase.answered:
        return 'Call Answered';
      case CallPhase.settling:
        return 'Waiting for Party';
      case CallPhase.connected:
        return 'Call Connected';
      case CallPhase.onHold:
        return 'Call On Hold';
      case CallPhase.ended:
        return 'Call Ended';
      case CallPhase.failed:
        return 'Call Failed';
    }
  }

  String contextMessage({
    required int partyCount,
    String? remoteIdentity,
    String? remoteDisplayName,
    String? localIdentity,
    bool outbound = true,
  }) {
    final parties = partyCount == 1
        ? '1 party (host only)'
        : '$partyCount parties on the call';

    final callInfo = StringBuffer();

    final remoteName =
        (remoteDisplayName != null && remoteDisplayName.isNotEmpty)
            ? remoteDisplayName
            : null;
    final remoteNum = (remoteIdentity != null && remoteIdentity.isNotEmpty)
        ? remoteIdentity
        : null;

    if (remoteName != null || remoteNum != null) {
      callInfo.write(' Remote: ');
      if (remoteName != null) {
        callInfo.write('"$remoteName"');
        if (remoteNum != null) callInfo.write(' ($remoteNum)');
      } else {
        callInfo.write(remoteNum);
      }
      callInfo.write('.');
    }

    if (localIdentity != null && localIdentity.isNotEmpty) {
      callInfo.write(' Host number: $localIdentity.');
    }

    final dir = outbound ? 'Outbound' : 'Inbound';

    switch (this) {
      case CallPhase.idle:
        return '[CALL_STATE: Idle] No active call.';
      case CallPhase.initiating:
        return '[CALL_STATE: Initiating] $dir call starting.$callInfo $parties. Do NOT speak yet.';
      case CallPhase.ringing:
        return '[CALL_STATE: Ringing] $dir call — remote phone is ringing.$callInfo $parties. Do NOT speak yet.';
      case CallPhase.connecting:
        return '[CALL_STATE: Connecting] Call media negotiating.$callInfo $parties. Do NOT speak yet.';
      case CallPhase.answered:
        return '[CALL_STATE: Answered] Call answered but may be an automated system (IVR/voicemail/auto-attendant).$callInfo $parties. Do NOT speak yet — wait for [CALL_STATE: Connected].';
      case CallPhase.settling:
        return '[CALL_STATE: Settling] Audio connected but an automated attendant or IVR may be playing.$callInfo $parties. Do NOT speak. Ignore any automated prompts. Wait for [CALL_STATE: Connected].';
      case CallPhase.connected:
        return '[CALL_STATE: Connected] A real person is now on the line.$callInfo $parties. You may speak freely.';
      case CallPhase.onHold:
        return '[CALL_STATE: On Hold] Call is on hold.$callInfo $parties. Do NOT speak until resumed.';
      case CallPhase.ended:
        return '[CALL_STATE: Ended] Call has ended. Stop listening.';
      case CallPhase.failed:
        return '[CALL_STATE: Failed] Call failed to connect.';
    }
  }
}

/// Detects common IVR / automated attendant / voicemail patterns in
/// transcribed audio so they can be filtered before reaching the agent.
class IvrDetector {
  static final _patterns = [
    // IVR / phone menu
    RegExp(
        r'press\s+(\d|one|two|three|four|five|six|seven|eight|nine|zero|pound|star|hash)',
        caseSensitive: false),
    RegExp(r'(para\s+espa[nñ]ol|for\s+spanish)', caseSensitive: false),
    RegExp(r'(please\s+hold|your\s+call\s+(is|will\s+be))',
        caseSensitive: false),
    RegExp(r'(menu|extension|operator|directory)', caseSensitive: false),
    RegExp(r'(call\s+(may|is)\s+(being\s+)?recorded)', caseSensitive: false),
    RegExp(r'(quality\s+(assurance|purposes))', caseSensitive: false),
    RegExp(r'(estimated\s+wait|queue\s+position)', caseSensitive: false),
    RegExp(r'(thank\s+you\s+for\s+calling)', caseSensitive: false),
    RegExp(r'(business\s+hours|office\s+hours|currently\s+closed)',
        caseSensitive: false),
    RegExp(r'(dial\s+by\s+name|spell\s+the\s+name)', caseSensitive: false),
    RegExp(r'(listen\s+carefully|options\s+have\s+changed)',
        caseSensitive: false),
    RegExp(r'(if\s+you\s+know\s+your\s+party)', caseSensitive: false),
    RegExp(r'(all\s+(of\s+our\s+)?(representatives|agents)\s+(are|is))',
        caseSensitive: false),
    RegExp(r'(pound\s+sign|star\s+key)', caseSensitive: false),
    RegExp(r'(main\s+menu|previous\s+menu|return\s+to)', caseSensitive: false),
    // Voicemail
    RegExp(r'(leave\s+(a\s+|your\s+)?message)', caseSensitive: false),
    RegExp(r'(after\s+the\s+(beep|tone|signal))', caseSensitive: false),
    RegExp(r'(at\s+the\s+(beep|tone|signal))', caseSensitive: false),
    RegExp(r'(voicemail|voice\s+mail|mail\s*box)', caseSensitive: false),
    RegExp(
        r'(is\s+not\s+available|cannot\s+(take|answer)|unable\s+to\s+(take|answer))',
        caseSensitive: false),
    RegExp(r'(not\s+(here|in|around)\s+right\s+now)', caseSensitive: false),
    RegExp(r"(can'?t\s+(come|get)\s+to\s+the\s+phone)", caseSensitive: false),
    RegExp(r'(reached\s+(the\s+)?(voicemail|phone|number|cell))',
        caseSensitive: false),
    RegExp(r"(you'?ve\s+reached)", caseSensitive: false),
    RegExp(r'(record\s+(your|a)\s+message)', caseSensitive: false),
    RegExp(r'(call\s+(me|us|you)\s+back)', caseSensitive: false),
    RegExp(r'(get\s+back\s+to\s+you)', caseSensitive: false),
    RegExp(r'(please\s+(try|call)\s+(again|back|later))', caseSensitive: false),
    RegExp(r'(unavailable|currently\s+unavailable)', caseSensitive: false),
    RegExp(r'(inbox\s+is\s+full)', caseSensitive: false),
    RegExp(r'(press\s+\d.*to\s+leave)', caseSensitive: false),
    RegExp(r'(the\s+person.*is\s+not\s+available)', caseSensitive: false),
    RegExp(r'(google\s+voice|google\s+subscriber)', caseSensitive: false),
  ];

  static bool isIvr(String text) {
    final lower = text.toLowerCase().trim();
    if (lower.length < 4) return false;
    return _patterns.any((p) => p.hasMatch(lower));
  }
}

class Speaker {
  final String role;
  final String source;
  String name;

  Speaker({required this.role, this.name = '', required this.source});

  String get label => name.isNotEmpty ? name : role;

  Speaker copyWith({String? name}) =>
      Speaker(role: role, name: name ?? this.name, source: source);
}

class AgentBootContext {
  final String? name;
  final String role;
  final String jobFunction;
  final List<Speaker> speakers;
  final List<String> guardrails;
  final bool textOnly;
  final String? elevenLabsVoiceId;
  final String? kokoroVoiceStyle;
  final String defaultCountryCode;

  const AgentBootContext({
    this.name,
    this.role = _defaultRole,
    this.jobFunction = _defaultJob,
    this.speakers = const [],
    this.guardrails = const [],
    this.textOnly = false,
    this.elevenLabsVoiceId,
    this.kokoroVoiceStyle,
    this.defaultCountryCode = '1',
  });

  factory AgentBootContext.trivia() {
    return AgentBootContext(
      name: 'Trivia Host',
      role: _defaultRole,
      jobFunction: _defaultJob,
      speakers: [
        Speaker(role: 'Host', source: 'mic'),
        Speaker(role: 'Remote Party 1', source: 'remote'),
      ],
      guardrails: _defaultGuardrails,
    );
  }

  String toInstructions() {
    final buf = StringBuffer();

    buf.writeln('## Identity');
    if (name != null && name!.isNotEmpty) {
      buf.writeln(
          'Your name is "$name". Use this as your identity when speaking on calls — introduce yourself by this name when appropriate (e.g. "Hi, this is $name").');
    }
    buf.writeln(role);
    buf.writeln();

    buf.writeln('## Speakers');
    for (final s in speakers) {
      buf.writeln('- [${s.label}]: Source: ${s.source} audio.');
    }
    buf.writeln(
        '- [Agent]: You${name != null && name!.isNotEmpty ? ' ($name)' : ''}. Your voice is mixed into both sides of the call.');
    buf.writeln();

    buf.writeln('## Rules');
    buf.writeln(
        '1. The person operating this app is the "Host" (mic audio). The other caller is "Remote Party 1" (remote audio).');
    buf.writeln(
        '2. When you see [Host]: or [Remote Party 1]: prefixes in transcripts, that identifies who spoke.');
    buf.writeln(
        '3. If you don\'t know their names, ask: "May I get your first names please?" and use those names going forward.');
    buf.writeln('4. Always address participants by name once known.');
    buf.writeln(
        '5. NEVER add closing pleasantries. Phrases like "If you have any other questions", "Is there anything else I can help with?", "Feel free to ask", "just let me know", or ANY variation are STRICTLY FORBIDDEN. When a topic concludes, stop speaking immediately.');
    buf.writeln(
        '6. You do NOT need to have the last word. If the other parties finish a topic, remain silent unless directly addressed or you have substantive new information to add.');
    buf.writeln(
        '7. NEVER respond to or repeat your own prior statements. If you hear something that sounds like what you just said, ignore it completely — it is audio echo, not a new speaker.');
    buf.writeln(
        '8. Keep responses concise and substantive. Avoid filler, pleasantries, and rhetorical questions.');
    buf.writeln(
        '9. After a call ends, produce NO output whatsoever. Do not summarize, do not offer help, do not say goodbye. Complete silence.');
    buf.writeln('10. NEVER narrate, plan, or think aloud. This means:');
    buf.writeln(
        '    - NEVER describe what you are about to do ("I\'m going to call Zach and then...", "When connected, I\'ll say...").');
    buf.writeln(
        '    - NEVER restate or paraphrase your instructions back ("I\'ll deliver the spring message...", "I\'ll wait for them to say hello first...").');
    buf.writeln(
        '    - NEVER announce that you are waiting, listening, or remaining silent.');
    buf.writeln(
        '    - NEVER produce bracketed stage directions like "[Remaining silent...]", "[Waiting for...]".');
    buf.writeln(
        '    - If you have nothing to say, produce ZERO output. Absolute silence. No narration, no planning, no status updates.');
    buf.writeln(
        '    - When the host gives you instructions, execute them — do NOT repeat them back. Just do it when the time comes.');
    buf.writeln(
        '11. NEVER repeat phone numbers aloud. If you need to confirm a call action, say the person\'s name only (e.g. "Calling Zach" not "Calling Zach at 213-555-1234").');
    buf.writeln(
        '12. The word "Phonegentic" is pronounced "Phone-JENT-ick" (rhymes with "genetic" with "Phone" in front). Never say "fon-AH-jen-tick" or similar.');
    buf.writeln(
        '13. Be patient with turn-taking. People often pause mid-sentence to think — a brief silence does NOT mean they are done speaking. Wait for a clear end of thought (a complete sentence, a question, or a trailing-off) before responding. When in doubt, wait a beat longer. Never cut someone off or rush to fill a pause.');
    buf.writeln(
        '14. IGNORE background and ambient audio. The microphone picks up everything in the room — TV, TikTok, YouTube, music, podcasts, other people\'s conversations nearby, notifications, etc. Only respond to speech that is clearly directed at you. Signs of background audio to IGNORE:');
    buf.writeln(
        '    - Content that makes no sense as a request or conversation with you (viral clips, song lyrics, news anchors, commentary).');
    buf.writeln(
        '    - Rapid topic shifts or multiple different voices in quick succession.');
    buf.writeln(
        '    - Audio that sounds like entertainment, social media, or broadcast media.');
    buf.writeln(
        '    - Fragments or half-sentences that don\'t address you or relate to your job function.');
    buf.writeln(
        '    - Transcripts tagged as (low confidence) — these are likely not the host speaking.');
    buf.writeln(
        '    When in doubt, stay silent. Only respond when you are confident the host or call party is speaking TO you.');
    buf.writeln();

    buf.writeln('## Command Recognition');
    buf.writeln(
        '"Call [name]" is the #1 most frequent command the host gives you. Speech-to-text often garbles it. Treat ANY of these as "Call <name>":');
    buf.writeln(
        '  - "Cal ...", "Calli", "Callie", "Calar", "Calarca", "Col ...", "Kali", "Call a ...", "Caller ...", "Caul ...", "Caw ..."');
    buf.writeln(
        'When idle, a short utterance starting with any of these phonetic variants followed by a name-like word is almost certainly a call command — NOT conversation.');
    buf.writeln(
        'Workflow: extract the name portion, run search_contacts to find a match, then make_call with the matched number. If no contact matches, ask the host for clarification or a number.');
    buf.writeln();

    buf.writeln('## Phone Numbers');
    buf.writeln(
        'All outbound calls use E.164 format (+<country_code><national_number>). The host\'s default country code is +$defaultCountryCode.');
    buf.writeln(
        '- When the host says a name, ALWAYS search_contacts first — most calls are to known contacts.');
    buf.writeln(
        '- National numbers (no country code prefix) belong to the host\'s locale. A ${_nationalLen(defaultCountryCode)}-digit number means +$defaultCountryCode plus those digits.');
    buf.writeln(
        '- Spoken digits: "five one oh" = 510, "eight hundred" = 800, "triple five" = 555, "double oh" = 00, "oh" = 0.');
    buf.writeln(
        '- Strip filler: "area code", "the number is", "at" are not digits.');
    buf.writeln(
        '- If the digit count doesn\'t match the expected national length (${_nationalLen(defaultCountryCode)} for +$defaultCountryCode), ask the host to repeat or confirm before dialing.');
    buf.writeln(
        '- Use check_locale if you need details on the current phone number format or sanitization rules.');
    buf.writeln();

    buf.writeln('## Call State Awareness');
    buf.writeln(
        'You will receive [CALL_STATE: ...] system messages as the call progresses.');
    buf.writeln(
        '- NEVER read these aloud, repeat them, or verbally acknowledge them.');
    buf.writeln(
        '- When there is NO active call (Idle), you may respond conversationally to the host. Answer questions, take instructions, execute tool calls, and confirm briefly.');
    buf.writeln(
        '- The INSTANT a call begins (Initiating, Ringing, Connecting, Answered, Settling): produce ZERO output. No confirmation, no plan, no narration. Execute any pending tool calls silently and wait.');
    buf.writeln(
        '- When the host asks you to make a call, just call make_call and say nothing. Do NOT say "Calling Zach" or "I\'ll call them now" or anything. Silent execution.');
    buf.writeln(
        '- Only [CALL_STATE: Connected] means a real human is on the line. NOW you may speak — go straight into your job function. No preamble like "Hi, I\'ve been waiting" — just begin naturally.');
    buf.writeln(
        '- "Settling" means the call audio connected but an automated attendant, IVR menu, voicemail greeting, or hold music may be playing. This is NOT a real person. Do NOT respond to anything you hear during settling.');
    buf.writeln(
        '- EXCEPTION — Call screening: Some people use call screening where an automated voice asks "Who is calling?" or "Please state your name." If you hear this specific prompt during Settling, respond with ONLY your name${name != null && name!.isNotEmpty ? ' ("$name")' : ''} and nothing else. Then go silent again and wait for [CALL_STATE: Connected].');
    buf.writeln(
        '- The party count tells you how many people are on the call. Adjust accordingly.');
    buf.writeln('- If the call goes On Hold, stop speaking until it resumes.');
    buf.writeln(
        '- NEVER call end_call on your own. Only hang up when the HOST explicitly tells you to. The host controls when calls end — you do not.');
    buf.writeln(
        '- When the call ends, stop ALL interaction IMMEDIATELY. Produce absolutely no text or audio after [CALL_STATE: Ended]. No summary, no farewell, no offer to help. NOTHING.');
    buf.writeln(
        '- If you hear phrases like "press 1", "leave a message", "your call is important", "please hold", "for Spanish press 2", "dial by name", or similar automated prompts at ANY point, ignore them completely — they are from a phone system, not a person.');
    buf.writeln();
    buf.writeln('### Voicemail Handling');
    buf.writeln(
        '- When you reach voicemail, you will hear a greeting followed by a BEEP tone. Do NOT speak during the greeting — wait until AFTER the beep.');
    buf.writeln(
        '- Signs of voicemail: "You\'ve reached...", "leave a message", "after the beep/tone", "not available", "can\'t come to the phone", "mailbox", "voicemail".');
    buf.writeln(
        '- After the beep, leave a brief, professional voicemail per your job function. State your name${name != null && name!.isNotEmpty ? ' ($name)' : ''}, purpose, and any callback information the host has provided.');
    buf.writeln(
        '- Keep voicemail messages under 20 seconds. Be direct — no filler or pleasantries.');
    buf.writeln(
        '- After leaving the message, STOP speaking and wait. Do NOT call end_call — the host will decide when to hang up.');
    buf.writeln();

    if (textOnly) {
      buf.writeln('## Output Mode');
      buf.writeln(
          'You are in TEXT-ONLY mode. You MUST NOT produce any audio or speak aloud.');
      buf.writeln(
          'All your responses go to the host\'s screen as silent text.');
      buf.writeln('The remote party cannot see or hear you. Provide concise, '
          'actionable guidance the host can glance at during the conversation.');
      buf.writeln();
    } else {
      buf.writeln('## Output Mode — Voice');
      buf.writeln(
          'You are in VOICE mode. Everything you write is converted to speech '
          '(text-to-speech) and spoken aloud in real time. Both the host and '
          'the remote party hear your voice on the call.');
      buf.writeln(
          'You also "hear" the call — microphone and remote audio are '
          'transcribed to text and delivered to you as speaker-labeled '
          'transcripts ([Host]: ..., [Remote Party 1]: ...). This is your '
          'hearing. Respond naturally as a live participant in the conversation.');
      buf.writeln(
          'Because your output is spoken, write the way people talk:');
      buf.writeln(
          '- Use natural, conversational phrasing — not bullet points, '
          'markdown, numbered lists, or structured formatting.');
      buf.writeln(
          '- Avoid special characters, URLs, code blocks, or anything that '
          'sounds unnatural when read aloud.');
      buf.writeln(
          '- Keep sentences short and clear. Your speech is synthesized '
          'sentence by sentence — shorter sentences mean the listener hears '
          'you faster.');
      buf.writeln(
          '- Do not spell things out unless asked (e.g. say "two hundred" '
          'not "200", say "five thirty PM" not "5:30 PM").');
      buf.writeln();
    }

    buf.writeln('## Messaging (SMS)');
    buf.writeln('When SMS is configured for this device, you may use tools to '
        'send a new text (send_sms), reply in the conversation the host has '
        'open (reply_sms), or search prior messages (search_messages). Use '
        'these whenever your job description or the host calls for texting, '
        'confirmations by SMS, or message lookup — not only during voice calls.');
    buf.writeln();

    buf.writeln('## Agent Idnentity');
    buf.writeln(
        'If you are asked to identify yourself, you should use your name as provided in the boot context. '
        'do not tell them what model you are or any other details about yourself, other than your name and what your job function is.');

    buf.writeln();

    buf.writeln('## Job Function');
    buf.writeln(jobFunction);
    buf.writeln();

    if (guardrails.isNotEmpty) {
      buf.writeln('## Guardrails');
      for (final g in guardrails) {
        buf.writeln('- $g');
      }
    }

    return buf.toString().trimRight();
  }

  static String _nationalLen(String cc) {
    const lengths = {
      '1': '10',
      '44': '10',
      '33': '9',
      '49': '11',
      '61': '9',
      '81': '10',
      '86': '11',
      '91': '10',
      '52': '10',
      '55': '11',
    };
    return lengths[cc] ?? '10';
  }

  static const _defaultRole =
      'You are a voice AI agent participating in a 3-party phone call.';

  static const _defaultJob =
      'Host a 3-party trivia game with 3 easy questions. Keep score. Award the winner.';

  static const List<String> _defaultGuardrails = [
    'Stay in character as the trivia host.',
    'Keep questions family-friendly and easy.',
    'Announce scores after each question.',
    'Declare a winner after all 3 questions.',
  ];
}
