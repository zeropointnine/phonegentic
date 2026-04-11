import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'agent_config_service.dart';
import 'text_segmenter.dart';

// =============================================================================
// ElevenLabs TTS Service — Architecture & Lifecycle
// =============================================================================
//
// This service manages a WebSocket connection to the ElevenLabs streaming
// text-to-speech API. Text arrives incrementally from the LLM (Claude) via
// AgentService._appendStreamingResponse, and audio chunks are emitted back
// to be injected into the call's audio pipeline.
//
// ## Connection lifecycle
//
//   warmUp()        — Pre-establishes the WebSocket + TLS handshake so the
//                     first generation doesn't pay the ~200-500ms connection
//                     cost.  Does NOT send a BOS (Beginning of Stream)
//                     message.  The connection idles until startGeneration().
//
//   startGeneration() — Begins a new TTS generation.  Resets _bosSent so
//                       _connectAndFlush() will send a fresh BOS with voice
//                       settings and chunk_length_schedule.  If the WS was
//                       closed after a previous EOS (ElevenLabs closes on
//                       EOS), _connectAndFlush() will reconnect first.
//
//   sendText(text)  — Buffers text in _textBuffer.  Flushes to the WS when
//                     the buffer reaches _minFlushChars (50) characters OR
//                     a sentence-ending punctuation mark is detected.
//                     This prevents tiny fragments (e.g. a single word like
//                     "Would") from being sent alone, which causes ElevenLabs
//                     to generate a tiny audio clip followed by a long pause
//                     before the rest arrives — perceived as "stuttering."
//
//   endGeneration() — Flushes any remaining _textBuffer, sends a flush + EOS
//                     to ElevenLabs, and marks generation complete.
//
// ## ElevenLabs WebSocket protocol
//
//   BOS  →  { text: " ", voice_settings: {...}, generation_config: {...} }
//   Text →  { text: "chunk of text" }   (one or more)
//   EOS  →  { text: "", flush: true }   then  { text: "" }
//
//   After EOS, ElevenLabs sends remaining audio chunks, then { isFinal: true }
//   and closes the WebSocket (code 1000).  A new generation requires a new
//   connection + BOS.
//
// ## chunk_length_schedule: [80, 120, 200, 260]
//
//   Controls how many characters ElevenLabs buffers before generating each
//   successive audio chunk.  The first chunk waits for 80 chars, the second
//   for 120 more, etc.  Lower values reduce time-to-first-audio but produce
//   choppier prosody; higher values sound smoother but add latency.
//
// ## Key tradeoff: BOS timing
//
//   The BOS must be sent CLOSE to when the first text arrives.  If BOS is
//   sent during warmUp() (seconds before text), ElevenLabs starts a
//   generation session that sits idle.  When the first small text fragment
//   arrives after a long gap, ElevenLabs may auto-flush it as a separate
//   audio clip, causing audible stuttering.  That's why BOS is deferred to
//   startGeneration() time — it's sent on the already-warm connection right
//   before the first text, keeping the chunk_length_schedule in sync with
//   actual text delivery.
//
// ## Buffering layers (text → audio)
//
//   1. _pendingText   — Pre-connection buffer.  Text arriving before the WS
//                       is ready is queued here and flushed once connected.
//   2. _textBuffer    — Post-connection buffer.  Accumulates small Claude
//                       streaming deltas until _minFlushChars or a sentence
//                       boundary, then sends as one WS message.
//   3. ElevenLabs     — Server-side buffer controlled by chunk_length_schedule.
//                       Accumulates characters before synthesizing audio.
//   4. AudioTap ring  — Native-side ring buffer that feeds PCM into the
//                       WebRTC capture pipeline at the hardware sample rate.
//
// =============================================================================

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
  bool _bosSent = false;
  int _audioChunkCount = 0;

  final List<String> _pendingText = [];
  final StringBuffer _textBuffer = StringBuffer();
  final TextSegmenter _segmenter = TextSegmenter();
  static const _minFlushChars = 50;
  Completer<void>? _connectCompleter;

  final _audioController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get audioChunks => _audioController.stream;

  final _speakingController = StreamController<bool>.broadcast();
  Stream<bool> get speakingState => _speakingController.stream;

  ElevenLabsTtsService({required TtsConfig config}) : _config = config;

  bool get isConnected => _connected;

  /// Pre-establish the WebSocket connection so the first generation starts
  /// without the ~5-10s TLS/handshake delay. Safe to call multiple times.
  Future<void> warmUp() async {
    if (_connected) return;
    try {
      await _connect();
      debugPrint('[ElevenLabsTTS] Warmed up — WebSocket ready');
    } catch (e) {
      debugPrint('[ElevenLabsTTS] warmUp failed: $e');
    }
  }

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
      _bosSent = false;

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

  /// Send the BOS (Beginning of Stream) message that initialises an
  /// ElevenLabs generation session.  Must be called once per generation,
  /// right before the first text is sent.
  void _sendBos() {
    if (_bosSent || !_connected) return;
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
    _bosSent = true;
    debugPrint('[ElevenLabsTTS] BOS sent');
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
    _textBuffer.clear();
    _segmenter.reset();
    _bosSent = false;
    _speakingController.add(true);
    _connectAndFlush();
  }

  Future<void> _connectAndFlush() async {
    try {
      if (!_connected) {
        await _connect();
      }

      _sendBos();

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

  /// Stream a text chunk. Small fragments are accumulated in [_textBuffer]
  /// and flushed once [_minFlushChars] is reached or a real sentence boundary
  /// is detected by [TextSegmenter], preventing ElevenLabs from generating
  /// tiny audio clips for partial words while avoiding false flushes on
  /// abbreviations like "Mr." or "D.C."
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

    _textBuffer.write(text);
    final sentences = _segmenter.addText(text);

    if (sentences.isNotEmpty) {
      // A real sentence boundary was detected — flush everything accumulated.
      _flushTextBuffer();
    } else if (_textBuffer.length >= _minFlushChars) {
      // No sentence boundary yet, but enough chars for ElevenLabs to work
      // with via its server-side chunk_length_schedule.
      _flushTextBuffer();
    }
  }

  void _flushTextBuffer() {
    if (_textBuffer.isEmpty) return;
    final text = _textBuffer.toString();
    _textBuffer.clear();
    _ws?.sink.add(jsonEncode({'text': text}));
    debugPrint('[ElevenLabsTTS] sendText SENT (${text.length} chars): '
        '"${text.length > 60 ? text.substring(0, 60) : text}"');
  }

  /// Flush remaining text and close the current generation.
  void endGeneration() {
    debugPrint('[ElevenLabsTTS] endGeneration called '
        '(generating=$_generating pending=${_pendingText.length} '
        'buf=${_textBuffer.length} connected=$_connected '
        'endAfterFlush=$_endAfterFlush)');

    if (!_generating && _pendingText.isEmpty && _textBuffer.isEmpty) return;

    if (!_connected) {
      _endAfterFlush = true;
      debugPrint('[ElevenLabsTTS] endGeneration DEFERRED '
          '(${_pendingText.length} pending, connected=$_connected)');
      return;
    }

    _flushTextBuffer();
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
    _bosSent = false;
    _pendingText.clear();
    _textBuffer.clear();
    _segmenter.reset();
  }

  Future<void> dispose() async {
    _speakingController.add(false);
    await _disconnect();
    await _audioController.close();
    await _speakingController.close();
  }
}
