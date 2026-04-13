//! Axum static file server
//!
//! Serves `WEB_ROOT` (default `/var/html`) at http://0.0.0.0:3000
//!
//! Email delivery:
//!   When `SENDGRID_API_KEY` is set, notifications are sent via the Twilio SendGrid
//!   v3 Mail Send API. Otherwise falls back to local `sendmail`.
//!   If both fail (or neither is configured), submissions are appended to a log file
//!   (`SMS_LOG_FILE` / `HELP_LOG_FILE`) so nothing is ever lost.

use axum::body::Bytes;
use axum::extract::{Form, State, WebSocketUpgrade};
use axum::extract::ws::{Message, WebSocket};
use axum::http::header::CONTENT_TYPE;
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Redirect, Response};
use axum::routing::{get, post};
use axum::Json;
use axum::Router;
use chrono::Utc;
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use serde::Serialize;
use std::fs::OpenOptions;
use std::io::Write;
use std::net::SocketAddr;
use std::process::{Command, Stdio};
use tokio::sync::broadcast;
use tower_http::{services::ServeDir, trace::TraceLayer};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

const DEFAULT_WEB_ROOT: &str = "/var/html";
const BIND_ADDR: &str = "0.0.0.0:3000";
const MAX_FIELD_LEN: usize = 256;
const MAX_NOTE_LEN: usize = 2000;
const DEFAULT_SMS_LOG: &str = "/var/log/sms_submissions.log";
const DEFAULT_HELP_LOG: &str = "/var/log/help_submissions.log";
const MAX_MESSAGE_LEN: usize = 5000;

/// Shared state: broadcast channel for relaying Telnyx call-control webhook
/// events to connected WebSocket clients (the Flutter app).
#[derive(Clone)]
struct AppState {
    call_control_tx: broadcast::Sender<String>,
}

fn sms_log_path() -> String {
    std::env::var("SMS_LOG_FILE").unwrap_or_else(|_| DEFAULT_SMS_LOG.to_string())
}

fn help_log_path() -> String {
    std::env::var("HELP_LOG_FILE").unwrap_or_else(|_| DEFAULT_HELP_LOG.to_string())
}

fn log_event(log_path: &str, event_type: &str, body: &str) {
    let ts = Utc::now().to_rfc3339();
    let entry = format!("[{}] {}\n{}\n---\n", ts, event_type, body);
    match OpenOptions::new().create(true).append(true).open(log_path) {
        Ok(mut f) => {
            if let Err(e) = f.write_all(entry.as_bytes()) {
                tracing::error!("failed to write log {}: {}", log_path, e);
            } else {
                tracing::info!("event logged to {}", log_path);
            }
        }
        Err(e) => tracing::error!("failed to open log {}: {}", log_path, e),
    }
}

fn log_sms_event(event_type: &str, body: &str) {
    log_event(&sms_log_path(), event_type, body);
}

fn log_help_event(event_type: &str, body: &str) {
    log_event(&help_log_path(), event_type, body);
}

/// Try SendGrid (if `SENDGRID_API_KEY` is set), then sendmail, then log to file.
async fn notify_or_log(to: Option<&str>, from: &str, subject: &str, body: &str) {
    if let Some(addr) = to {
        if let Some(key) = sendgrid_api_key() {
            match sendgrid_notify(&key, addr, from, subject, body).await {
                Ok(()) => {
                    tracing::info!("SendGrid succeeded for {}", subject);
                    return;
                }
                Err(e) => tracing::warn!("SendGrid failed ({}), trying sendmail", e),
            }
        }
        match sendmail_notify(addr, from, subject, body) {
            Ok(()) => {
                tracing::info!("sendmail succeeded for {}", subject);
                return;
            }
            Err(e) => tracing::warn!("sendmail failed ({}), falling back to file log", e),
        }
    } else {
        tracing::warn!("no email configured, logging to file");
    }
    log_sms_event(subject, body);
}

fn web_root() -> String {
    std::env::var("WEB_ROOT").unwrap_or_else(|_| DEFAULT_WEB_ROOT.to_string())
}

#[tokio::main]
async fn main() {
    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::new(
            std::env::var("RUST_LOG").unwrap_or_else(|_| "info".into()),
        ))
        .with(tracing_subscriber::fmt::layer())
        .init();

    let (call_control_tx, _) = broadcast::channel::<String>(64);
    let state = AppState { call_control_tx };

    let root = web_root();
    let app = router(root.clone(), state);

    let addr: SocketAddr = BIND_ADDR.parse().expect("Invalid bind address");
    tracing::info!("Listening on http://{}", addr);
    tracing::info!("Serving files from {}", root);

    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

