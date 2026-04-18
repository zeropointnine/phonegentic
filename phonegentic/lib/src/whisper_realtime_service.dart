import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class TranscriptionEvent {
  final String text;
  final bool isFinal;
  final String itemId;

  const TranscriptionEvent({
    required this.text,
    required this.isFinal,
    this.itemId = '',
  });
}

class AudioResponseEvent {
  final Uint8List pcm16Data;
  final bool isDone;

  const AudioResponseEvent({required this.pcm16Data, this.isDone = false});
}

class ResponseTextEvent {
  final String text;
  final bool isFinal;

  const ResponseTextEvent({required this.text, this.isFinal = false});
}

class FunctionCallEvent {
  final String callId;
  final String name;
  final String arguments;

  const FunctionCallEvent({
    required this.callId,
    required this.name,
    required this.arguments,
  });
}

class WhisperRealtimeService {
  static const _audioTapChannel = EventChannel('com.agentic_ai/audio_tap');
  static const _methodChannel =
      MethodChannel('com.agentic_ai/audio_tap_control');
  static final _logger = Logger();

  WebSocketChannel? _ws;
  StreamSubscription<dynamic>? _audioSub;
  bool _connected = false;
  bool muted = false;
  bool _vadActive = false;
  bool _isTtsPlaying = false;
  DateTime _ttsSuppressedUntil = DateTime(0);
  static const int _ttsEchoCooldownMs = 300;

  /// When true, the native layer strips mic echo and sends remote-only audio
  /// during TTS playback, so Flutter-level suppression is unnecessary.
  bool inCallMode = false;

  final _transcriptionController =
      StreamController<TranscriptionEvent>.broadcast();
  final _audioResponseController =
      StreamController<AudioResponseEvent>.broadcast();
  final _responseTextController =
      StreamController<ResponseTextEvent>.broadcast();
  final _functionCallController =
      StreamController<FunctionCallEvent>.broadcast();
  final _audioLevelController = StreamController<double>.broadcast();
  final _speakingController = StreamController<bool>.broadcast();
  final _vadController = StreamController<bool>.broadcast();
  // Raw PCM16 audio from the mic tap — exposed so callers can forward to a
  // local STT engine without needing their own EventChannel subscription.
  final _rawAudioController = StreamController<Uint8List>.broadcast();

  // Accumulate function call arguments by call_id
  final Map<String, _PendingFunctionCall> _pendingFunctionCalls = {};

  Stream<TranscriptionEvent> get transcriptions =>
      _transcriptionController.stream;
  Stream<AudioResponseEvent> get audioResponses =>
      _audioResponseController.stream;
  Stream<ResponseTextEvent> get responseTexts =>
      _responseTextController.stream;
  Stream<FunctionCallEvent> get functionCalls =>
      _functionCallController.stream;
  Stream<double> get audioLevels => _audioLevelController.stream;
  Stream<bool> get speakingState => _speakingController.stream;
  Stream<bool> get vadEvents => _vadController.stream;
  Stream<Uint8List> get rawAudio => _rawAudioController.stream;
  bool get isConnected => _connected;
  bool get vadActive => _vadActive;

  bool get isTtsPlaying => _isTtsPlaying;
  set isTtsPlaying(bool value) {
    if (_isTtsPlaying != value) {
      _isTtsPlaying = value;
      if (!value) {
        _ttsSuppressedUntil =
            DateTime.now().add(const Duration(milliseconds: _ttsEchoCooldownMs));
      }
      debugPrint('[WhisperRealtimeService] _isTtsPlaying = $_isTtsPlaying');
    }
  }

  /// Query native layer for speaker info including voiceprint identity.
  /// Returns a map with keys: "source" (host/remote/unknown),
  /// "identity" (speaker name or ""), "confidence" (0.0-1.0).
  Future<Map<String, dynamic>> getSpeakerInfo() async {
    try {
      final result = await _methodChannel.invokeMethod<Map>('getDominantSpeaker');
      if (result != null) {
        return Map<String, dynamic>.from(result);
      }
      return {'source': 'unknown', 'identity': '', 'confidence': 0.0};
    } catch (_) {
      return {'source': 'unknown', 'identity': '', 'confidence': 0.0};
    }
  }

  /// Convenience: returns just the dominant source ("host", "remote", "unknown").
  Future<String> getDominantSpeaker() async {
    final info = await getSpeakerInfo();
    return info['source'] as String? ?? 'unknown';
  }

  /// Initialize the on-device speaker identifier (FluidAudio / CoreML).
  Future<void> initSpeakerIdentifier() async {
    try {
      await _methodChannel.invokeMethod('initSpeakerIdentifier');
    } catch (e) {
      debugPrint('[Whisper] initSpeakerIdentifier failed: $e');
    }
  }

