import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'agent_config_service.dart';

/// Streams text to ElevenLabs WebSocket TTS and emits PCM16 24 kHz audio
/// chunks that can be fed directly into [WhisperRealtimeService.playResponseAudio].
class ElevenLabsTtsService {
  final TtsConfig _config;
  String? _voiceIdOverride;

  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  bool _connected = false;
  bool _generating = false;
  bool _endAfterFlush = false;
  int _audioChunkCount = 0;

  final List<String> _pendingText = [];
  Completer<void>? _connectCompleter;

  final _audioController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get audioChunks => _audioController.stream;

  final _speakingController = StreamController<bool>.broadcast();
  Stream<bool> get speakingState => _speakingController.stream;

  ElevenLabsTtsService({required TtsConfig config}) : _config = config;

  bool get isConnected => _connected;

  /// Override the voice used for subsequent generations.
  /// Pass null to revert to the config default.
  void updateVoiceId(String? voiceId) {
    _voiceIdOverride = voiceId;
    debugPrint('[ElevenLabsTTS] Voice override set: '
        '${voiceId ?? "(cleared, using default)"}');
  }

  Future<void> _connect() async {
    // Close any existing socket without resetting generation state.
    _wsSub?.cancel();
    _wsSub = null;
    try {
      await _ws?.sink.close();
    } catch (_) {}
    _ws = null;
    _connected = false;

    final voiceId = _voiceIdOverride ?? _config.elevenLabsVoiceId;
    if (voiceId.isEmpty) {
      debugPrint('[ElevenLabsTTS] No voice ID set — skipping connection');
      _generating = false;
      _speakingController.add(false);
      return;
    }
    final modelId = _config.elevenLabsModelId;
    final uri = Uri.parse(
      'wss://api.elevenlabs.io/v1/text-to-speech/$voiceId/stream-input'
      '?model_id=$modelId&output_format=pcm_24000',
    );

    debugPrint('[ElevenLabsTTS] Connecting to $uri');

    _connectCompleter = Completer<void>();
    _audioChunkCount = 0;

    try {
      _ws = IOWebSocketChannel.connect(
        uri,
        headers: {'xi-api-key': _config.elevenLabsApiKey},
      );

      await _ws!.ready;

      _wsSub = _ws!.stream.listen(
        _onMessage,
        onError: (e) {
          debugPrint('[ElevenLabsTTS] WS error: $e');
          _connected = false;
          if (!(_connectCompleter?.isCompleted ?? true)) {
            _connectCompleter!.completeError(e);
          }
        },
        onDone: () {
          final code = _ws?.closeCode;
          final reason = _ws?.closeReason;
          debugPrint('[ElevenLabsTTS] WS closed (code=$code reason=$reason)');
          _connected = false;
          _generating = false;
        },
      );

      _connected = true;

      _ws!.sink.add(jsonEncode({
        'text': ' ',
        'voice_settings': {
          'stability': 0.5,
          'similarity_boost': 0.8,
          'use_speaker_boost': false,
        },
        'generation_config': {
          'chunk_length_schedule': [80, 120, 200, 260],
        },
      }));

      debugPrint('[ElevenLabsTTS] Connected, voice=$voiceId model=$modelId');
      _connectCompleter!.complete();
    } catch (e) {
      debugPrint('[ElevenLabsTTS] Connection failed: $e');
      _connected = false;
      if (!(_connectCompleter?.isCompleted ?? true)) {
        _connectCompleter!.completeError(e);
      }
      rethrow;
    }
  }