fn router(web_root: String, state: AppState) -> Router {
    let images_dir = format!("{}/images", web_root);
    Router::new()
        .route("/api/health", get(health_handler))
        .route("/api/sms-opt-in", post(sms_opt_in_handler))
        .route("/api/sms-opt-out", post(sms_opt_out_dispatch))
        .route("/api/help", post(help_handler))
        .nest_service("/images", ServeDir::new(images_dir))
        .route("/web_hooks/telnyx", post(telnyx_webhook_handler))
        .route("/web_hooks/telnyx_fail", post(telnyx_fail_handler))
        .route("/ws/call_control", get(ws_call_control_handler))
        .fallback_service(ServeDir::new(web_root))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

async fn health_handler() -> &'static str {
    r#"{"status":"ok","server":"axum"}"#
}

async fn telnyx_webhook_handler(
    State(state): State<AppState>,
    Json(payload): Json<serde_json::Value>,
) -> StatusCode {
    let event_type = payload
        .pointer("/data/event_type")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown");

    tracing::info!(event_type, "Telnyx webhook received");

    let forward = match event_type {
        "call.initiated" | "call.answered" | "call.bridged" | "call.hangup"
        | "conference.participant.joined" | "conference.participant.left" => true,
        _ => false,
    };

    if forward {
        let msg = payload.to_string();
        let receivers = state.call_control_tx.receiver_count();
        if receivers > 0 {
            if let Err(e) = state.call_control_tx.send(msg) {
                tracing::warn!("WS broadcast failed: {}", e);
            } else {
                tracing::info!(event_type, receivers, "broadcast to WS clients");
            }
        }
    }

    StatusCode::OK
}

async fn telnyx_fail_handler() -> StatusCode {
    tracing::info!("Telnyx fail webhook received");
    StatusCode::OK
}

async fn ws_call_control_handler(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
) -> Response {
    tracing::info!("WebSocket upgrade request for /ws/call_control");
    ws.on_upgrade(move |socket| ws_call_control_session(socket, state))
}

async fn ws_call_control_session(socket: WebSocket, state: AppState) {
    let (mut ws_tx, mut ws_rx) = socket.split();
    let mut rx = state.call_control_tx.subscribe();

    tracing::info!("WS call_control client connected");

    let send_task = tokio::spawn(async move {
        while let Ok(msg) = rx.recv().await {
            if ws_tx.send(Message::Text(msg.into())).await.is_err() {
                break;
            }
        }
    });

    // Drain incoming frames (pings handled automatically); close on any error.
    let recv_task = tokio::spawn(async move {
        while let Some(Ok(_)) = ws_rx.next().await {}
    });

    tokio::select! {
        _ = send_task => {},
        _ = recv_task => {},
    }

    tracing::info!("WS call_control client disconnected");
}

