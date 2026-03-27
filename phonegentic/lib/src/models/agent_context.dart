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

    final remoteName = (remoteDisplayName != null && remoteDisplayName.isNotEmpty)
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
    RegExp(r'press\s+(\d|one|two|three|four|five|six|seven|eight|nine|zero|pound|star|hash)', caseSensitive: false),
    RegExp(r'(para\s+espa[nñ]ol|for\s+spanish)', caseSensitive: false),
    RegExp(r'(please\s+hold|your\s+call\s+(is|will\s+be))', caseSensitive: false),
    RegExp(r'(leave\s+a\s+message|after\s+the\s+(beep|tone))', caseSensitive: false),
    RegExp(r'(voicemail|mail\s*box)', caseSensitive: false),
    RegExp(r'(is\s+not\s+available|cannot\s+(take|answer))', caseSensitive: false),
    RegExp(r'(menu|extension|operator|directory)', caseSensitive: false),
    RegExp(r'(call\s+(may|is)\s+(being\s+)?recorded)', caseSensitive: false),
    RegExp(r'(quality\s+(assurance|purposes))', caseSensitive: false),
    RegExp(r'(estimated\s+wait|queue\s+position)', caseSensitive: false),
    RegExp(r'(thank\s+you\s+for\s+calling)', caseSensitive: false),
    RegExp(r'(business\s+hours|office\s+hours|currently\s+closed)', caseSensitive: false),
    RegExp(r'(dial\s+by\s+name|spell\s+the\s+name)', caseSensitive: false),
    RegExp(r'(listen\s+carefully|options\s+have\s+changed)', caseSensitive: false),
    RegExp(r'(if\s+you\s+know\s+your\s+party)', caseSensitive: false),
    RegExp(r'(all\s+(of\s+our\s+)?(representatives|agents)\s+(are|is))', caseSensitive: false),
    RegExp(r'(pound\s+sign|star\s+key)', caseSensitive: false),
    RegExp(r'(main\s+menu|previous\s+menu|return\s+to)', caseSensitive: false),
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
  final String role;
  final String jobFunction;
  final List<Speaker> speakers;
  final List<String> guardrails;
  final bool textOnly;

  const AgentBootContext({
    this.role = _defaultRole,
    this.jobFunction = _defaultJob,
    this.speakers = const [],
    this.guardrails = const [],
    this.textOnly = false,
  });

  factory AgentBootContext.trivia() {
    return AgentBootContext(
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
    buf.writeln(role);
    buf.writeln();

    buf.writeln('## Speakers');
    for (final s in speakers) {
      buf.writeln('- [${s.label}]: Source: ${s.source} audio.');
    }
    buf.writeln('- [Agent]: You. Your voice is mixed into both sides of the call.');
    buf.writeln();

    buf.writeln('## Rules');
    buf.writeln('1. The person operating this app is the "Host" (mic audio). The other caller is "Remote Party 1" (remote audio).');
    buf.writeln('2. When you see [Host]: or [Remote Party 1]: prefixes in transcripts, that identifies who spoke.');
    buf.writeln('3. If you don\'t know their names, ask: "May I get your first names please?" and use those names going forward.');
    buf.writeln('4. Always address participants by name once known.');
    buf.writeln();

    buf.writeln('## Call State Awareness');
    buf.writeln('You will receive [CALL_STATE: ...] system messages as the call progresses.');
    buf.writeln('- NEVER read these aloud, repeat them, or verbally acknowledge them.');
    buf.writeln('- Do NOT speak until you see [CALL_STATE: Connected].');
    buf.writeln('- While the state is Initiating, Ringing, Connecting, Answered, or Settling, remain COMPLETELY SILENT.');
    buf.writeln('- "Settling" means the call audio connected but an automated attendant, IVR menu, voicemail greeting, or hold music may be playing. This is NOT a real person. Do NOT respond to anything you hear during settling.');
    buf.writeln('- Only [CALL_STATE: Connected] means a real human is on the line and conversation can begin.');
    buf.writeln('- The party count tells you how many people are on the call. Adjust accordingly.');
    buf.writeln('- If the call goes On Hold, stop speaking until it resumes.');
    buf.writeln('- When the call ends, stop all interaction immediately.');
    buf.writeln('- If you hear phrases like "press 1", "leave a message", "your call is important", "please hold", "for Spanish press 2", "dial by name", or similar automated prompts at ANY point, ignore them completely — they are from a phone system, not a person.');
    buf.writeln();

    if (textOnly) {
      buf.writeln('## Output Mode');
      buf.writeln('You are in TEXT-ONLY mode. You MUST NOT produce any audio or speak aloud.');
      buf.writeln('All your responses go to the host\'s screen as silent text.');
      buf.writeln('The remote party cannot see or hear you. Provide concise, '
          'actionable guidance the host can glance at during the conversation.');
      buf.writeln();
    }

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
