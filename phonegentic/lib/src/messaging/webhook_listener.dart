import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'telnyx_messaging_provider.dart';

/// Lightweight local HTTP server that receives Telnyx webhook POSTs and
/// forwards them to a [TelnyxMessagingProvider].
///
/// The user configures Telnyx to POST to this server's address (typically
/// via an ngrok / cloudflare tunnel). When no webhook URL is configured,
/// the provider falls back to polling automatically.
class WebhookListener {
  final TelnyxMessagingProvider provider;
  final int port;

  HttpServer? _server;

  WebhookListener({required this.provider, this.port = 4190});

  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      debugPrint('[WebhookListener] Listening on localhost:$port');
      _server!.listen(_handleRequest);
    } catch (e) {
      debugPrint('[WebhookListener] Failed to bind: $e');
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.method != 'POST') {
      request.response
        ..statusCode = HttpStatus.methodNotAllowed
        ..write('Method not allowed');
      await request.response.close();
      return;
    }

    try {
      final body = await utf8.decoder.bind(request).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      provider.handleWebhookPayload(json);
      request.response
        ..statusCode = HttpStatus.ok
        ..write('OK');
    } catch (e) {
      debugPrint('[WebhookListener] Error processing webhook: $e');
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('Bad request');
    }
    await request.response.close();
  }
}
