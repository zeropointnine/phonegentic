import 'dart:async';

import 'package:flutter/foundation.dart';

// Abstract interface for on-device (local) TTS providers.
// Modelled on the Kokoro implementation; PocketTtsService will implement this
// alongside KokoroTtsService.
//
// ElevenLabs (remote TTS) does NOT implement this — its lifecycle and
// speakingState semantics differ and are handled separately in AgentService.
abstract class LocalTtsService {
  /// Load the model and set up the native channel. Must be awaited before any
  /// other method is called.
  Future<void> initialize();

  /// Whether initialize() completed successfully.
  bool get isInitialized;

  /// Select the voice to use for subsequent synthesis calls.
  Future<void> setVoice(String voiceStyle);

  /// Prime the inference engine with a discarded synthesis so the first
  /// user-visible utterance does not pay cold-start latency.
  Future<void> warmUpSynthesis();

  /// Begin a generation. Resets segmentation state and emits speaking=true.
  void startGeneration();

  /// Stream a text delta. The implementation accumulates deltas and queues
  /// complete sentences for synthesis.
  void sendText(String text);

  /// Flush any remaining text and wait for the synthesis queue to fully drain
  /// before emitting speaking=false.
  Future<void> endGeneration();

  /// PCM16 24 kHz mono audio chunks, ready to pass to playResponseAudio.
  Stream<Uint8List> get audioChunks;

  /// Emits true when generation starts, false when the synthesis queue is
  /// fully drained and all audio has been queued for playback.
  Stream<bool> get speakingState;

  /// Cancel any in-progress synthesis, release native resources, and close
  /// streams.
  Future<void> dispose();
}