  void _onMessage(dynamic raw) {
    try {
      final data = jsonDecode(raw as String) as Map<String, dynamic>;

      // Log every non-audio message for diagnostics
      if (data['audio'] == null || (data['audio'] as String).isEmpty) {
        debugPrint('[ElevenLabsTTS] MSG: $data');
      }

      final audioB64 = data['audio'] as String?;
      if (audioB64 != null && audioB64.isNotEmpty) {
        final bytes = base64Decode(audioB64);
        if (bytes.isNotEmpty) {
          _audioChunkCount++;
          if (_audioChunkCount <= 3 || _audioChunkCount % 25 == 0) {
            debugPrint('[ElevenLabsTTS] Audio chunk #$_audioChunkCount: '
                '${bytes.length} bytes');
          }
          _audioController.add(Uint8List.fromList(bytes));
        }
      }

      if (data['isFinal'] == true) {
        debugPrint('[ElevenLabsTTS] Generation complete, '
            '$_audioChunkCount audio chunks');
        _speakingController.add(false);
        _generating = false;
      }
    } catch (e) {
      debugPrint('[ElevenLabsTTS] Parse error: $e (raw=${raw.toString().length > 200 ? raw.toString().substring(0, 200) : raw})');
    }
  }

  /// Begin a new TTS generation. Text sent via [sendText] before the
  /// connection is ready will be buffered and flushed once connected.
  void startGeneration() {
    if (_generating) {
      endGeneration();
    }
    _generating = true;
    _endAfterFlush = false;
    _pendingText.clear();
    _speakingController.add(true);
    _connectAndFlush();
  }

  Future<void> _connectAndFlush() async {
    try {
      await _connect();

      if (_pendingText.isNotEmpty) {
        debugPrint('[ElevenLabsTTS] Flushing ${_pendingText.length} '
            'buffered text chunks');
        for (final text in _pendingText) {
          _ws?.sink.add(jsonEncode({'text': text}));
        }
        _pendingText.clear();
      }

      // If endGeneration() was called while we were connecting, close now.
      if (_endAfterFlush) {
        debugPrint('[ElevenLabsTTS] Sending deferred EOS after flush');
        _endAfterFlush = false;
        _generating = false;
        try {
          _ws?.sink.add(jsonEncode({'text': '', 'flush': true}));
          _ws?.sink.add(jsonEncode({'text': ''}));
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[ElevenLabsTTS] connectAndFlush failed: $e');
      _generating = false;
      _endAfterFlush = false;
      _speakingController.add(false);
    }
  }

  /// Stream a text chunk. Buffers if the WebSocket isn't ready yet.
  void sendText(String text) {
    if (!_generating || text.isEmpty) {
      if (!_generating && text.isNotEmpty) {
        debugPrint('[ElevenLabsTTS] sendText DROPPED (generating=$_generating '
            'connected=$_connected): "${text.length > 40 ? text.substring(0, 40) : text}"');
      }
      return;
    }
    if (!_connected) {
      _pendingText.add(text);
      debugPrint('[ElevenLabsTTS] sendText BUFFERED #${_pendingText.length}: '
          '"${text.length > 40 ? text.substring(0, 40) : text}"');
      return;
    }
    _ws?.sink.add(jsonEncode({'text': text}));
    debugPrint('[ElevenLabsTTS] sendText SENT: '
        '"${text.length > 40 ? text.substring(0, 40) : text}"');
  }

  /// Flush remaining text and close the current generation.
  void endGeneration() {
    debugPrint('[ElevenLabsTTS] endGeneration called '
        '(generating=$_generating pending=${_pendingText.length} '
        'connected=$_connected endAfterFlush=$_endAfterFlush)');

    if (!_generating && _pendingText.isEmpty) return;

    if (!_connected) {
      _endAfterFlush = true;
      debugPrint('[ElevenLabsTTS] endGeneration DEFERRED '
          '(${_pendingText.length} pending, connected=$_connected)');
      return;
    }

    _generating = false;
    _pendingText.clear();
    try {
      _ws?.sink.add(jsonEncode({'text': '', 'flush': true}));
      _ws?.sink.add(jsonEncode({'text': ''}));
    } catch (_) {}
    debugPrint('[ElevenLabsTTS] endGeneration SENT EOS');
  }

  Future<void> _disconnect() async {
    _wsSub?.cancel();
    _wsSub = null;
    try {
      await _ws?.sink.close();
    } catch (_) {}
    _ws = null;
    _connected = false;
    _generating = false;
    _endAfterFlush = false;
    _pendingText.clear();
  }

  Future<void> dispose() async {
    _speakingController.add(false);
    await _disconnect();
    await _audioController.close();
    await _speakingController.close();
  }
}
