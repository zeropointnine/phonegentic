//! Axum static file server
//!
//! Serves /var/html at http://0.0.0.0:3000
//! Extensible: add API routes in the `router()` function below.

use axum::{Router, routing::get, response::Html};
use std::net::SocketAddr;
use tower_http::{
    services::ServeDir,
    trace::TraceLayer,
};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};
use axum::http::StatusCode;
use axum::routing::post;    
const WEB_ROOT:  &str = "/var/html";
const BIND_ADDR: &str = "0.0.0.0:3000";

#[tokio::main]
async fn main() {
    // ── Logging ──────────────────────────────────────────────────────────────
    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::new(
            std::env::var("RUST_LOG").unwrap_or_else(|_| "info".into()),
        ))
        .with(tracing_subscriber::fmt::layer())
        .init();

    let app = router();

    let addr: SocketAddr = BIND_ADDR.parse().expect("Invalid bind address");
    tracing::info!("Listening on http://{}", addr);
    tracing::info!("Serving files from {}", WEB_ROOT);

    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

/// Build the application router.
///
/// Structure:
///   GET  /           → serves index.html from WEB_ROOT
///   GET  /images/*   → serves files from WEB_ROOT/images/
///   GET  /static/*   → serves all of WEB_ROOT
///   GET  /api/health → JSON health-check (example API route)
///
/// To extend: add more `.route(...)` calls or nest routers here.
fn router() -> Router {
    Router::new()
        .route("/api/health", get(health_handler))
        .nest_service(
            "/images",
            ServeDir::new(format!("{}/images", WEB_ROOT)),
        )
        .route("/web_hooks/telnyx", post(telnyx_webhook_handler))
        .route("/web_hooks/telnyx_fail", post(telnyx_fail_handler))
        // This serves ALL files in WEB_ROOT at their natural paths
        // including index.html, privacy.html, terms.html, etc.
        .fallback_service(ServeDir::new(WEB_ROOT))
        .layer(TraceLayer::new_for_http())
    }
/// Serve index.html from WEB_ROOT
async fn index_handler() -> Result<Html<String>, String> {
    let path = format!("{}/index.html", WEB_ROOT);
    let content = tokio::fs::read_to_string(&path)
        .await
        .map_err(|e| format!("Could not read {}: {}", path, e))?;
    Ok(Html(content))
}

/// Example API route — returns a simple JSON health check.
/// Swap this out for axum::Json<T> responses in your real API.
async fn health_handler() -> &'static str {
    r#"{"status":"ok","server":"axum"}"#
}

async fn telnyx_webhook_handler() -> StatusCode {
    tracing::info!("Telnyx webhook received");
    StatusCode::OK
}

async fn telnyx_fail_handler() -> StatusCode {
    tracing::info!("Telnyx fail webhook received");
    StatusCode::OK
}
