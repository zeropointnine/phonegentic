import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

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
  bool _muted = false;

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
  bool get isConnected => _connected;

  bool get muted => _muted;
  set muted(bool value) => _muted = value;

  /// Query native layer for which audio source was louder in the
  /// most recent flush window. Returns "host", "remote", or "unknown".
  Future<String> getDominantSpeaker() async {
    try {
      final result = await _methodChannel.invokeMethod<String>('getDominantSpeaker');
      return result ?? 'unknown';
    } catch (_) {
      return 'unknown';
    }
  }

  Future<void> connect({
    required String apiKey,
    required String model,
    required String voice,
    String instructions = '',
  }) async {
    if (_connected) await disconnect();

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
        'threshold': 0.5,
        'prefix_padding_ms': 300,
        'silence_duration_ms': 1000,
      },
    };

    if (instructions.isNotEmpty) {
      session['instructions'] = instructions +
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

  void sendAudio(Uint8List pcm16Mono24kHz) {
    _emitAudioLevel(pcm16Mono24kHz);
    if (_muted || !_connected || _ws == null) return;
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
          _transcriptionController.add(TranscriptionEvent(
            text: transcript,
            isFinal: true,
            itemId: itemId,
          ));
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
          _send({'type': 'input_audio_buffer.clear'});
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
          _logger.d('VAD: speech started');
          break;

        case 'input_audio_buffer.speech_stopped':
          _logger.d('VAD: speech stopped');
          break;

        case 'input_audio_buffer.committed':
          _logger.d('Audio buffer committed');
          break;

        case 'session.created':
          _logger.i('Session created');
          break;

        case 'session.updated':
          _logger.i('Session updated');
          break;

        case 'response.created':
          _logger.d('Response generation started');
          break;

        case 'response.done':
          _logger.d('Response complete');
          break;

        case 'error':
          final error = msg['error'] as Map<String, dynamic>?;
          _logger.e(
              'Realtime API error: ${error?['message'] ?? error}');
          break;

        default:
          _logger.d('Unhandled event: $type');
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
        sendAudio(data);
      }
    });
  }

  Future<void> playResponseAudio(Uint8List pcm16Data) async {
    if (pcm16Data.isEmpty) return;
    await _methodChannel.invokeMethod('playAudioResponse', pcm16Data);
  }

  Future<void> stopResponseAudio() async {
    try {
      await _methodChannel.invokeMethod('stopAudioPlayback');
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
  }
}

class _PendingFunctionCall {
  final String name;
  final String callId;
  final StringBuffer argumentBuffer = StringBuffer();

  _PendingFunctionCall({required this.name, required this.callId});
}