fn env_email(key: &str) -> Option<String> {
    std::env::var(key)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Opt-in: `SMS_OPTIN_NOTIFY_EMAIL`, or shared `SMS_NOTIFY_EMAIL`.
fn sms_opt_in_notify_email() -> Option<String> {
    env_email("SMS_OPTIN_NOTIFY_EMAIL").or_else(|| env_email("SMS_NOTIFY_EMAIL"))
}

/// Opt-out: `SMS_OPTOUT_NOTIFY_EMAIL`, then `SMS_NOTIFY_EMAIL`, then opt-in address.
fn sms_opt_out_notify_email() -> Option<String> {
    env_email("SMS_OPTOUT_NOTIFY_EMAIL")
        .or_else(|| env_email("SMS_NOTIFY_EMAIL"))
        .or_else(sms_opt_in_notify_email)
}

/// Help form: `HELP_NOTIFY_EMAIL`, then `SMS_NOTIFY_EMAIL` as shared fallback.
fn help_notify_email() -> Option<String> {
    env_email("HELP_NOTIFY_EMAIL").or_else(|| env_email("SMS_NOTIFY_EMAIL"))
}

async fn notify_or_log_help(to: Option<&str>, from: &str, subject: &str, body: &str) {
    if let Some(addr) = to {
        if let Some(key) = sendgrid_api_key() {
            match sendgrid_notify(&key, addr, from, subject, body).await {
                Ok(()) => {
                    tracing::info!("SendGrid succeeded for {}", subject);
                    return;
                }
                Err(e) => tracing::warn!("SendGrid failed ({}), trying sendmail", e),
            }
        }
        match sendmail_notify(addr, from, subject, body) {
            Ok(()) => {
                tracing::info!("sendmail succeeded for {}", subject);
                return;
            }
            Err(e) => tracing::warn!("sendmail failed ({}), falling back to file log", e),
        }
    } else {
        tracing::warn!("no help email configured, logging to file");
    }
    log_help_event(subject, body);
}

fn mail_from() -> String {
    std::env::var("SMS_OPTIN_MAIL_FROM")
        .or_else(|_| std::env::var("SMS_MAIL_FROM"))
        .unwrap_or_else(|_| "Phonegentic <noreply@phonegentic.ai>".to_string())
}

#[derive(Debug, Deserialize)]
struct SmsOptInForm {
    phone: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    company: String,
    #[serde(default)]
    website: String,
    sms_consent: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SmsOptOutForm {
    phone: String,
    #[serde(default)]
    note: String,
    #[serde(default)]
    website: String,
}

#[derive(Debug, Deserialize)]
struct SmsOptOutJson {
    phone: String,
    #[serde(default)]
    note: String,
}

#[derive(Debug, Deserialize)]
struct HelpForm {
    #[serde(default)]
    name: String,
    #[serde(default)]
    email: String,
    message: String,
    #[serde(default)]
    website: String,
}

#[derive(Serialize)]
struct JsonError {
    error: String,
}

/// Set by static pages when submitting via `fetch()` so we return JSON instead of a redirect.
fn sms_ajax_submission(headers: &HeaderMap) -> bool {
    headers
        .get("x-sms-form")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.trim() == "1")
        .unwrap_or(false)
}

#[derive(Clone, Copy, Debug)]
enum OptOutFinishMode {
    JsonApi,
    AjaxForm,
    BrowserFormPost,
}

impl OptOutFinishMode {
    fn json_envelope(self) -> bool {
        matches!(self, Self::JsonApi | Self::AjaxForm)
    }

    fn mail_source(self) -> &'static str {
        match self {
            Self::JsonApi => "REST POST /api/sms-opt-out (application/json)",
            Self::AjaxForm => "Web form (in-page fetch) https://phonegentic.ai/sms-opt-out.html",
            Self::BrowserFormPost => "Web form https://phonegentic.ai/sms-opt-out.html",
        }
    }
}

fn opt_out_bad_request(ajax: bool, msg: &str) -> Response {
    if ajax {
        (
            StatusCode::BAD_REQUEST,
            Json(JsonError {
                error: msg.to_string(),
            }),
        )
            .into_response()
    } else {
        (StatusCode::BAD_REQUEST, msg.to_string()).into_response()
    }
}

fn trim_limit(s: String, max: usize) -> String {
    s.trim().chars().take(max).collect()
}

/// Normalize to E.164: strip non-digits, prepend +1 for 10-digit US/CA, + for 11 starting with 1.
/// Returns None if the result isn't 7–15 digits after +.
fn normalize_e164(s: &str) -> Option<String> {
    let t = s.trim();
    let has_plus = t.starts_with('+');
    let digits: String = t.chars().filter(|c| c.is_ascii_digit()).collect();

    let e164 = if has_plus {
        if (7..=15).contains(&digits.len()) {
            format!("+{}", digits)
        } else {
            return None;
        }
    } else if digits.len() == 10 {
        format!("+1{}", digits)
    } else if digits.len() == 11 && digits.starts_with('1') {
        format!("+{}", digits)
    } else if (7..=15).contains(&digits.len()) {
        format!("+{}", digits)
    } else {
        return None;
    };

    Some(e164)
}

fn sendgrid_api_key() -> Option<String> {
    env_email("SENDGRID_API_KEY")
}

/// Parse a "Display Name <addr>" or bare "addr" into (name, email).
fn parse_from_field(from: &str) -> (&str, &str) {
    if let Some(open) = from.find('<') {
        let name = from[..open].trim();
        let email = from[open + 1..].trim_end_matches('>').trim();
        (name, email)
    } else {
        ("", from.trim())
    }
}