  /// Load known speaker profiles into the native speaker identifier.
  /// Each entry: { "id": String, "name": String, "embedding": List<double> }
  Future<void> loadKnownSpeakers(List<Map<String, dynamic>> speakers) async {
    try {
      await _methodChannel.invokeMethod('loadKnownSpeakers', speakers);
    } catch (e) {
      debugPrint('[Whisper] loadKnownSpeakers failed: $e');
    }
  }

  /// Reset the speaker identifier state (call at end of each call).
  Future<void> resetSpeakerIdentifier() async {
    try {
      await _methodChannel.invokeMethod('resetSpeakerIdentifier');
    } catch (e) {
      debugPrint('[Whisper] resetSpeakerIdentifier failed: $e');
    }
  }

  /// Retrieve the current remote speaker's voiceprint embedding (for storage).
  /// Returns null if no speaker was identified.
  Future<List<double>?> getRemoteSpeakerEmbedding() async {
    try {
      final result = await _methodChannel.invokeMethod<List>('getRemoteSpeakerEmbedding');
      if (result == null) return null;
      return result.cast<double>();
    } catch (e) {
      debugPrint('[Whisper] getRemoteSpeakerEmbedding failed: $e');
      return null;
    }
  }

  List<Map<String, dynamic>> _extraTools = [];

  /// Register additional tools (e.g. from 3rd-party integrations) before
  /// or after connect.  Triggers a session.update if already connected.
  void setExtraTools(List<Map<String, dynamic>> tools) {
    _extraTools = tools;
  }

  Future<void> connect({
    required String apiKey,
    required String model,
    required String voice,
    String instructions = '',
  }) async {
    if (_connected) await disconnect();

    _audioSendCount = 0;

    final uri =
        Uri.parse('wss://api.openai.com/v1/realtime?model=$model');

    _logger.i('Connecting to OpenAI Realtime: $model voice=$voice');

    _ws = IOWebSocketChannel.connect(
      uri,
      headers: {
        'Authorization': 'Bearer $apiKey',
        'OpenAI-Beta': 'realtime=v1',
      },
    );

    await _ws!.ready;
    _connected = true;

    _ws!.stream.listen(
      _handleMessage,
      onError: (error) {
        _logger.e('WebSocket error: $error');
        _connected = false;
      },
      onDone: () {
        _logger.i('WebSocket closed');
        _connected = false;
      },
    );

    _configureSession(voice: voice, instructions: instructions);
    _logger.i('Connected to OpenAI Realtime API ($model)');
  }

