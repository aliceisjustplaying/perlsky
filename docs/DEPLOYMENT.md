# Deployment

This document describes a generic single-node `perlsky` deployment behind a reverse proxy with TLS.

## Requirements

- A public host name for the PDS, for example `pds.example.com`
- DNS for that host name pointing at your server
- Perl 5.34+ on the server
- SQLite and filesystem storage
- A reverse proxy that can terminate TLS and proxy to a localhost HTTP listener
- Optional but recommended: a process supervisor such as `systemd`

## Layout

A simple layout that works well in production is:

- app checkout: `/opt/perlsky/app`
- local Perl dependencies: `/opt/perlsky/local`
- launcher: `/opt/perlsky/bin/run`
- config: `/etc/perlsky/perlsky.json`
- mutable data: `/var/lib/perlsky`

## Install

Clone the repo onto the server:

```sh
git clone https://github.com/aliceisjustplaying/perlsky.git /opt/perlsky/app
```

Install the runtime dependencies that are easiest to obtain from the OS:

```sh
apt-get update
apt-get install -y cpanminus libcbor-xs-perl libcryptx-perl libdbd-sqlite3-perl libio-socket-ssl-perl jq
```

Install Mojolicious into an app-local library so the deployed runtime matches the repo expectation:

```sh
cd /opt/perlsky/app
cpanm --notest --local-lib-contained /opt/perlsky/local Mojolicious@9.42
```

`IO::Socket::SSL` is required for `did:plc` account creation and crawler calls to `https://` endpoints.

## Config

Create `/etc/perlsky/perlsky.json`:

```json
{
  "host": "127.0.0.1",
  "port": 7755,
  "base_url": "https://pds.example.com",
  "hostname": "pds.example.com",
  "service_did_method": "did:web",
  "service_handle_domain": "example.com",
  "invite_code_required": false,
  "account_did_method": "did:plc",
  "plc_rotation_private_key_hex": "REPLACE_WITH_64_HEX_CHARS",
  "jwt_secret": "REPLACE_WITH_A_RANDOM_SECRET",
  "admin_password": "REPLACE_WITH_A_RANDOM_SECRET",
  "metrics_token": "REPLACE_WITH_A_RANDOM_SECRET",
  "sentry_dsn": "https://PUBLIC_KEY@o0.ingest.sentry.io/0",
  "bsky_appview_url": "https://api.bsky.app",
  "bsky_appview_did": "did:web:api.bsky.app",
  "chat_service_url": "https://api.bsky.chat",
  "chat_service_did": "did:web:api.bsky.chat",
  "crawlers": ["https://bsky.network"],
  "crawler_notify_interval": 1200,
  "data_dir": "/var/lib/perlsky/data",
  "db_path": "/var/lib/perlsky/perlsky.sqlite"
}
```

Important fields:

- `base_url`: the public HTTPS origin for the PDS
- `hostname`: the host relays should crawl
- `service_handle_domain`: the suffix used for local handles
- `jwt_secret`: required; the server now refuses to start if it is missing or still set to the old `perlsky-dev-secret` fallback
- `sentry_dsn`: optional; when set, perlsky reports unhandled XRPC exceptions to Sentry with request context and Perl stack frames
- If you want users like `alice.pds.example.com`, set `service_handle_domain` to `pds.example.com`, not `example.com`.
- Public handle resolution for `alice.pds.example.com` also requires wildcard DNS for `*.pds.example.com` and a reverse proxy/TLS setup that will answer those subdomains.
- `invite_code_required`: if true, `createAccount` requires a valid invite code
- `account_did_method`: set to `did:plc` if you want PLC-backed user DIDs
- `plc_rotation_private_key_hex`: required for `did:plc` account creation
- `bsky_appview_*` / `chat_service_*`: upstream AppView and chat services for unknown `app.bsky.*` and `chat.bsky.*` calls. The public Bluesky services are the normal defaults.
- `crawlers`: relay/crawler origins to notify after repo activity

## Launcher

Create a small launcher script such as `/opt/perlsky/bin/run`:

```sh
#!/bin/sh
set -eu

ARCHNAME=$(/usr/bin/perl -MConfig -e 'print $Config{archname}')
export PATH=/opt/perlsky/local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PERL5LIB=/opt/perlsky/local/lib/perl5:/opt/perlsky/local/lib/perl5/$ARCHNAME
export PERLSKY_CONFIG=/etc/perlsky/perlsky.json

exec /usr/bin/perl /opt/perlsky/app/script/perlsky daemon -l http://127.0.0.1:7755
```

