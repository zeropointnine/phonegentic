<p align="center">
  <img src="phonegentic/assets/phonegentic_logo.svg" width="72" height="72" alt="Phonegentic AI logo" />
</p>

<h1 align="center">Phonegentic AI</h1>

<p align="center">
  A retro-future SIP softphone with a built-in AI voice agent that joins your calls.
</p>

<p align="center">
  <a href="https://pub.dev/packages/sip_ua"><img src="https://img.shields.io/pub/v/sip_ua.svg" alt="pub package" /></a>
  <a href="https://opencollective.com/flutter-webrtc"><img src="https://opencollective.com/flutter-webrtc/all/badge.svg?label=financial+contributors" alt="Financial Contributors on Open Collective" /></a>
  <a href="https://join.slack.com/t/flutterwebrtc/shared_invite/zt-q83o7y1s-FExGLWEvtkPKM8ku_F8cEQ"><img src="https://img.shields.io/badge/join-us%20on%20slack-gray.svg?longCache=true&logo=slack&colorB=brightgreen" alt="slack" /></a>
</p>

---

## What is Phonegentic?

Phonegentic is a Flutter SIP softphone built on the [`sip_ua`](https://pub.dev/packages/sip_ua) library (a Dart port of [JsSIP](https://github.com/versatica/JsSIP)). What makes it different is a real-time AI voice agent that participates in your calls as a third party.

The app captures **both sides** of a live SIP/WebRTC call -- your microphone and the remote caller's audio -- taps the raw PCM stream, and pipes it to the **OpenAI Realtime API**. The AI listens, understands context, and speaks back into the call with sub-second latency. Think of it as giving every phone call an AI copilot.

### Use cases

- **3-way AI call participant** -- trivia host, interview coach, meeting facilitator
- **Real-time transcription and note-taking** -- the agent transcribes both sides of the conversation live
- **Call quality monitoring and compliance** -- flag keywords, enforce scripts, score calls automatically
- **AI receptionist / IVR replacement** -- handle inbound calls with natural conversation instead of "press 1"
- **Accessibility** -- live captioning for deaf or hard-of-hearing callers

## Architecture

### System overview

```mermaid
%%{init: {'theme': 'neutral'}}%%
flowchart TB
  Caller["Remote Caller\n(SIP / PSTN)"]
  SIP["SIP Server\n(Telnyx, Asterisk, etc.)"]
  App["Phonegentic App\n(Flutter)"]
  OAI["OpenAI Realtime API"]
  Claude["Claude API\n(Anthropic)"]
  EL["ElevenLabs\nWebSocket TTS"]
  DB[(SQLite)]

  Caller <-->|"SIP / WebRTC\naudio + signalling"| SIP
  SIP <-->|"SIP / WebRTC"| App

  App -->|"PCM16 24 kHz\n(mic + remote)"| OAI
  OAI -->|"transcripts +\nfunction calls"| App

  App -.->|"transcripts"| Claude
  Claude -.->|"streaming text\nresponses"| App

  App -.->|"text chunks"| EL
  EL -.->|"PCM16 audio"| App

  App --- DB

  style OAI fill:#10a37f,color:#fff
  style Claude fill:#d97706,color:#fff
  style EL fill:#6366f1,color:#fff
```

<sub>Solid lines = standard pipeline (always active). Dashed lines = split pipeline (optional, when a separate text agent and/or TTS provider is configured).</sub>

### Pipelines

Phonegentic supports two agent pipeline modes, configured in **Settings > Agents**:

**Standard pipeline** — OpenAI Realtime handles transcription, reasoning, and speech output in a single WebSocket connection. Lowest latency, simplest setup.

```mermaid
%%{init: {'theme': 'neutral'}}%%
flowchart LR
  Tap["Audio Tap\n(native)"] -->|"PCM16 mono\n24 kHz"| WS["OpenAI Realtime\nWebSocket"]
  WS -->|transcripts| UI["Agent Panel\n(chat UI)"]
  WS -->|TTS audio| Play["playResponseAudio\n→ call speaker"]
  WS -->|function calls| Tools["Agent Tools\n(search, dial, DTMF, …)"]
```

**Split pipeline** — OpenAI Realtime still captures audio and produces transcripts, but reasoning is handled by a separate LLM (Claude) and speech output by ElevenLabs TTS. This lets you mix best-in-class models for each stage.

```mermaid
%%{init: {'theme': 'neutral'}}%%
flowchart LR
  Tap["Audio Tap\n(native)"] -->|"PCM16"| WS["OpenAI Realtime\n(transcription only)"]
  WS -->|transcripts| TA["TextAgentService\n(Claude)"]
  TA -->|"streaming text"| UI["Agent Panel"]
  TA -->|"streaming text"| TTS["ElevenLabsTtsService"]
  TTS -->|"PCM16 audio"| Play["playResponseAudio\n→ call speaker"]
```

### Internal services

```mermaid
%%{init: {'theme': 'neutral'}}%%
flowchart TB
  subgraph UI["UI Layer"]
    DP["DialPad"]
    AP["AgentPanel"]
    CS["CallScreen"]
    TS["TearSheetStrip"]
  end

  subgraph Services["Service Layer (ChangeNotifier / Provider)"]
    AS["AgentService"]
    JFS["JobFunctionService"]
    CHS["CallHistoryService"]
    ConS["ContactService"]
    TSS["TearSheetService"]
    SIP["SipUserCubit"]
  end

  subgraph IO["I/O Layer"]
    WR["WhisperRealtimeService\n(OpenAI WebSocket + native audio tap)"]
    TAS["TextAgentService\n(Claude HTTP streaming)"]
    EL["ElevenLabsTtsService\n(WebSocket TTS)"]
    DB[(SQLite\ncall history · contacts\njob functions · voiceprints\ntear sheets)]
  end

  DP --> SIP
  AP --> AS
  CS --> AS
  TS --> TSS

  AS --> WR
  AS --> TAS
  AS --> EL
  AS --> JFS
  AS --> CHS
  AS --> ConS
  TSS --> AS

  JFS --> DB
  CHS --> DB
  ConS --> DB
  TSS --> DB
```

### How the audio pipeline works

1. A SIP/WebRTC call is established through any standard SIP server.
2. A native audio tap on the device captures PCM from both the microphone (host) and the remote WebRTC stream (caller).
3. The mixed PCM16 mono 24 kHz audio is streamed over a WebSocket to the OpenAI Realtime API.
4. OpenAI transcribes the speech, generates a response (or, in split pipeline mode, forwards transcripts to Claude), and returns TTS audio.
5. The TTS audio is played back into the call so both the host and the remote caller hear the agent.
6. Transcripts and agent messages appear in a side-panel chat UI in real time.
7. An IVR/auto-attendant detector suppresses transcripts during the settling window after a call connects, preventing robotic prompts from polluting the conversation.
8. Speaker identification via on-device voiceprint embeddings labels transcripts with known contact names.

### Call lifecycle

```mermaid
%%{init: {'theme': 'neutral'}}%%
sequenceDiagram
    actor User
    participant App as Phonegentic App
    participant SIP as SIP Server
    actor Caller as Remote Caller
    participant Tap as Audio Tap<br/>(native)
    participant OAI as OpenAI Realtime API

    Note over App: Agent boots → WebSocket to OpenAI,<br/>sends boot context + instructions

    User->>App: Presses Dial
    App->>SIP: SIP INVITE (WebRTC)
    SIP->>Caller: Ring
    Caller-->>SIP: Answer
    SIP-->>App: 200 OK → CONFIRMED

    rect rgb(255, 247, 230)
        Note over App,Tap: Settling phase (~8 s)
        App->>Tap: enterCallMode()
        Tap->>Tap: Register WebRTC audio processor
        App->>OAI: [CALL_STATE: settling] (silent context)
        Note over App: IVR detector suppresses<br/>robotic prompts
    end

    rect rgb(230, 255, 235)
        Note over App: User taps "Party On" or timer expires → connected
        App->>OAI: [CALL_STATE: connected] (silent context)

        loop Every 100 ms while call is active
            Tap->>Tap: Capture mic PCM + remote WebRTC PCM
            Tap->>Tap: Mix to mono PCM16 24 kHz
            Tap->>App: EventChannel (Uint8List chunk)
            App->>OAI: input_audio_buffer.append (base64)
        end

        OAI-->>App: transcription.completed
        App->>App: Speaker ID (voiceprint + dominant speaker)
        App->>App: Display transcript in Agent Panel

        Note over OAI: Model reasons + generates response

        OAI-->>App: response.audio.delta (PCM16 TTS)
        App->>Tap: playResponseAudio (PCM16)
        Tap->>Tap: Mix TTS into capture path (→ caller)<br/>+ render path (→ host headphones)
        Note over Tap: Echo suppression: omit mic<br/>from tap mix during TTS

        Note right of Caller: Caller hears AI voice
        Note right of User: Host hears AI voice
    end

    User->>App: Hang up
    App->>SIP: BYE
    App->>OAI: Disconnect WebSocket
    Note over App: Save call history + voiceprints
```

## Getting started

### Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (stable channel)
- A **SIP account** with WebSocket (WSS) transport ([see below](#sip-credentials))
- An **OpenAI API key** with Realtime API access ([see below](#ai-voice-agent-setup))

### Run the app

```bash
git clone https://github.com/user/dart-sip-ua.git
cd dart-sip-ua/phonegentic
flutter pub get
flutter run            # or: flutter run -d macos | chrome | windows | linux
```

On first launch the app will attempt to auto-register using the credentials in [`phonegentic/lib/src/test_credentials.dart`](phonegentic/lib/src/test_credentials.dart). To use your own account, either edit that file or configure credentials at runtime through **Settings** (the gear icon in the top bar).

## SIP credentials

A SIP account is required to make and receive calls. You need a provider that supports **WebSocket (WSS) transport** for use with WebRTC.

### What you need

| Field | Example |
|-------|---------|
| **WebSocket URL** | `wss://sip.telnyx.com:7443` |
| **SIP URI** | `youruser@sip.telnyx.com` |
| **Auth User** | `youruser` |
| **Password** | `your-password` |

### Where to get SIP credentials

If you do not already have a SIP provider, credentials can be purchased from [**Telnyx**](https://telnyx.com/) -- they provide SIP trunking with full WebSocket/WebRTC support, global coverage, and sub-500ms latency.

Other compatible SIP servers and providers:

- [Asterisk](https://github.com/flutter-webrtc/dockers/tree/main/asterisk) (self-hosted, free)
- FreeSWITCH (self-hosted, free)
- OpenSIPS / Kamailio (self-hosted, free)
- 3CX (commercial PBX with WSS support)
- [tryit.jssip.net](https://tryit.jssip.net) (free public demo for testing)

### Option A: Edit `test_credentials.dart` (auto-register on launch)

Open [`phonegentic/lib/src/test_credentials.dart`](phonegentic/lib/src/test_credentials.dart) and replace the placeholder values:

```dart
static String telnyxUsername = 'YOUR_SIP_USERNAME';
static String telnyxPassword = 'YOUR_SIP_PASSWORD';
```

Then point `sipUser` to your provider getter:

```dart
static SipUser get sipUser => _telnyx;
```

### Option B: Configure at runtime

Tap the **menu icon** (top-right) and select **Settings**. The **Phone** tab lets you enter all SIP fields and register on the fly. Values are persisted with `SharedPreferences`.

## AI voice agent setup

The AI agent uses the **OpenAI Realtime API** to listen, think, and speak during live calls.

### Requirements

- An **OpenAI API key** with access to the Realtime API
- A supported model: `gpt-4o-mini-realtime-preview` or `gpt-4o-realtime-preview`

### Configuration

1. Open the app and go to **Settings > Agents** tab.
2. Toggle **Voice Agent** on.
3. Paste your **OpenAI API key**.
4. Pick a **model** and **voice**.
5. Optionally write custom **instructions** to control the agent's personality and behavior.

### Available voices

`coral` (default), `alloy`, `ash`, `ballad`, `echo`, `sage`, `shimmer`, `verse`, `marin`, `cedar`

### Custom instructions

The instructions field accepts freeform text that becomes the agent's system prompt. By default the agent boots as a trivia host, but you can replace this with any persona:

> *"You are a medical intake assistant. Greet the caller, collect their name, date of birth, and reason for visit. Be concise and empathetic."*

The agent automatically identifies speakers as **Host** (mic audio) and **Remote Party** (call audio) and will ask for names if not provided.

### Listen To

The **Listen To** setting controls whose audio the agent transcribes:

| Setting | Behavior |
|---------|----------|
| **Both Sides** | Agent hears host + remote caller (default) |
| **Local Only** | Agent hears only the host's microphone |
| **Remote Only** | Agent hears only the remote caller |

## Agent boot context

When the agent joins a call it needs to know **who it is**, **who else is on the call**, **what its job is**, and **what rules to follow**. This is managed by `AgentBootContext` in [`phonegentic/lib/src/models/agent_context.dart`](phonegentic/lib/src/models/agent_context.dart).

### How it works

On startup, `AgentService` creates a boot context and converts it to a structured system prompt via `toInstructions()`. If the user has written custom instructions in Settings > Agents, those override the boot context entirely. Otherwise the boot context generates the prompt automatically from its four fields:

```
AgentBootContext
├── role            →  "## Identity" block (who the agent is)
├── speakers[]      →  "## Speakers" block (who is on the call)
├── jobFunction     →  "## Job Function" block (what to do)
└── guardrails[]    →  "## Guardrails" block (behavioral constraints)
```

The generated prompt also includes a fixed **Rules** section that teaches the agent how to interpret speaker labels (`[Host]:` vs `[Remote Party 1]:`) and to ask for names.

### Default boot context

Out of the box the app ships with `AgentBootContext.trivia()`, a 3-party trivia host:

```dart
AgentBootContext(
  role: 'You are a voice AI agent participating in a 3-party phone call.',
  jobFunction: 'Host a 3-party trivia game with 3 easy questions. Keep score. Award the winner.',
  speakers: [
    Speaker(role: 'Host', source: 'mic'),
    Speaker(role: 'Remote Party 1', source: 'remote'),
  ],
  guardrails: [
    'Stay in character as the trivia host.',
    'Keep questions family-friendly and easy.',
    'Announce scores after each question.',
    'Declare a winner after all 3 questions.',
  ],
);
```

### Creating a custom boot context

To change the agent's persona programmatically, create a new `AgentBootContext` and assign it before the agent initializes. For example, a meeting note-taker:

```dart
AgentBootContext(
  role: 'You are an AI meeting assistant on a live phone call.',
  jobFunction: 'Listen to the conversation silently. When asked, provide a summary '
               'of what was discussed. Track action items and who they were assigned to.',
  speakers: [
    Speaker(role: 'Project Manager', source: 'mic'),
    Speaker(role: 'Client', source: 'remote'),
  ],
  guardrails: [
    'Do not interrupt unless directly addressed.',
    'Keep summaries concise -- bullet points, not paragraphs.',
    'Never fabricate details that were not said on the call.',
  ],
);
```

Or a QA compliance monitor:

```dart
AgentBootContext(
  role: 'You are a call quality analyst monitoring a customer support call.',
  jobFunction: 'Score the agent on greeting, empathy, resolution, and closing. '
               'Flag any policy violations in real time.',
  speakers: [
    Speaker(role: 'Support Agent', source: 'mic'),
    Speaker(role: 'Customer', source: 'remote'),
  ],
  guardrails: [
    'Do not speak aloud during the call -- text-only feedback.',
    'Be objective. Cite specific phrases when flagging issues.',
  ],
);
```

### The `Speaker` model

Each speaker on the call is described by:

| Field | Type | Description |
|-------|------|-------------|
| `role` | `String` | A label for this participant (e.g. `"Host"`, `"Customer"`) |
| `source` | `String` | Audio source: `"mic"` for local microphone, `"remote"` for the WebRTC stream |
| `name` | `String` | The speaker's real name (initially empty; the agent or host can set it at runtime) |

The `label` getter returns `name` if set, otherwise falls back to `role`. Transcripts in the chat UI use this label to attribute who said what.

Speaker names can be updated mid-call by the agent (it will ask "May I get your first names?") or programmatically:

```dart
agentService.updateSpeakerName('Host', 'Patrick');
agentService.updateSpeakerName('Remote Party 1', 'Sarah');
```

### Instructions priority

The system resolves the agent's instructions in this order:

1. **Settings > Agents > Instructions** -- if the user has typed custom instructions in the UI, those are used verbatim as the system prompt.
2. **`AgentBootContext.toInstructions()`** -- if the instructions field is empty, the boot context generates a structured prompt from `role`, `speakers`, `jobFunction`, and `guardrails`.

This means you can either give end users a freeform text box (the Settings approach) or wire up structured boot contexts in code for specific workflows.

## Features

### Job Functions — switchable agent personas

Job Functions let you define reusable agent personas and swap between them instantly. Each job function bundles a role, job description, speaker definitions, guardrails, whisper-by-default preference, and an optional ElevenLabs voice ID.

- **Dropdown selector** — the agent panel header shows a dropdown of all saved job functions. Selecting one reconnects the agent with the new persona and clears the chat history for a clean start.
- **CRUD editor** — create, edit, and delete job functions from the full-screen editor (tap the pencil icon next to the dropdown).
- **Persisted selection** — the last-used job function is saved to `SharedPreferences` and restored on next launch.
- **Per-function voice** — each job function can specify its own ElevenLabs voice ID, so a sales persona can sound different from a support persona.

### Tear Sheet — AI-driven call queue

Tear Sheet is an automated call queue mode. Instead of manually entering phone numbers, you describe who you want to call in natural language — the AI agent searches your contacts and call history, builds the queue, and dials through it sequentially.

**How it works:**

1. Tap the tear sheet icon (or select **New Tear Sheet** from the menu on narrow screens).
2. Describe the criteria in the prompt, e.g. *"Contacts not called in 2 weeks"* or *"All contacts tagged lead."*
3. The agent searches your contacts database via the `search_contacts` tool, then creates the queue with `create_tear_sheet`.
4. The Tear Sheet strip docks at the top of the screen with play/pause/skip controls.
5. Press **Play** — the agent calls through the list automatically, reporting outcomes after each call.
6. Press **Pause** at any time to hold after the current call.

You can also create a Tear Sheet from call history search results using the **Tear Sheet** button in the call history panel header.

**Agent tools:**

| Tool | Description |
|------|-------------|
| `search_contacts` | Query the contacts DB by name, phone, tags, or call recency (`not_called_since_days`) |
| `create_tear_sheet` | Build a call queue from a list of `{phone_number, name}` entries |

### Contacts

A native-feeling contact store inside Phonegentic. When a known contact is called, their name automatically appears above the number on the active call screen.

- **Quick Add** — tap `+` to add a contact with a single field (name or phone). Phonegentic infers the type.
- **Inline editing** — tap any field on a contact card to edit it in place.
- **Call screen integration** — matching contacts display as `[Name]` above the number during a call.
- **Alphabetical index** — the contact list is grouped A–Z with live search.

### Whisper Mode

A real-time, host-only command channel to the AI agent that does not trigger any verbal readback. The agent receives the instruction silently and acts on it — the caller never hears a thing.

- Toggle via the ear icon on the active call screen.
- While active, anything typed in the agent panel is sent as a silent `[WHISPER]` instruction.
- The agent adjusts its behavior without acknowledging the instruction aloud.
- Whisper messages appear in the chat log as grayed-out italic entries labeled **W**.

### Responsive top bar

On narrow windows (below 700px), the Tear Sheet, Contacts, Call History, and Audio Devices buttons collapse into the overflow menu to keep the UI clean.

## Supported platforms

- [x] iOS
- [x] Android
- [x] Web
- [x] macOS
- [x] Windows
- [x] Linux

## Install notes

### Android Proguard

```
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

-keep class com.cloudwebrtc.webrtc.** {*;}
-keep class org.webrtc.** {*;}
```

## FAQ

<details>
<summary>Expand</summary>

### Server not configured for DTLS/SRTP

`WEBRTC_SET_REMOTE_DESCRIPTION_ERROR: Failed to set remote offer sdp: Called with SDP without DTLS fingerprint.`

Your server is not sending a DTLS fingerprint inside the SDP. WebRTC requires encryption by default -- all communications are encrypted using DTLS and SRTP. Your PBX must be configured to use DTLS/SRTP when calling sip_ua.

### Why isn't there a UDP connection option?

This package uses WS or TCP for SIP signalling. Once the session is connected, WebRTC transmits media (audio/video) over UDP automatically.

### SIP/2.0 488 Not acceptable here

The codecs on your PBX server don't match what WebRTC offers:

- **opus** (111, 48 kHz, 2ch)
- **G722** (9, 8 kHz, 1ch)
- **PCMU** (0, 8 kHz, 1ch)
- **PCMA** (8, 8 kHz, 1ch)
- **telephone-event** (110, 48 kHz / 8 kHz)
</details>


## License
Phonegentic AI is released under the [MIT license](LICENSE).
