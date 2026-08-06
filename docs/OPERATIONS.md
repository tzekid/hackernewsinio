# Operations

The current `hn.plosca.ru` deployment uses the user-service variant in
`deploy/hn-continuity-user.service`, listens only on `127.0.0.1:9333`, and is
published through Cloudio's owned Caddy fragment. Its immutable binary release
is selected by `%h/.local/opt/hn-continuity/current`; durable data lives under
`%h/.local/share/hn-continuity`.

## Current production deployment

The first production deployment was accepted on 2026-08-06:

- public origin: `https://hn.plosca.ru`;
- service: `hn-continuity.service`, enabled in the user's `default.target`;
- selected release: `%h/.local/opt/hn-continuity/releases/20260806-02`;
- database: `%h/.local/share/hn-continuity/continuity.db`;
- verified pre-upgrade backup:
  `%h/.local/share/hn-continuity/backups/continuity-20260806-pre-02.db`;
- proxy: Cloudio-owned `hn.plosca.ru -> 127.0.0.1:9333` Caddy route;
- TLS: automatically managed by Caddy with a publicly trusted certificate.

Public acceptance covered repeated and concurrent readiness requests, News,
History, registration, exact production WebAuthn RP/origin options, wrong-origin
rejection, authenticated-route redirection, security headers, a real HN thread,
process restart, cursor advancement, and exact release-binary checksums.

## Runtime shape

HN Continuity runs as one loopback-only Zig process with one local embedded
Turso database and embedded browser assets. Caddy terminates TLS. The service
does not require Node, Redis, a message broker, or an HN credential.

The process owns both HTTP and source synchronization. It polls the durable HN
item cursor every 30 seconds, captures ranked feeds every five minutes, retries
recorded gaps, and reconciles known changed items from `/updates`. Firebase SSE
parsing is implemented and replay-tested, but polling remains the correctness
path and the deployed upstream transport in v1.

## First install

1. Install the ReleaseSafe binary at
   `/opt/hn-continuity/bin/hn-continuity`.
2. Create the `hn-continuity` system user and `/var/lib/hn-continuity`, owned by
   that user with mode `0700`.
3. Initialize the database while the service is stopped:

   ```sh
   sudo -u hn-continuity /opt/hn-continuity/bin/hn-continuity init /var/lib/hn-continuity/continuity.db
   ```

4. Install `deploy/hn-continuity.env.example` as
   `/etc/hn-continuity.env`, mode `0600`, and set the canonical HTTPS origin.
5. Install the systemd and Caddy examples, then enable the service.

The binary refuses non-loopback binds. `--origin`, `--rp-id`, and `--secure`
must describe the public HTTPS endpoint or passkey ceremonies will correctly
fail origin validation.

## Upgrade

Stop the service, make an exclusive verified backup, install the new binary,
run migrations, inspect status, and start it again:

```sh
sudo systemctl stop hn-continuity
sudo -u hn-continuity /opt/hn-continuity/bin/hn-continuity backup /var/lib/hn-continuity/continuity.db /var/lib/hn-continuity/backups/pre-upgrade.db
sudo -u hn-continuity /opt/hn-continuity/bin/hn-continuity migrate /var/lib/hn-continuity/continuity.db
sudo -u hn-continuity /opt/hn-continuity/bin/hn-continuity status /var/lib/hn-continuity/continuity.db
sudo systemctl start hn-continuity
```

Backup destinations are create-only. Both the source and resulting copy pass
schema and integrity checks. Never copy the database while the service is
running and never run two HN Continuity writers against the same local file.

## Restore rehearsal

Restore always creates a new destination. Rehearse away from production:

```sh
hn-continuity restore backups/pre-upgrade.db restore-check.db
hn-continuity status restore-check.db
```

For production rollback, stop the service, restore to a new path, atomically
select that verified file as the service database, and start. Preserve the old
file until the rollback is accepted.

## Health and diagnosis

- `/healthz` proves the HTTP process is alive.
- `/readyz` proves the local schema is current.
- `hn-continuity status DATABASE` checks schema and database integrity and
  reports item, event, notification, and cursor counts.
- Temporary item failures remain visible in `ingest_gaps`; the contiguous
  cursor advances only across explicitly covered IDs.
- Feed history begins at the first successful local capture. Missing intervals
  are not invented.

Private Atom bearer tokens appear in request paths. The supplied Caddyfile does
not enable access logging; if logging is added, redact `/feeds/*` paths. The
current Caddy runtime explicitly lists `hn.plosca.ru` among its skipped access-
log hosts.
