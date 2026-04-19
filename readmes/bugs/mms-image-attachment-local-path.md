# MMS Image Attachment Sends Local File Path Instead of URL

## Problem

When a user attaches an image to a message (via file picker or drag-and-drop), the app sends the **local filesystem path** (e.g. `/Users/patrick/Desktop/Screenshot.png`) as the `media_urls` value to the Telnyx API. Telnyx requires publicly accessible HTTP/HTTPS URLs, so the request fails with error 40317 ("Invalid MMS content").

The bug exists in both `TelnyxMessagingProvider` and `TwilioMessagingProvider` — neither provider validates or transforms the media URLs before sending.

## Solution

Added a media upload step to the messaging providers. When `sendMessage` receives local file paths (anything not starting with `http://` or `https://`):

1. **Telnyx**: Upload to Telnyx Media Storage API (`POST /v2/media` multipart form-data), get back a `media_name`, construct the download URL
2. **Twilio**: Upload via Twilio's media creation endpoint to get a hosted URL
3. Both providers validate file size (< 1 MB for MMS) and provide clear error messages

The upload happens transparently inside each provider's `sendMessage` — no changes needed to `MessagingService`, `MessagingProvider` interface, or UI code.

Also added a friendly error message in `MessagingService._friendlyError` for the 40317 error code.

## Files

- `phonegentic/lib/src/messaging/telnyx_messaging_provider.dart` — added `_uploadLocalFile`, `_resolveMediaUrls`; modified `sendMessage`
- `phonegentic/lib/src/messaging/twilio_messaging_provider.dart` — added same upload logic for Twilio
- `phonegentic/lib/src/messaging/messaging_service.dart` — added friendly error for 40317