  void _configureSession({
    required String voice,
    String instructions = '',
  }) {
    final session = <String, dynamic>{
      'modalities': ['text', 'audio'],
      'voice': voice,
      'input_audio_format': 'pcm16',
      'output_audio_format': 'pcm16',
      'input_audio_transcription': {
        'model': 'gpt-4o-mini-transcribe',
      },
      'turn_detection': {
        'type': 'server_vad',
        'threshold': 0.8,
        'prefix_padding_ms': 300,
        'silence_duration_ms': 1800,
      },
    };

    if (instructions.isNotEmpty) {
      session['instructions'] = '$instructions'
          '\n\nYou have access to a local call history database and a contacts database. '
          'When the user asks about past calls, call duration, '
          'or wants to search their call history, use the search_calls tool. '
          'You can also open the call history UI with open_call_history. '
          'You can make calls with make_call, hang up with end_call, '
          'and navigate phone menus with send_dtmf.'
          '\n\nYou can search the contacts database with search_contacts. '
          'When the user asks you to build a call list, tear sheet, or find '
          'contacts matching criteria (e.g. "contacts not called in 2 weeks"), '
          'first use search_contacts to find matching contacts, then use '
          'create_tear_sheet to build the queue. Always confirm the list with '
          'the user before creating the tear sheet.'
          '\n\nYou can send SMS with send_sms, reply in the selected thread '
          'with reply_sms, and search message history with search_messages '
          'when texting fits the job or the host asks.'
          '\n\n## Whisper Mode\n'
          'When you receive a message prefixed with [WHISPER], treat it as a private '
          'stage direction from the host. Act on it immediately and naturally — adjust '
          'your approach, topic, tone, or strategy — but do NOT acknowledge it verbally. '
          'Do not say "understood," do not repeat it, do not pause. The caller must '
          'never know the instruction was given. If the instruction is unclear or '
          'contradictory, silently ignore it and continue naturally.';
    }

    session['tools'] = [
      {
        'type': 'function',
        'name': 'search_calls',
        'description':
            'Search the local call history database. Use when the user asks '
                'about past calls, call history, or wants to find specific calls.',
        'parameters': {
          'type': 'object',
          'properties': {
            'contact_name': {
              'type': 'string',
              'description': 'Name or phone number to search for',
            },
            'min_duration_seconds': {
              'type': 'integer',
              'description': 'Minimum call duration in seconds',
            },
            'max_duration_seconds': {
              'type': 'integer',
              'description': 'Maximum call duration in seconds',
            },
            'since_minutes_ago': {
              'type': 'integer',
              'description':
                  'Only include calls from the last N minutes (e.g. 60 for last hour)',
            },
            'direction': {
              'type': 'string',
              'enum': ['inbound', 'outbound'],
              'description': 'Call direction filter',
            },
            'status': {
              'type': 'string',
              'enum': ['completed', 'missed', 'failed', 'rejected'],
              'description': 'Call outcome filter',
            },
          },
        },
      },
      {
        'type': 'function',
        'name': 'open_call_history',
        'description':
            'Open the call history panel in the UI, optionally with a '
                'search query pre-filled.',
        'parameters': {
          'type': 'object',
          'properties': {
            'search_query': {
              'type': 'string',
              'description':
                  'Optional text to pre-populate the search field',
            },
          },
        },
      },
      {
        'type': 'function',
        'name': 'make_call',
        'description':
            'Initiate an outbound phone call. Use "last" to redial '
                'the most recent number.',
        'parameters': {
          'type': 'object',
          'properties': {
            'number': {
              'type': 'string',
              'description':
                  'The phone number or SIP URI to dial. Use "last" to redial '
                      'the most recently dialed number.',
            },
          },
          'required': ['number'],
        },
      },
      {
        'type': 'function',
        'name': 'check_locale',
        'description':
            'Get the host\'s phone-number locale: country code, expected '
                'digit length, format example, and sanitization rules.',
        'parameters': {
          'type': 'object',
          'properties': {},
        },
      },
      {
        'type': 'function',
        'name': 'end_call',
        'description': 'Hang up the current active call.',
        'parameters': {
          'type': 'object',
          'properties': {},
        },
      },
      {
        'type': 'function',
        'name': 'send_dtmf',
        'description':
            'Send DTMF tones on the active call to navigate phone menus.',
        'parameters': {
          'type': 'object',
          'properties': {
            'tones': {
              'type': 'string',
              'description':
                  'DTMF digit string to send (e.g. "1", "123#", "*9")',
            },
          },
          'required': ['tones'],
        },
      },
      {
        'type': 'function',
        'name': 'search_contacts',
        'description':
            'Search the local contacts database. Use to find contacts by name, '
                'phone, tags, or to filter by call recency. Supports finding '
                'contacts who have not been called within a given number of days.',
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description':
                  'Search text to match against contact name, phone, or tags. '
                      'Leave empty to get all contacts.',
            },
            'not_called_since_days': {
              'type': 'integer',
              'description':
                  'Only return contacts who have NOT been called in the last N days. '
                      'For example, 14 means "contacts not called in the last 2 weeks."',
            },
          },
        },
      },
      {
        'type': 'function',
        'name': 'save_contact',
        'description':
            'Save or update a contact in the local contacts database. '
                'Use when a caller provides their name, email, or company. '
                'If a contact already exists for the phone number, it is updated; '
                'otherwise a new contact is created.',
        'parameters': {
          'type': 'object',
          'properties': {
            'phone_number': {
              'type': 'string',
              'description':
                  'Phone number (E.164 preferred). Uses the current caller\'s '
                      'number if omitted during an active call.',
            },
            'display_name': {
              'type': 'string',
              'description': 'Contact display name (e.g. "John Smith").',
            },
            'email': {
              'type': 'string',
              'description': 'Email address (optional).',
            },
            'company': {
              'type': 'string',
              'description': 'Company or organization (optional).',
            },
            'notes': {
              'type': 'string',
              'description': 'Free-form notes about the contact (optional).',
            },
          },
        },
      },
      {
        'type': 'function',
        'name': 'create_tear_sheet',
        'description':
            'Create a Tear Sheet (automated call queue) from a list of contacts/numbers. '
                'The tear sheet docks at the top of the screen and the agent calls through '
                'the list sequentially. Use after searching contacts to build the queue.',
        'parameters': {
          'type': 'object',
          'properties': {
            'name': {
              'type': 'string',
              'description': 'Display name for the tear sheet (e.g. "Follow-up calls")',
            },
            'entries': {
              'type': 'array',
              'description': 'List of entries to add to the tear sheet.',
              'items': {
                'type': 'object',
                'properties': {
                  'phone_number': {
                    'type': 'string',
                    'description': 'Phone number to call',
                  },
                  'name': {
                    'type': 'string',
                    'description': 'Contact name (optional)',
                  },
                },
                'required': ['phone_number'],
              },
            },
          },
          'required': ['entries'],
        },
      },
      {
        'type': 'function',
        'name': 'send_sms',
        'description':
            'Send an SMS or MMS from the manager\'s phone number to a recipient. '
                'The message is sent on behalf of the manager. Use when the user or caller asks '
                'you to text someone, send a message, or follow up via text.',
        'parameters': {
          'type': 'object',
          'properties': {
            'to': {
              'type': 'string',
              'description': 'Phone number to send to (E.164 format, e.g. +18005551234)',
            },
            'text': {
              'type': 'string',
              'description': 'The message body to send',
            },
            'media_url': {
              'type': 'string',
              'description': 'Optional URL of an image to attach (MMS)',
            },
          },
          'required': ['to', 'text'],
        },
      },
      {
        'type': 'function',
        'name': 'reply_sms',
        'description':
            'Reply in the currently selected SMS conversation on behalf of the '
                'manager. The reply is sent from the manager\'s phone number. Use when '
                'the user asks to respond to or reply to a text message.',
        'parameters': {
          'type': 'object',
          'properties': {
            'text': {
              'type': 'string',
              'description': 'The reply message body',
            },
          },
          'required': ['text'],
        },
      },
      {
        'type': 'function',
        'name': 'search_messages',
        'description':
            'Search the SMS message history. Use when the user asks about '
                'past text messages or wants to find a specific message.',
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'Search text to match against message body or phone number',
            },
            'contact_name': {
              'type': 'string',
              'description': 'Contact name to filter by',
            },
          },
        },
      },
      {
        'type': 'function',
        'name': 'start_voice_sample',
        'description':
            'Start capturing a voice sample from the specified call party for '
                'voice cloning. Use this to record audio that will be sent to '
                'ElevenLabs to create a cloned voice. Let them speak for at '
                'least 10-15 seconds before stopping.',
        'parameters': {
          'type': 'object',
          'properties': {
            'party': {
              'type': 'string',
              'enum': ['remote', 'host'],
              'description':
                  'Which call party to sample: "remote" for the other caller, '
                      '"host" for the app user.',
            },
          },
          'required': ['party'],
        },
      },
      {
        'type': 'function',
        'name': 'stop_and_clone_voice',
        'description':
            'Stop the active voice sample and upload it to ElevenLabs to '
                'create a cloned voice. Returns the new voice_id on success. '
                'Must call start_voice_sample first.',
        'parameters': {
          'type': 'object',
          'properties': {
            'voice_name': {
              'type': 'string',
              'description':
                  'A friendly name for the cloned voice (e.g. "Sarah\'s Voice").',
            },
          },
        },
      },
      {
        'type': 'function',
        'name': 'set_agent_voice',
        'description':
            'Change the agent\'s speaking voice mid-call. Provide either a '
                'voice_id (from list_voices or stop_and_clone_voice) or a '
                'voice_name to search by name. All subsequent agent speech '
                'will use this voice.',
        'parameters': {
          'type': 'object',
          'properties': {
            'voice_id': {
              'type': 'string',
              'description':
                  'The ElevenLabs voice ID to switch to. Takes priority over voice_name.',
            },
            'voice_name': {
              'type': 'string',
              'description':
                  'The name of the voice to switch to (case-insensitive). '
                      'Use this when you know the voice name from list_voices.',
            },
          },
        },
      },
      {
        'type': 'function',
        'name': 'list_voices',
        'description':
            'List all available ElevenLabs voices the agent can switch to. '
                'Returns voice names, IDs, and categories. Use this when asked '
                'to change voice or show available voices, BEFORE calling '
                'set_agent_voice.',
        'parameters': {
          'type': 'object',
          'properties': {},
        },
      },
      {
        'type': 'function',
        'name': 'transfer_call',
        'description':
            'Blind-transfer the active call to another number or SIP URI. '
                'The current call will be redirected and then disconnected on '
                'our side once the transfer is accepted.',
        'parameters': {
          'type': 'object',
          'properties': {
            'target': {
              'type': 'string',
              'description':
                  'Phone number or SIP URI to transfer the call to '
                      '(e.g. "+18005551234" or "sip:agent@example.com")',
            },
          },
          'required': ['target'],
        },
      },
      {
        'type': 'function',
        'name': 'hold_call',
        'description':
            'Put the active call on hold, or resume a held call. '
                'Toggling hold is useful before adding a conference participant.',
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['hold', 'resume'],
              'description': 'Whether to hold or resume the call.',
            },
          },
          'required': ['action'],
        },
      },
      {
        'type': 'function',
        'name': 'mute_call',
        'description':
            'Mute or unmute the microphone on the active call.',
        'parameters': {
          'type': 'object',
          'properties': {
            'muted': {
              'type': 'boolean',
              'description': 'True to mute the microphone, false to unmute.',
            },
          },
          'required': ['muted'],
        },
      },
      {
        'type': 'function',
        'name': 'add_conference_participant',
        'description':
            'Add a new participant to the call by dialing a second number. '
                'The current call is automatically placed on hold while the '
                'new leg connects. Use merge_conference afterwards to bridge '
                'all participants together.',
        'parameters': {
          'type': 'object',
          'properties': {
            'number': {
              'type': 'string',
              'description':
                  'Phone number or SIP URI of the participant to add.',
            },
          },
          'required': ['number'],
        },
      },
      {
        'type': 'function',
        'name': 'merge_conference',
        'description':
            'Merge all active call legs into a single conference call. '
                'Requires at least two call legs (use add_conference_participant first).',
        'parameters': {
          'type': 'object',
          'properties': {},
        },
      },
      {
        'type': 'function',
        'name': 'create_reminder',
        'description':
            'Create a timed reminder for the manager. '
                'ALWAYS prefer the delay/offset parameters (delay_minutes, delay_hours, '
                'delay_days) over remind_at — the server computes the exact fire time so '
                'you never need to do time arithmetic. Combine them freely: e.g. '
                'delay_days=1 + at_time="17:00" for "tomorrow at 5 PM". '
                'Only fall back to remind_at for a fully-specified absolute datetime '
                'like "April 25 2026 at 3 PM". '
                'Offer to also add it to Google Calendar.',
        'parameters': {
          'type': 'object',
          'properties': {
            'title': {
              'type': 'string',
              'description': 'Short title for the reminder.',
            },
            'delay_minutes': {
              'type': 'integer',
              'description':
                  'Additional minutes from now to fire. Can combine with '
                      'delay_hours and delay_days.',
            },
            'delay_hours': {
              'type': 'integer',
              'description':
                  'Additional hours from now to fire. Can combine with '
                      'delay_minutes and delay_days.',
            },
            'delay_days': {
              'type': 'integer',
              'description':
                  'Additional days from now to fire. "tomorrow" = 1, '
                      '"next week" = 7, "in 3 weeks" = 21. '
                      'Can combine with delay_hours, delay_minutes, and at_time.',
            },
            'at_time': {
              'type': 'string',
              'description':
                  'Time of day in HH:MM 24-hour format (e.g. "17:00" for 5 PM, '
                      '"09:30" for 9:30 AM). Overrides the time-of-day on the '
                      'computed date. If used alone without delay_days/hours/minutes, '
                      'fires today if the time is still ahead, otherwise tomorrow.',
            },
            'remind_at': {
              'type': 'string',
              'description':
                  'ISO 8601 datetime (e.g. "2026-04-25T15:00:00"). '
                      'LAST RESORT — only use when the user gives a full absolute '
                      'date+time and none of the delay/at_time params fit.',
            },
            'description': {
              'type': 'string',
              'description': 'Optional longer description.',
            },
            'add_to_google_calendar': {
              'type': 'boolean',
              'description':
                  'If true, also create a Google Calendar event for this reminder.',
            },
          },
          'required': ['title'],
        },
      },
      {
        'type': 'function',
        'name': 'get_call_summary',
        'description':
            'Get a summary of recent call activity. Use when the manager '
                'asks about calls since they were away or wants a status update.',
        'parameters': {
          'type': 'object',
          'properties': {
            'since_minutes_ago': {
              'type': 'integer',
              'description':
                  'Only include calls from the last N minutes. '
                      'Omit to use time since last briefing.',
            },
          },
        },
      },
      {
        'type': 'function',
        'name': 'play_call_recording',
        'description':
            'Play back a call recording inline in the chat for the manager.',
        'parameters': {
          'type': 'object',
          'properties': {
            'call_record_id': {
              'type': 'integer',
              'description': 'The ID of the call record whose recording to play.',
            },
          },
          'required': ['call_record_id'],
        },
      },
      {
        'type': 'function',
        'name': 'list_reminders',
        'description':
            'List all scheduled reminders. Use when the manager asks about '
                'upcoming reminders, what is scheduled, or "do I have any reminders?".',
        'parameters': {
          'type': 'object',
          'properties': {
            'include_fired': {
              'type': 'boolean',
              'description':
                  'If true, include already-fired and dismissed reminders. '
                      'Defaults to false (only pending).',
            },
          },
        },
      },
      {
        'type': 'function',
        'name': 'cancel_reminder',
        'description':
            'Cancel/remove a pending reminder. Use when the manager asks to '
                'cancel, remove, or delete a reminder. List reminders first if '
                'the ID is unknown.',
        'parameters': {
          'type': 'object',
          'properties': {
            'reminder_id': {
              'type': 'integer',
              'description': 'The ID of the reminder to cancel.',
            },
          },
          'required': ['reminder_id'],
        },
      },
      {
        'type': 'function',
        'name': 'create_transfer_rule',
        'description':
            'Create a persistent call transfer rule. When a caller matching '
                'the pattern calls in, the call is automatically transferred to '
                'the target number. The manager can specify silent or announced '
                'mode, and optionally assign a job function.',
        'parameters': {
          'type': 'object',
          'properties': {
            'name': {
              'type': 'string',
              'description':
                  'Short label for this rule (e.g. "Amber → my cell").',
            },
            'caller_patterns': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Phone numbers or patterns to match the caller. '
                      'Use "*" for any caller. E.164 format preferred '
                      '(e.g. ["+14155551234"]).',
            },
            'transfer_target': {
              'type': 'string',
              'description':
                  'Phone number or SIP URI to transfer matching calls to.',
            },
            'silent': {
              'type': 'boolean',
              'description':
                  'If true, transfer silently. If false (default), announce.',
            },
            'job_function_id': {
              'type': 'integer',
              'description':
                  'Optional job function ID to activate for this transfer.',
            },
          },
          'required': ['name', 'caller_patterns', 'transfer_target'],
        },
      },
      {
        'type': 'function',
        'name': 'update_transfer_rule',
        'description':
            'Update an existing transfer rule. Provide the rule ID and '
                'only the fields you want to change.',
        'parameters': {
          'type': 'object',
          'properties': {
            'id': {
              'type': 'integer',
              'description': 'The ID of the transfer rule to update.',
            },
            'name': {
              'type': 'string',
              'description': 'New label for this rule.',
            },
            'enabled': {
              'type': 'boolean',
              'description': 'Enable or disable this rule.',
            },
            'caller_patterns': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'New caller patterns to match.',
            },
            'transfer_target': {
              'type': 'string',
              'description': 'New transfer destination.',
            },
            'silent': {
              'type': 'boolean',
              'description': 'Whether to transfer silently.',
            },
            'job_function_id': {
              'type': 'integer',
              'description': 'Job function ID to activate, or null to remove.',
            },
          },
          'required': ['id'],
        },
      },
      {
        'type': 'function',
        'name': 'delete_transfer_rule',
        'description': 'Delete a transfer rule by ID.',
        'parameters': {
          'type': 'object',
          'properties': {
            'id': {
              'type': 'integer',
              'description': 'The ID of the transfer rule to delete.',
            },
          },
          'required': ['id'],
        },
      },
      {
        'type': 'function',
        'name': 'list_transfer_rules',
        'description': 'List all transfer rules, including disabled ones.',
        'parameters': {
          'type': 'object',
          'properties': {},
        },
      },
      {
        'type': 'function',
        'name': 'request_transfer_approval',
        'description':
            'Send an SMS to the manager asking for approval to transfer '
                'the current call. Use when a REMOTE PARTY (not the manager) '
                'requests a transfer. Never transfer on a remote party\'s '
                'request without manager approval.',
        'parameters': {
          'type': 'object',
          'properties': {
            'reason': {
              'type': 'string',
              'description': 'Why the caller wants to be transferred.',
            },
            'requested_target': {
              'type': 'string',
              'description':
                  'The number/person the caller wants to reach, if specified.',
            },
          },
          'required': ['reason'],
        },
      },
      ..._extraTools,
    ];

    _send({'type': 'session.update', 'session': session});
  }

  void sendTextMessage(String text) {
    if (!_connected || _ws == null) return;
    _send({
      'type': 'conversation.item.create',
      'item': {
        'type': 'message',
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': text}
        ],
      },
    });
    _send({'type': 'response.create'});
  }

  /// Inject a system instruction and trigger a spoken response.
  /// Unlike sendTextMessage (user role), this uses the system role so the
  /// agent treats it as a directive it must follow, not a conversational
  /// request it may decline.
  void sendSystemDirective(String text) {
    if (!_connected || _ws == null) return;
    _send({
      'type': 'conversation.item.create',
      'item': {
        'type': 'message',
        'role': 'system',
        'content': [
          {'type': 'input_text', 'text': text}
        ],
      },
    });
    _send({'type': 'response.create'});
  }

  /// Inject a system context message the model can see but won't respond to
  /// audibly. No `response.create` is sent, so the agent stays silent.
  void sendSystemContext(String text) {
    if (!_connected || _ws == null) return;
    _send({
      'type': 'conversation.item.create',
      'item': {
        'type': 'message',
        'role': 'system',
        'content': [
          {'type': 'input_text', 'text': text}
        ],
      },
    });
  }

  void setModalities(List<String> modalities) {
    if (!_connected || _ws == null) return;
    _send({
      'type': 'session.update',
      'session': {
        'modalities': modalities,
      },
    });
  }

  void updateSessionInstructions(String instructions) {
    if (!_connected || _ws == null) return;
    _send({
      'type': 'session.update',
      'session': {
        'instructions': instructions,
      },
    });
  }

  void sendFunctionCallOutput({
    required String callId,
    required String output,
  }) {
    if (!_connected || _ws == null) return;
    _send({
      'type': 'conversation.item.create',
      'item': {
        'type': 'function_call_output',
        'call_id': callId,
        'output': output,
      },
    });
    _send({'type': 'response.create'});
  }

  bool get _ttsSuppressed =>
      _isTtsPlaying || DateTime.now().isBefore(_ttsSuppressedUntil);

  int _audioSendCount = 0;
  void sendAudio(Uint8List pcm16Mono24kHz) {
    _emitAudioLevel(pcm16Mono24kHz);
    if (muted || !_connected || _ws == null) return;
    // In call mode, native flushBuffers strips mic echo and sends
    // remote-only audio during TTS — no Flutter-level suppression needed.
    // In direct mode, native blocks the event sink entirely via
    // isPlayingResponse, so _ttsSuppressed is the safety net.
    if (!inCallMode && _ttsSuppressed) return;
    _audioSendCount++;
    if (_audioSendCount == 1 || _audioSendCount == 50 || _audioSendCount % 500 == 0) {
      debugPrint('[Whisper] sendAudio #$_audioSendCount: ${pcm16Mono24kHz.length} bytes '
          '(muted=$muted connected=$_connected ws=${_ws != null})');
    }
    final b64 = base64Encode(pcm16Mono24kHz);
    _send({
      'type': 'input_audio_buffer.append',
      'audio': b64,
    });
  }

  void _emitAudioLevel(Uint8List pcm16) {
    if (pcm16.length < 4 || _audioLevelController.isClosed) return;
    final byteData = ByteData.sublistView(pcm16);
    final sampleCount = pcm16.length ~/ 2;
    double sumSquares = 0;
    for (int i = 0; i < sampleCount; i++) {
      final sample = byteData.getInt16(i * 2, Endian.little) / 32768.0;
      sumSquares += sample * sample;
    }
    final rms = sqrt(sumSquares / sampleCount);
    _audioLevelController.add((rms * 4.0).clamp(0.0, 1.0));
  }

  void _send(Map<String, dynamic> message) {
    _ws?.sink.add(jsonEncode(message));
  }

  void _handleMessage(dynamic raw) {
    try {
      final msg = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = msg['type'] as String?;

      switch (type) {
        case 'conversation.item.input_audio_transcription.delta':
          final delta = msg['delta'] as String? ?? '';
          final itemId = msg['item_id'] as String? ?? '';
          if (delta.isNotEmpty) {
            _transcriptionController.add(TranscriptionEvent(
              text: delta,
              isFinal: false,
              itemId: itemId,
            ));
          }
          break;

        case 'conversation.item.input_audio_transcription.completed':
          final transcript = msg['transcript'] as String? ?? '';
          final itemId = msg['item_id'] as String? ?? '';
          debugPrint('[Whisper] Transcription: "$transcript"');
          _transcriptionController.add(TranscriptionEvent(
            text: transcript,
            isFinal: true,
            itemId: itemId,
          ));
          break;

        case 'conversation.item.input_audio_transcription.failed':
          debugPrint('[Whisper] TRANSCRIPTION FAILED: ${msg['error'] ?? msg}');
          break;

        case 'response.audio.delta':
        case 'response.output_audio.delta':
          final b64 = msg['delta'] as String? ?? '';
          if (b64.isNotEmpty) {
            final bytes = base64Decode(b64);
            _audioResponseController.add(AudioResponseEvent(
              pcm16Data: Uint8List.fromList(bytes),
            ));
            if (!_speakingController.isClosed) {
              _speakingController.add(true);
            }
          }
          break;

        case 'response.audio.done':
        case 'response.output_audio.done':
          _audioResponseController.add(AudioResponseEvent(
            pcm16Data: Uint8List(0),
            isDone: true,
          ));
          // Don't manually clear the input buffer — server-side VAD manages
          // the buffer automatically and manual clears can reset VAD state,
          // preventing subsequent speech detection.
          if (!_speakingController.isClosed) {
            _speakingController.add(false);
          }
          break;

        case 'response.audio_transcript.delta':
        case 'response.output_audio_transcript.delta':
          final delta = msg['delta'] as String? ?? '';
          if (delta.isNotEmpty) {
            _responseTextController
                .add(ResponseTextEvent(text: delta));
          }
          break;

        case 'response.audio_transcript.done':
        case 'response.output_audio_transcript.done':
          final transcript = msg['transcript'] as String? ?? '';
          _responseTextController
              .add(ResponseTextEvent(text: transcript, isFinal: true));
          break;

        case 'response.text.delta':
        case 'response.output_text.delta':
          final delta = msg['delta'] as String? ?? '';
          if (delta.isNotEmpty) {
            _responseTextController
                .add(ResponseTextEvent(text: delta));
          }
          break;

        case 'response.text.done':
        case 'response.output_text.done':
          final text = msg['text'] as String? ?? '';
          _responseTextController
              .add(ResponseTextEvent(text: text, isFinal: true));
          break;

        case 'response.output_item.added':
          final item = msg['item'] as Map<String, dynamic>? ?? {};
          if (item['type'] == 'function_call') {
            final callId = item['call_id'] as String? ?? '';
            final name = item['name'] as String? ?? '';
            _pendingFunctionCalls[callId] =
                _PendingFunctionCall(name: name, callId: callId);
            _logger.d('Function call started: $name ($callId)');
          }
          break;

        case 'response.function_call_arguments.delta':
          final callId = msg['call_id'] as String? ?? '';
          final delta = msg['delta'] as String? ?? '';
          _pendingFunctionCalls[callId]?.argumentBuffer.write(delta);
          break;

        case 'response.function_call_arguments.done':
          final callId = msg['call_id'] as String? ?? '';
          final arguments = msg['arguments'] as String? ?? '{}';
          final pending = _pendingFunctionCalls.remove(callId);
          if (pending != null && !_functionCallController.isClosed) {
            _functionCallController.add(FunctionCallEvent(
              callId: callId,
              name: pending.name,
              arguments: arguments,
            ));
          }
          break;

        case 'input_audio_buffer.speech_started':
          _vadActive = true;
          if (!_vadController.isClosed) _vadController.add(true);
          debugPrint('[Whisper] VAD: speech started');
          break;

        case 'input_audio_buffer.speech_stopped':
          _vadActive = false;
          if (!_vadController.isClosed) _vadController.add(false);
          debugPrint('[Whisper] VAD: speech stopped');
          break;

        case 'input_audio_buffer.committed':
          debugPrint('[Whisper] Audio buffer committed');
          break;

        case 'session.created':
          debugPrint('[Whisper] Session created');
          break;

        case 'session.updated':
          debugPrint('[Whisper] Session updated');
          break;

        case 'response.created':
          debugPrint('[Whisper] Response generation started');
          break;

        case 'response.done':
          debugPrint('[Whisper] Response complete');
          break;

        case 'conversation.item.created':
        case 'response.content_part.added':
        case 'response.content_part.done':
        case 'response.output_item.done':
        case 'input_audio_buffer.cleared':
        case 'rate_limits.updated':
          break;

        case 'error':
          final error = msg['error'] as Map<String, dynamic>?;
          debugPrint('[Whisper] ERROR: ${error?['message'] ?? error}');
          break;

        default:
          debugPrint('[Whisper] Unhandled event: $type');
          break;
      }
    } catch (e) {
      _logger.e('Failed to parse Realtime message: $e');
    }
  }

  Future<void> startAudioTap(
      {bool captureInput = true, bool captureOutput = true}) async {
    await _methodChannel.invokeMethod('startAudioTap', {
      'captureInput': captureInput,
      'captureOutput': captureOutput,
    });

    _audioSub = _audioTapChannel.receiveBroadcastStream().listen((data) {
      if (data is Uint8List) {
        _rawAudioController.add(data);
        sendAudio(data);
      }
    });
  }

  Future<void> playResponseAudio(Uint8List pcm16Data) async {
    if (pcm16Data.isEmpty) return;
    isTtsPlaying = true;
    await _methodChannel.invokeMethod('playAudioResponse', pcm16Data);
  }

  Future<void> stopResponseAudio() async {
    try {
      await _methodChannel.invokeMethod('stopAudioPlayback');
    } catch (_) {}
  }

  /// Clear the native TTS ring buffers (call mode) so queued agent audio
  /// is silenced immediately on barge-in. Also cancels the call-mode
  /// playback timer and fires onPlaybackComplete.
  Future<void> clearTTSQueue() async {
    try {
      await _methodChannel.invokeMethod('clearTTSQueue');
    } catch (_) {}
  }

  Future<void> stopAudioTap() async {
    await _audioSub?.cancel();
    _audioSub = null;
    try {
      await _methodChannel.invokeMethod('stopAudioTap');
    } catch (_) {}
  }

  Future<void> disconnect() async {
    await stopAudioTap();
    await stopResponseAudio();
    _connected = false;
    muted = false;
    _isTtsPlaying = false;
    _ttsSuppressedUntil = DateTime(0);
    inCallMode = false;
    await _ws?.sink.close();
    _ws = null;
  }

  void dispose() {
    disconnect();
    _transcriptionController.close();
    _audioResponseController.close();
    _responseTextController.close();
    _functionCallController.close();
    _audioLevelController.close();
    _speakingController.close();
    _vadController.close();
    _rawAudioController.close();
  }
}

class _PendingFunctionCall {
  final String name;
  final String callId;
  final StringBuffer argumentBuffer = StringBuffer();

  _PendingFunctionCall({required this.name, required this.callId});
}