async fn sendgrid_notify(
    api_key: &str,
    to: &str,
    from: &str,
    subject: &str,
    body: &str,
) -> Result<(), String> {
    let (from_name, from_email) = parse_from_field(from);

    let mut from_obj = serde_json::json!({ "email": from_email });
    if !from_name.is_empty() {
        from_obj["name"] = serde_json::json!(from_name);
    }

    let payload = serde_json::json!({
        "personalizations": [{
            "to": [{ "email": to }]
        }],
        "from": from_obj,
        "subject": subject,
        "content": [{
            "type": "text/plain",
            "value": body
        }]
    });

    let resp = reqwest::Client::new()
        .post("https://api.sendgrid.com/v3/mail/send")
        .bearer_auth(api_key)
        .json(&payload)
        .send()
        .await
        .map_err(|e| format!("SendGrid request failed: {}", e))?;

    let status = resp.status();
    if status.is_success() {
        Ok(())
    } else {
        let text = resp.text().await.unwrap_or_default();
        Err(format!("SendGrid HTTP {}: {}", status.as_u16(), text))
    }
}

fn sendmail_notify(to: &str, from: &str, subject: &str, body: &str) -> std::io::Result<()> {
    let mut child = Command::new("sendmail")
        .args(["-t", "-i"])
        .stdin(Stdio::piped())
        .spawn()?;

    let mut stdin = child.stdin.take().ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::Other, "sendmail stdin unavailable")
    })?;

    writeln!(stdin, "To: {}", to)?;
    writeln!(stdin, "From: {}", from)?;
    writeln!(stdin, "Subject: {}", subject)?;
    writeln!(stdin, "Content-Type: text/plain; charset=utf-8")?;
    writeln!(stdin)?;
    write!(stdin, "{}", body)?;
    drop(stdin);

    let status = child.wait()?;
    if status.success() {
        Ok(())
    } else {
        Err(std::io::Error::new(
            std::io::ErrorKind::Other,
            format!("sendmail exited with {:?}", status.code()),
        ))
    }
}

fn opt_in_err_response(ajax: bool, status: StatusCode, msg: &str) -> Response {
    if ajax {
        (status, Json(JsonError { error: msg.to_string() })).into_response()
    } else {
        (status, msg.to_string()).into_response()
    }
}

async fn sms_opt_in_handler(headers: HeaderMap, Form(form): Form<SmsOptInForm>) -> Response {
    let ajax = sms_ajax_submission(&headers);
    let thanks = Redirect::to("/sms-opt-in.html?thanks=1");

    if !form.website.trim().is_empty() {
        tracing::warn!("SMS opt-in honeypot triggered");
        if ajax {
            return (StatusCode::OK, Json(serde_json::json!({ "ok": true }))).into_response();
        }
        return thanks.into_response();
    }

    let phone = match normalize_e164(&trim_limit(form.phone, MAX_FIELD_LEN)) {
        Some(p) => p,
        None => {
            return opt_in_err_response(
                ajax,
                StatusCode::BAD_REQUEST,
                "Enter a valid mobile number (e.g. 4155331352 or +14155331352).",
            );
        }
    };

    let name = trim_limit(form.name, MAX_FIELD_LEN);
    let company = trim_limit(form.company, MAX_FIELD_LEN);

    let notify_to = sms_opt_in_notify_email();

    let body = format!(
        "New SMS marketing opt-in (web form)\n\
         \n\
         Phone (E.164): {}\n\
         Name: {}\n\
         Company: {}\n\
         Consent: explicit SMS marketing opt-in (checkbox), unchecked-by-default on form\n\
         \n\
         ---\n\
         Submitted via https://phonegentic.ai/sms-opt-in.html\n",
        phone,
        if name.is_empty() { "(not provided)" } else { &name },
        if company.is_empty() {
            "(not provided)"
        } else {
            &company
        },
    );

    notify_or_log(
        notify_to.as_deref(),
        &mail_from(),
        "Phonegentic SMS marketing opt-in",
        &body,
    )
    .await;

    tracing::info!(phone = %phone, "SMS opt-in processed");
    if ajax {
        (StatusCode::OK, Json(serde_json::json!({ "ok": true }))).into_response()
    } else {
        thanks.into_response()
    }
}

