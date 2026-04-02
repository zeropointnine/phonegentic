#!/usr/bin/env bash
# =============================================================================
# bootstrap_rust_server.sh
# Generates a complete Rust/Axum static file server project.
# Run this script once — it installs Rust, scaffolds the app, and builds it.
# =============================================================================
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
PROJECT_NAME="static_server"
PROJECT_DIR="$(pwd)/$PROJECT_NAME"
WEB_ROOT="/var/html"
SERVER_PORT="3000"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}▶ $*${RESET}"; }
success() { echo -e "${GREEN}✔ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }
die()     { echo -e "${RED}✖ $*${RESET}" >&2; exit 1; }

# ── 1. Install Rust (rustup) ──────────────────────────────────────────────────
install_rust() {
  if command -v rustc &>/dev/null; then
    success "Rust already installed: $(rustc --version)"
  else
    info "Installing Rust via rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain stable
    # Source cargo env for the rest of this script
    # shellcheck source=/dev/null
    source "$HOME/.cargo/env"
    success "Rust installed: $(rustc --version)"
  fi

  # Ensure cargo is on PATH for this session
  export PATH="$HOME/.cargo/bin:$PATH"
}

# ── 2. Create /var/html with sample content ───────────────────────────────────
create_web_root() {
  info "Creating web root at $WEB_ROOT..."

  if [ ! -d "$WEB_ROOT" ]; then
    sudo mkdir -p "$WEB_ROOT/images"
    sudo chown -R "$(whoami)" "$WEB_ROOT"
    success "Created $WEB_ROOT"
  else
    warn "$WEB_ROOT already exists — skipping mkdir"
  fi

  # Sample index.html (only if missing)
  if [ ! -f "$WEB_ROOT/index.html" ]; then
    cat > "$WEB_ROOT/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Axum Static Server</title>
  <style>
    body { font-family: sans-serif; max-width: 800px; margin: 4rem auto; padding: 0 1rem; }
    h1   { color: #e05d2a; }
    img  { max-width: 300px; display: block; margin: 1rem 0; border-radius: 8px; }
  </style>
</head>
<body>
  <h1>🦀 Axum Static Server</h1>
  <p>Serving files from <code>/var/html</code></p>
  <p>Drop images into <code>/var/html/images/</code> and link them like:</p>
  <pre>&lt;img src="/images/photo.jpg"&gt;</pre>
</body>
</html>
HTML
    success "Created sample $WEB_ROOT/index.html"
  fi
}

# ── 3. Scaffold Rust project ──────────────────────────────────────────────────
scaffold_project() {
  info "Scaffolding Rust project at $PROJECT_DIR..."

  if [ -d "$PROJECT_DIR" ]; then
    warn "Directory $PROJECT_DIR already exists — skipping cargo new"
  else
    cargo new "$PROJECT_NAME"
  fi

  # ── Cargo.toml ──────────────────────────────────────────────────────────────
  cat > "$PROJECT_DIR/Cargo.toml" <<TOML
[package]
name        = "$PROJECT_NAME"
version     = "0.1.0"
edition     = "2021"

[dependencies]
axum        = { version = "0.7", features = ["macros"] }
tokio       = { version = "1",   features = ["full"] }
tower-http  = { version = "0.5", features = ["fs", "trace"] }
tracing     = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
TOML
  success "Wrote Cargo.toml"

  # ── src/main.rs ─────────────────────────────────────────────────────────────
  cat > "$PROJECT_DIR/src/main.rs" <<'RUST'
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
        // ── API routes (add your REST endpoints here) ─────────────────────
        .route("/api/health", get(health_handler))
        // ── Static file serving ───────────────────────────────────────────
        // Serve everything under /static/* from WEB_ROOT
        .nest_service("/static", ServeDir::new(WEB_ROOT))
        // Serve /images/* directly
        .nest_service(
            "/images",
            ServeDir::new(format!("{}/images", WEB_ROOT)),
        )
        // Serve index.html at root
        .route("/", get(index_handler))
        // ── Middleware ────────────────────────────────────────────────────
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
RUST
  success "Wrote src/main.rs"
}

# ── 4. Build ──────────────────────────────────────────────────────────────────
build_project() {
  info "Building project (release)... this may take a minute on first run."
  (cd "$PROJECT_DIR" && cargo build --release)
  success "Build complete: $PROJECT_DIR/target/release/$PROJECT_NAME"
}

# ── 5. Print run instructions ─────────────────────────────────────────────────
print_summary() {
  echo ""
  echo -e "${BOLD}═══════════════════════════════════════════${RESET}"
  echo -e "${GREEN}${BOLD}  ✔ Setup complete!${RESET}"
  echo -e "${BOLD}═══════════════════════════════════════════${RESET}"
  echo ""
  echo -e "  ${BOLD}Run the server:${RESET}"
  echo -e "    cd $PROJECT_DIR"
  echo -e "    ./target/release/$PROJECT_NAME"
  echo ""
  echo -e "  ${BOLD}Or with debug logging:${RESET}"
  echo -e "    RUST_LOG=debug ./target/release/$PROJECT_NAME"
  echo ""
  echo -e "  ${BOLD}URLs:${RESET}"
  echo -e "    http://localhost:$SERVER_PORT/           → index.html"
  echo -e "    http://localhost:$SERVER_PORT/images/    → /var/html/images/"
  echo -e "    http://localhost:$SERVER_PORT/static/    → /var/html/ (all files)"
  echo -e "    http://localhost:$SERVER_PORT/api/health → health check"
  echo ""
  echo -e "  ${BOLD}Add API routes:${RESET}  edit ${CYAN}src/main.rs${RESET} → ${CYAN}router()${RESET} function"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║   Rust / Axum Static Server Bootstrap    ║${RESET}"
  echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
  echo ""

  install_rust
  create_web_root
  scaffold_project
  build_project
  print_summary
}

main "$@"