Mark it executable:

```sh
chmod 755 /opt/perlsky/bin/run
```

## systemd

An example unit:

```ini
[Unit]
Description=perlsky ATProto PDS
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=MOJO_MODE=production
User=perlsky
Group=perlsky
WorkingDirectory=/opt/perlsky/app
ExecStart=/opt/perlsky/bin/run
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/var/lib/perlsky

[Install]
WantedBy=multi-user.target
```

Then:

```sh
systemctl daemon-reload
systemctl enable --now perlsky
```

`MOJO_MODE=production` is recommended so unexpected exceptions return ordinary HTTP 500 responses instead of Mojolicious development debug pages.

## Reverse Proxy

Expose `perlsky` through a TLS-capable reverse proxy to `127.0.0.1:7755`.

If `service_handle_domain` is a subdomain suffix such as `pds.example.com`, your proxy must answer both:

- `pds.example.com`
- `*.pds.example.com`

That is what allows external PDSes to resolve `https://alice.pds.example.com/.well-known/atproto-did`.

A minimal Caddy site looks like:

```caddy
pds.example.com {
  encode gzip
  reverse_proxy 127.0.0.1:7755
}
```

For public user handles you also need a matching wildcard-capable site or on-demand TLS path for `*.pds.example.com`.

One practical Caddy pattern is on-demand TLS restricted to domains that `perlsky` approves:

```caddy
{
  on_demand_tls {
    ask http://127.0.0.1:7755/_allow-cert
  }
}

pds.example.com {
  encode gzip
  reverse_proxy 127.0.0.1:7755
}

https:// {
  tls {
    on_demand
  }

  @perlsky_handles host *.pds.example.com
  handle @perlsky_handles {
    encode gzip
    reverse_proxy 127.0.0.1:7755
  }
}
```

This still requires wildcard DNS or per-handle DNS records so public ACME validation can reach the server.

A minimal nginx site looks like:

```nginx
server {
  server_name pds.example.com;
  listen 443 ssl http2;

  ssl_certificate /path/to/fullchain.pem;
  ssl_certificate_key /path/to/privkey.pem;

  location / {
    proxy_pass http://127.0.0.1:7755;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  }
}
```

## Validation

Check the local service first:

```sh
curl http://127.0.0.1:7755/_health
curl http://127.0.0.1:7755/.well-known/did.json
```

Then validate the public host:

```sh
curl https://pds.example.com/_health
curl https://pds.example.com/.well-known/did.json
curl https://pds.example.com/xrpc/com.atproto.server.describeServer
curl --resolve alice.pds.example.com:443:SERVER_IP https://alice.pds.example.com/.well-known/atproto-did
```

For browser-hosted clients such as `https://bsky.app`, `perlsky` also answers CORS preflight requests on XRPC routes. A quick manual probe looks like:

```sh
curl -i -X OPTIONS https://pds.example.com/xrpc/com.atproto.server.describeServer \
  -H 'Origin: https://bsky.app' \
  -H 'Access-Control-Request-Method: GET'
```

You should see:

- a healthy `_health` response
- a `did:web:pds.example.com` DID document
- `describeServer.availableUserDomains` matching `service_handle_domain`
- a per-handle `/.well-known/atproto-did` response returning the account DID when queried on the handle host

## First Account

You can create the first account directly with XRPC:

```sh
curl -X POST https://pds.example.com/xrpc/com.atproto.server.createAccount \
  -H 'Content-Type: application/json' \
  -d '{
    "handle": "alice",
    "email": "alice@example.com",
    "password": "correct horse battery staple"
  }'
```

If `service_handle_domain` is `example.com`, the short handle `alice` is normalized to `alice.example.com`.

The response contains:

- `did`
- `handle`
- `accessJwt`
- `refreshJwt`

Passwords must be at least 8 characters long.

If you want to disable open signup, enable `invite_code_required` and mint invite codes locally on the server:

```sh
PERLSKY_CONFIG=/etc/perlsky/perlsky.json \
  /opt/perlsky/app/script/perlsky-admin create-invite
```