async fn sms_opt_out_dispatch(headers: HeaderMap, body: Bytes) -> Response {
    let ct = headers
        .get(CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_lowercase();

    if ct.starts_with("application/json") {
        sms_opt_out_json(body).await
    } else {
        sms_opt_out_form(headers, body).await
    }
}

async fn sms_opt_out_form(headers: HeaderMap, body: Bytes) -> Response {
    let ajax = sms_ajax_submission(&headers);
    let thanks = Redirect::to("/sms-opt-out.html?thanks=1");
    let form: SmsOptOutForm = match serde_urlencoded::from_bytes(&body) {
        Ok(f) => f,
        Err(_) => {
            return opt_out_bad_request(ajax, "Invalid form submission.");
        }
    };

    if !form.website.trim().is_empty() {
        tracing::warn!("SMS opt-out honeypot triggered");
        if ajax {
            return (StatusCode::OK, Json(serde_json::json!({ "ok": true }))).into_response();
        }
        return thanks.into_response();
    }

    let phone = match normalize_e164(&trim_limit(form.phone, MAX_FIELD_LEN)) {
        Some(p) => p,
        None => {
            return opt_out_bad_request(
                ajax,
                "Enter a valid mobile number (e.g. 4155331352 or +14155331352).",
            );
        }
    };

    let note = trim_limit(form.note, MAX_NOTE_LEN);
    let mode = if ajax {
        OptOutFinishMode::AjaxForm
    } else {
        OptOutFinishMode::BrowserFormPost
    };
    finish_sms_opt_out(phone, note, mode).await
}

async fn sms_opt_out_json(body: Bytes) -> Response {
    if body.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(JsonError {
                error: "empty body".into(),
            }),
        )
            .into_response();
    }

    let payload: SmsOptOutJson = match serde_json::from_slice(&body) {
        Ok(p) => p,
        Err(e) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(JsonError {
                    error: format!("invalid JSON: {}", e),
                }),
            )
                .into_response();
        }
    };

    let phone = match normalize_e164(&trim_limit(payload.phone, MAX_FIELD_LEN)) {
        Some(p) => p,
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(JsonError {
                    error: "Enter a valid mobile number (e.g. 4155331352 or +14155331352)".into(),
                }),
            )
                .into_response();
        }
    };

    let note = trim_limit(payload.note, MAX_NOTE_LEN);
    finish_sms_opt_out(phone, note, OptOutFinishMode::JsonApi).await
}

async fn finish_sms_opt_out(phone: String, note: String, mode: OptOutFinishMode) -> Response {
    let json_env = mode.json_envelope();
    let notify_to = sms_opt_out_notify_email();

    let note_line = if note.is_empty() {
        "(not provided)".to_string()
    } else {
        note.clone()
    };

    let body = format!(
        "SMS marketing opt-out request\n\
         \n\
         Phone (E.164): {}\n\
         Note: {}\n\
         Source: {}\n\
         \n\
         ---\n\
         Process this number on your SMS subscriber list / Telnyx campaign.\n",
        phone,
        note_line,
        mode.mail_source(),
    );

    notify_or_log(
        notify_to.as_deref(),
        &mail_from(),
        "Phonegentic SMS marketing opt-out",
        &body,
    )
    .await;

    tracing::info!(phone = %phone, ?mode, "SMS opt-out processed");

    if json_env {
        (StatusCode::OK, Json(serde_json::json!({ "ok": true }))).into_response()
    } else {
        Redirect::to("/sms-opt-out.html?thanks=1").into_response()
    }
}

async fn help_handler(headers: HeaderMap, Form(form): Form<HelpForm>) -> Response {
    let ajax = headers
        .get(CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.contains("urlencoded"))
        .unwrap_or(false);
    let thanks = Redirect::to("/help.html?thanks=1");

    if !form.website.trim().is_empty() {
        tracing::warn!("help form honeypot triggered");
        if ajax {
            return (StatusCode::OK, Json(serde_json::json!({ "ok": true }))).into_response();
        }
        return thanks.into_response();
    }

    let message = trim_limit(form.message, MAX_MESSAGE_LEN);
    if message.is_empty() {
        return (StatusCode::BAD_REQUEST, "Please enter a message.").into_response();
    }

    let name = trim_limit(form.name, MAX_FIELD_LEN);
    let email = trim_limit(form.email, MAX_FIELD_LEN);

    let notify_to = help_notify_email();

    let body = format!(
        "Help / support request (web form)\n\
         \n\
         Name: {}\n\
         Email: {}\n\
         \n\
         Message:\n{}\n\
         \n\
         ---\n\
         Submitted via https://phonegentic.ai/help.html\n",
        if name.is_empty() { "(not provided)" } else { &name },
        if email.is_empty() { "(not provided)" } else { &email },
        message,
    );

    notify_or_log_help(
        notify_to.as_deref(),
        &mail_from(),
        "Phonegentic help request",
        &body,
    )
    .await;

    tracing::info!("help request processed");
    (StatusCode::OK, Json(serde_json::json!({ "ok": true }))).into_response()
}
