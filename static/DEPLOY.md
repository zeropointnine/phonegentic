# Deploying the Rust Static Server

The server is an Axum app that lives in `static_server/`. It runs on port **3000** behind nginx (which terminates TLS on 443 and proxies).

---

## Quick-reference one-liners

### 1 — SCP the source to the server

Static HTML files are served from `/var/html/` on the server.
The Rust server source lives at `/root/phonegentic/static/static_server/` on the server.

```bash
# Static HTML files
scp static/sms-opt-in.html root@phonegentic.ai:/var/html/

# Rust server source
scp -r static/static_server root@phonegentic.ai:/root/phonegentic/static/static_server
```

Or if you only changed `main.rs`:

```bash
scp static/static_server/src/main.rs root@phonegentic.ai:/root/phonegentic/static/static_server/src/main.rs
```

Tail server
```
ssh root@phonegentic.ai "journalctl -u static_server -f"
```


### 2 — SSH in, build release, and restart

> `cargo` isn't on `PATH` in non-interactive SSH sessions — always source the rustup env first.

```bash
ssh root@phonegentic.ai "source \$HOME/.cargo/env && cd /root/phonegentic/static/static_server && cargo build --release && systemctl restart static_server"
```

All three steps as a single copy-paste chain (scp + build + restart):

```bash
scp -r static/static_server root@phonegentic.ai:/root/phonegentic/static/static_server && \
  ssh root@phonegentic.ai "source \$HOME/.cargo/env && cd /root/phonegentic/static/static_server && cargo build --release && systemctl restart static_server"
```
```bash
cat > /etc/nginx/sites-enabled/phonegentic << 'EOF'
server {
    server_name phonegentic.ai www.phonegentic.ai;
    location /ws/ {
        proxy_pass         http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           $http_upgrade;
        proxy_set_header   Connection        "upgrade";
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_read_timeout 3600s;
    }
    location / {
        proxy_pass         http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }
    listen 443 ssl;
    ssl_certificate /etc/letsencrypt/live/phonegentic.ai/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/phonegentic.ai/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}
server {
    if ($host = www.phonegentic.ai) {
        return 301 https://$host$request_uri;
    }
    if ($host = phonegentic.ai) {
        return 301 https://$host$request_uri;
    }
    listen 80;
    server_name phonegentic.ai www.phonegentic.ai;
    return 404;
}
EOF
nginx -t && systemctl reload nginx
```
---

## nginx

Config lives at `/etc/nginx/sites-enabled/phonegentic`.  Key blocks:

```nginx
# HTTPS → Axum (port 3000)
server {
    listen 443 ssl;
    server_name phonegentic.ai;

    ssl_certificate     /etc/letsencrypt/live/phonegentic.ai/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/phonegentic.ai/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    # WebSocket upgrade for /ws/call_control
    location /ws/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 3600s;
    }
}
```

Reload nginx after any config change:

```bash
ssh root@phonegentic.ai "nginx -t && systemctl reload nginx"
```

---

## systemd service

If the service doesn't exist yet, create `/etc/systemd/system/static_server.service`:

```ini
[Unit]
Description=Phonegentic Axum static server
After=network.target

[Service]
ExecStart=/root/phonegentic/static/static_server/target/release/static_server
WorkingDirectory=/root/phonegentic/static/static_server
Restart=on-failure
Environment=RUST_LOG=info
Environment=WEB_ROOT=/var/html

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
ssh root@phonegentic.ai "systemctl daemon-reload && systemctl enable static_server && systemctl start static_server"
```

Check logs:

```bash
ssh root@phonegentic.ai "journalctl -u static_server -f"
```

---

## Environment variables

| Variable          | Default                        | Purpose                              |
|-------------------|--------------------------------|--------------------------------------|
| `WEB_ROOT`        | `/var/html`                    | Directory served as static files     |
| `RUST_LOG`        | `info`                         | Log verbosity (`debug`, `info`, …)   |
| `SENDGRID_API_KEY`| *(unset)*                      | Email delivery; falls back to sendmail |
| `NOTIFY_EMAIL`    | *(unset)*                      | Destination address for form alerts  |
| `SMS_LOG_FILE`    | `/var/log/sms_submissions.log` | Fallback log for SMS opt-in/out      |
| `HELP_LOG_FILE`   | `/var/log/help_submissions.log`| Fallback log for help form           |

---

## Endpoints

| Method | Path                    | Purpose                                              |
|--------|-------------------------|------------------------------------------------------|
| GET    | `/api/health`           | Health check → `{"status":"ok"}`                     |
| POST   | `/web_hooks/telnyx`     | Telnyx call-control events (B-leg discovery)         |
| POST   | `/web_hooks/telnyx_fail`| Telnyx failure webhook                               |
| GET    | `/ws/call_control`      | WebSocket relay — streams call events to Flutter app |
| GET    | `/ws/messaging`         | WebSocket relay — streams messaging events (message.received, etc.) |
| POST   | `/api/sms-opt-in`       | SMS opt-in form                                      |
| POST   | `/api/sms-opt-out`      | SMS opt-out form                                     |
| POST   | `/api/help`             | Help/contact form                                    |
| GET    | `/*`                    | Static files from `WEB_ROOT`                         |

---

## First-time bootstrap

If the server is brand new, run the bootstrap script from your local machine:

```bash
scp static/bootstrap_server.sh root@phonegentic.ai:~ && \
  ssh root@phonegentic.ai "bash ~/bootstrap_server.sh"
```

This installs Rust, creates `/var/html`, and builds the initial binary.
