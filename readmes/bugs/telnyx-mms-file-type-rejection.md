# Telnyx MMS Image Upload & Delivery Failures

## Problem

Two sequential issues when pasting a screenshot into a messaging conversation:

### Phase 1: Upload rejection (422)
The Telnyx Media API rejected the upload because the filename `Screenshot 2026-04-19 at 10.33.33 AM.png` (with spaces and multiple dots) caused file-type detection to fail, even though `.png` is accepted.

### Phase 2: Delivery failure (401 media fetch)
After fixing the upload, Telnyx accepted the file but its MMS system couldn't deliver it. The download URL (`/v2/media/.../download`) requires Bearer token auth. When the MMS pipeline tried to fetch the media to send to the carrier, it got a 401:

```
"media_error": "Bad status code received while fetching media: 401"
```

Per Telnyx docs: *"Media URLs must be publicly accessible."* Their own Media Storage API is auth-gated, making it useless for MMS.

## Solution

### Phase 1 fix — explicit content type
- Added `_extToMime` map for all Telnyx-accepted file types
- Extract extension, look up MIME, reject early for unsupported types
- Set `contentType` and `filename` explicitly on the `MultipartFile` using a clean timestamp-based name

### Phase 2 fix — public media hosting
Replaced Telnyx Media Storage with a new upload endpoint on the phonegentic.ai server:

**Server side** (`static_server/src/main.rs`):
- Added `POST /api/media/upload` (multipart) that saves to `/images/mms/` and returns a public URL
- Protected by `MEDIA_UPLOAD_SECRET` env var (shared secret in `x-upload-secret` header)
- Validates file type, enforces 2 MB limit, generates UUID-based filenames

**Client side** (`telnyx_messaging_provider.dart`):
- `_uploadLocalFile` now POSTs to `https://phonegentic.ai/api/media/upload` instead of Telnyx
- Sends `x-upload-secret` header from config
- Returns the public `https://phonegentic.ai/images/mms/...` URL

**Config** (`messaging_config.dart` + settings UI):
- Added `mediaUploadSecret` field to `TelnyxMessagingConfig`
- Added "MMS Upload Secret" field in Settings > Messaging > Telnyx

## Files

- `phonegentic/lib/src/messaging/telnyx_messaging_provider.dart` — rewritten `_uploadLocalFile`
- `phonegentic/lib/src/messaging/messaging_config.dart` — added `mediaUploadSecret`
- `phonegentic/lib/src/messaging/messaging_service.dart` — thread secret to provider
- `phonegentic/lib/src/widgets/user_settings_tab.dart` — upload secret UI field
- `phonegentic/pubspec.yaml` — added explicit `http_parser` dependency
- `static/static_server/src/main.rs` — added `/api/media/upload` endpoint
- `static/static_server/Cargo.toml` — added `uuid`, `multipart` feature
- `static/static_server/.env.example` — documented `MEDIA_UPLOAD_SECRET`
- `static/DEPLOY.md` — documented env var and endpoint