That command prints a single invite code such as `perlsky-0123456789ab`.

You can then pass that value as `inviteCode` in the `createAccount` request:

```sh
curl -X POST https://pds.example.com/xrpc/com.atproto.server.createAccount \
  -H 'Content-Type: application/json' \
  -d '{
    "handle": "alice",
    "email": "alice@example.com",
    "password": "correct horse battery staple",
    "inviteCode": "perlsky-0123456789ab"
  }'
```

If `service_handle_domain` is `pds.example.com`, the short handle `alice` becomes `alice.pds.example.com`.

For a fully local bootstrap flow on the server, you can save the invite code into a shell variable first:

```sh
INVITE_CODE=$(
  PERLSKY_CONFIG=/etc/perlsky/perlsky.json \
    /opt/perlsky/app/script/perlsky-admin create-invite
)
printf 'Invite code: %s\n' "$INVITE_CODE"
```

## Metrics

If `metrics_token` is set, scrape metrics with:

```sh
curl -H 'Authorization: Bearer YOUR_METRICS_TOKEN' \
  https://pds.example.com/metrics
```

Checked-in Prometheus and Grafana examples live under:

- [ops/prometheus/perlsky.yml](../ops/prometheus/perlsky.yml)
- [ops/grafana/prometheus-datasource.yml](../ops/grafana/prometheus-datasource.yml)
- [ops/grafana/perlsky-dashboard-provider.yml](../ops/grafana/perlsky-dashboard-provider.yml)
- [ops/grafana/perlsky-dashboard.json](../ops/grafana/perlsky-dashboard.json)

See [METRICS.md](./METRICS.md) for the metric surface and dashboard notes.

## Sentry

If you want exception reporting in addition to Prometheus metrics, add `sentry_dsn` to `/etc/perlsky/perlsky.json`.

The current integration is intentionally narrow:

- it reports unhandled XRPC exceptions
- the Sentry event includes request metadata and Perl stack frames
- it does not report ordinary handled XRPC errors like `InvalidToken`
- it is a no-op when `sentry_dsn` is unset

## Prometheus

Merge [ops/prometheus/perlsky.yml](../ops/prometheus/perlsky.yml) into your Prometheus config and replace the placeholder bearer token with `metrics_token` from `/etc/perlsky/perlsky.json`.

One minimal local scrape job looks like:

```yaml
- job_name: perlsky
  scrape_interval: 15s
  scrape_timeout: 5s
  metrics_path: /metrics
  scheme: http
  authorization:
    credentials: REPLACE_WITH_PERLSKY_METRICS_TOKEN
  static_configs:
    - targets: ['127.0.0.1:7755']
      labels:
        service: perlsky
```

Validate and reload:

```sh
promtool check config /etc/prometheus/prometheus.yml
systemctl reload prometheus || systemctl restart prometheus
curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22perlsky%22%7D'
```

## Grafana

Provision the Prometheus data source and dashboard provider with the checked-in examples, then copy the dashboard JSON into the watched directory:

```sh
install -d /etc/grafana/provisioning/datasources
install -d /etc/grafana/provisioning/dashboards
install -d /var/lib/grafana/dashboards
cp /opt/perlsky/app/ops/grafana/prometheus-datasource.yml /etc/grafana/provisioning/datasources/perlsky-prometheus.yml
cp /opt/perlsky/app/ops/grafana/perlsky-dashboard-provider.yml /etc/grafana/provisioning/dashboards/perlsky.yml
cp /opt/perlsky/app/ops/grafana/perlsky-dashboard.json /var/lib/grafana/dashboards/perlsky-overview.json
systemctl restart grafana-server || systemctl restart grafana
```

The example data source uses the stable UID `prometheus`. Keep that UID or update the dashboard file to match your local Prometheus data source UID.

## Upgrades

To update a deployed instance:

```sh
git -C /opt/perlsky/app fetch origin
git -C /opt/perlsky/app reset --hard origin/main
cd /opt/perlsky/app
cpanm --notest --local-lib-contained /opt/perlsky/local Mojolicious@9.42
systemctl restart perlsky
```

## Useful Commands

```sh
systemctl status perlsky --no-pager
journalctl -u perlsky -f
curl http://127.0.0.1:7755/_health
curl http://127.0.0.1:7755/xrpc/com.atproto.server.describeServer
```
