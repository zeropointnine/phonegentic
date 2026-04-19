# Telnyx Messaging WebSocket Relay

## Problem

We want to observe inbound Telnyx messaging webhook events (message.received, message.sent, message.finalized, etc.) through the Rust server, similar to how call-control events are already relayed via `/ws/call_control`. This will help us verify that Telnyx messaging webhooks are firing and inspect their payloads.

## Solution

Extended the Rust Axum server with a second broadcast channel and WebSocket endpoint dedicated to messaging events:

- Added `messaging_tx` broadcast channel to `AppState`
- Extended `telnyx_webhook_handler` to detect `message.*` event types and broadcast them on the messaging channel
- Added `GET /ws/messaging` WebSocket endpoint that streams messaging events to connected clients
- All messaging webhook payloads are logged with the full event type for observability

The existing call-control relay (`/ws/call_control`) is unchanged.

## Files

- `static/static_server/src/main.rs` — added messaging broadcast channel, webhook forwarding, and `/ws/messaging` endpoint
- `static/DEPLOY.md` — added `/ws/messaging` to endpoint table
