# Conversation unread counter not clearing on open

## Problem

Opening an SMS conversation does not immediately clear the unread counter. The `selectConversation` method calls `_startReadTimer()` which waits 30 seconds (`_readDelayMs = 30000`) before calling `markConversationRead`. Users expect the counter to clear as soon as they view the conversation.

## Solution

Call `markConversationRead` immediately in `selectConversation` instead of deferring it behind the 30-second engagement timer. The timer is still useful for the lifecycle/focus-change scenario (user tabs away then back), but selecting a conversation is an explicit user action that should mark it as read right away.

## Files

- `phonegentic/lib/src/messaging/messaging_service.dart` — call `markConversationRead` in `selectConversation`
