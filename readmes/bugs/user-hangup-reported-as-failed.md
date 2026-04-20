# User Hangup Incorrectly Reported as Failed Call

## Problem

When the user hangs up an outgoing call — even if unanswered — the system
reports it as a **failed** call.  This is wrong: the user deliberately ended the
call, which is a normal hang-up, not a failure.

### Root cause

`RTCSession.terminate()` is called when the user presses the hang-up button.
For outgoing calls that haven't been answered yet (states `none`,
`inviteSent`, `provisionalResponse`), this cancels the INVITE and calls the
internal `_failed()` helper with `Originator.local` + `CausesType.CANCELED`.
That emits `EventCallFailed`, which `SIPUAHelper` translates to
`CallStateEnum.FAILED`.

The call-screen then:
- Shows "Failed" in the status label.
- Tells `TearSheetService.onCallEnded('failed')`, which flags the tear-sheet
  item.

The same path applies when the user **rejects** an incoming call (local +
`CausesType.REJECTED`).

## Solution

In `sip_ua_helper.dart`, inside the `EventCallFailed` handler, detect
locally-initiated cancellations/rejections and emit `CallStateEnum.ENDED`
instead of `CallStateEnum.FAILED`.  This keeps the low-level SIP library
semantics untouched while giving the UI the correct signal.

## Files

- `lib/src/sip_ua_helper.dart` — remap local cancel/reject to ENDED
- `phonegentic/lib/src/callscreen.dart` — update tear-sheet status for ENDED originator logic
