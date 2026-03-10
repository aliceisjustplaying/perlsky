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
apt-get install -y cpanminus libcbor-xs-perl libcryptx-perl libdbd-sqlite3-perl jq
```

Install Mojolicious into an app-local library so the deployed runtime matches the repo expectation:

```sh
cd /opt/perlsky/app
cpanm --notest --local-lib-contained /opt/perlsky/local Mojolicious@9.42
```

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
- If you want users like `alice.pds.example.com`, set `service_handle_domain` to `pds.example.com`, not `example.com`.
- `invite_code_required`: if true, `createAccount` requires a valid invite code
- `account_did_method`: set to `did:plc` if you want PLC-backed user DIDs
- `plc_rotation_private_key_hex`: required for `did:plc` account creation
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

## Reverse Proxy

Expose `perlsky` through a TLS-capable reverse proxy to `127.0.0.1:7755`.

A minimal Caddy site looks like:

```caddy
pds.example.com {
  encode gzip
  reverse_proxy 127.0.0.1:7755
}
```

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
```

You should see:

- a healthy `_health` response
- a `did:web:pds.example.com` DID document
- `describeServer.availableUserDomains` matching `service_handle_domain`

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

You can then pass that value as `inviteCode` in the `createAccount` request.

## Metrics

If `metrics_token` is set, scrape metrics with:

```sh
curl -H 'Authorization: Bearer YOUR_METRICS_TOKEN' \
  https://pds.example.com/metrics
```

See `docs/METRICS.md` for the metric surface.

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
