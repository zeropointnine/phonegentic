import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Local HTTP server for carrier inbound webhooks.
///
/// Telnyx posts JSON; Twilio posts `application/x-www-form-urlencoded`.
/// When no webhook URL is configured in settings, providers fall back to
/// polling.
class WebhookListener {
  final void Function(Map<String, dynamic> json)? onTelnyxJson;
  final void Function(Map<String, String> form)? onTwilioForm;

  /// Optional handler for Telnyx call control events (conference, call.initiated,
  /// etc.).  The messaging handler runs first; this fires for any JSON payload
  /// so call-control-specific consumers can inspect the event_type.
  void Function(Map<String, dynamic> json)? onTelnyxCallControl;

  final int port;

  HttpServer? _server;

  WebhookListener({
    this.onTelnyxJson,
    this.onTwilioForm,
    this.onTelnyxCallControl,
    this.port = 4190,
  });

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
      final mime = request.headers.contentType?.mimeType ?? '';
      final looksTwilio =
          body.contains('MessageSid=') || body.contains('SmsSid=');
      if (looksTwilio && onTwilioForm != null) {
        onTwilioForm!(_parseFormBody(body));
      } else if (mime.contains('json') ||
          body.trimLeft().startsWith('{') ||
          body.trimLeft().startsWith('[')) {
        final json = jsonDecode(body) as Map<String, dynamic>;
        onTelnyxJson?.call(json);
        onTelnyxCallControl?.call(json);
      } else if (onTwilioForm != null) {
        onTwilioForm!(_parseFormBody(body));
      }
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

  static Map<String, String> _parseFormBody(String body) {
    try {
      return Map<String, String>.from(Uri.splitQueryString(body));
    } catch (_) {
      return {};
    }
  }
}
