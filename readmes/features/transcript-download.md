# Transcript Download & File Attachment

**Date:** 2026-04-12

## Problem

There is no way to export or download call transcripts from the app. Transcripts are stored in SQLite (`call_transcripts` table) and displayed in the call history panel, but users cannot save them as text files. Additionally, there is no mechanism to attach a text file (e.g., a previous transcript or notes) to the agent for silent understanding — the agent can only receive typed text or voice input.

## Solution

### Phase 1: Transcript Download Utility

- Add a `TranscriptExporter` utility that formats transcript data into a readable `.txt` file
- Formats: timestamped lines with role labels, call metadata header
- Saves to the system Downloads directory (reusing the pattern from `_RecordingPlayer._downloadRecording`)

### Phase 2: Download UI in Call History Panel

- Add a download button to the transcript section header in `_CallRecordTile._buildTranscriptSection()`
- Button appears when transcripts are loaded and non-empty
- Triggers the `TranscriptExporter` utility

### Phase 3: Download from Main Agent Panel

- Add a download button to the agent panel header area (overflow/action menu)
- Exports the current session's messages as a transcript file
- Works for both live and completed conversations

### Phase 4: Drag-and-Drop Text File Attachment

- Add `DropTarget` (from `desktop_drop`) to the agent panel
- Accept `.txt` files only
- Read file contents and send to agent as a system context (not read back via TTS)
- Add a file picker button to the `_InputBar` for explicit file attachment
- Visual feedback: drop zone overlay, attached file chip

## Files

### Created
- `phonegentic/lib/src/transcript_exporter.dart` — export utility

### Modified
- `phonegentic/lib/src/widgets/call_history_panel.dart` — download button in transcript section
- `phonegentic/lib/src/widgets/agent_panel.dart` — download current transcript + drag-and-drop attachment
- `phonegentic/lib/src/agent_service.dart` — method to accept file content as silent context
- `phonegentic/lib/src/models/chat_message.dart` — new `attachment` message type
