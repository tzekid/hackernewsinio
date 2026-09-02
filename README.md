# HN Continuity

A server-rendered Hacker News client that remembers where you were and tells
you exactly what changed since you left.

HN Continuity makes three kinds of hidden state explicit:

- **News ledger:** when a story was first observed in ranked HN feeds, its
  exact captured ranks, score, comments, and milestones.
- **Conversation ledger:** deterministic direct replies and activity beneath
  watched stories or individual comment branches, with causal reasons.
- **Attention ledger:** feed, thread, inbox, and watch boundaries already seen
  by each application user.

The implemented interface follows the accepted iPhone-first design: compact
white lists, near-black text, restrained orange-red emphasis, native links and
forms, and persistent News, Inbox, Following, and Settings navigation. Public
News, History, and Thread views work without JavaScript. HTMX 4 live count
fragments, passkey ceremonies, and keyboard navigation are enhancements.

## What is implemented

- exact `top`, `ask`, `show`, and `job` feed captures with first appearance,
  best rank, top-20/top-10 milestones, chronological News, capture History, and
  server-rendered SVG story trajectories;
- contiguous `/maxitem` cursor ingestion, durable retry gaps, deterministic
  item normalization, cached parent/root resolution, `/updates`
  reconciliation, and idempotent replay;
- exact direct replies, comments on tracked submissions, story watches,
  direct-child watches, branch-descendant watches, overlapping reason
  provenance, self-event suppression, and bounded onboarding backfill;
- contextual Inbox, explicit read/unread/dismiss boundaries, Following
  markers, independent branch/story controls, recursive collapsible thread
  branches, thread snapshot markers, and new-comment highlighting;
- passkey application accounts with strict RP/origin, presence/verification,
  challenge expiry/single use, counter and backup-state handling, CSRF, and
  hardened sessions;
- revocable hashed private Atom feeds, authenticated live count invalidation,
  data export/deletion, strict upstream HTML sanitization, CSP and related
  response headers;
- one Zig binary, one embedded Turso database in WAL mode, embedded assets,
  loopback-only HTTP, systemd/Caddy examples, verified backup/restore, and a
  real-process end-to-end replay/restart test.

Posting, voting, and HN account actions remain native Hacker News links. The
service never accepts an HN password. Tracked HN usernames are public watches,
not proof of ownership.

## Stack

- Zig `0.17.0-dev.1963+e00c6c439`, checksummed in `.zig-sha256`;
- `web.zig` at commit `bed5729051202c397d10b6ee8f1310701bca8efd`;
- `turso.zig` at commit `f1b82da9f9207bee085808ad6a8686a9780ed76d`,
  built locally without cloud sync;
- HTMX `4.0.0-beta6`, including its `hx-sse` extension, embedded from the
  pinned package rather than a CDN;
- Passcay `3.1.0` and zbor `0.21.2` for WebAuthn verification;
- the official public Hacker News Firebase API.

There is no Node runtime, client state store, Redis, message broker, cloud
database, JSON frontend API, or microservice split.

## Build and test

The source build requires the pinned Zig toolchain plus Cargo for the embedded
Turso native library:

```sh
zig build -Doptimize=Debug
zig build test -Doptimize=Debug
zig build e2e -Doptimize=Debug
zig build -Doptimize=ReleaseSafe
```

The end-to-end test starts a captured HN fixture source and the real HTTP
binary, synchronizes feeds, tracks an identity, creates a branch watch, stops
and restarts at a database boundary, replays new activity, checks Inbox,
Following, Thread, History, live invalidation, Atom, security headers, and
verified backup/restore.

## Run locally

```sh
zig-out/bin/hn-continuity init var/continuity.db
zig-out/bin/hn-continuity sync var/continuity.db
zig-out/bin/hn-continuity serve var/continuity.db --listen 127.0.0.1:8080
```

Open `http://127.0.0.1:8080/news`. The server runs continuing 30-second item
polling and five-minute feed capture/reconciliation after startup. The first
sync establishes the current item cursor; it does not pretend to have observed
historical front pages before the service existed.

Useful operational commands:

```sh
hn-continuity status var/continuity.db
hn-continuity backup var/continuity.db backups/continuity.db
hn-continuity restore backups/continuity.db restore-check.db
hn-continuity replay var/continuity.db tests/fixtures/replay.ndjson
```

Only use `dev-session` for local fixture work. Public deployments should use
passkeys and an HTTPS `--origin`, matching `--rp-id`, and `--secure` behind the
provided Caddy configuration.

## Documentation

- [`docs/SPEC.md`](docs/SPEC.md) — normative product behavior and route
  contract.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — ingestion, matching, HTTP,
  authentication, delivery, and operational design.
- [`docs/DATA_MODEL.md`](docs/DATA_MODEL.md) — durable tables, uniqueness,
  ownership, transaction boundaries, and retention.
- [`docs/DESIGN.md`](docs/DESIGN.md) — accepted mobile-first interface system.
- [`docs/DECISIONS.md`](docs/DECISIONS.md) — consequential decisions and
  deliberately deferred scope.
- [`docs/OPERATIONS.md`](docs/OPERATIONS.md) — installation, upgrades,
  backup/restore, health, and diagnostics.
- [`docs/IMPLEMENTATION.md`](docs/IMPLEMENTATION.md) — implemented surface,
  verification evidence, measurements, and explicit runtime boundaries.
- [`docs/MILESTONES.md`](docs/MILESTONES.md) — original staged build criteria.
- [`docs/STACK-RESEARCH.md`](docs/STACK-RESEARCH.md) — adjacent-project and
  upstream research behind the adopted stack.
- [`docs/source/chatgpt-pro-continuity-discussion.md`](docs/source/chatgpt-pro-continuity-discussion.md)
  — preserved source discussion; normative decisions live in the documents
  above.

The canonical visual reference is
[`docs/design/style-guides/mobile-v1-overview.png`](docs/design/style-guides/mobile-v1-overview.png).
The other style boards are rejected explorations retained as process evidence.

## Deployment

The release shape is intentionally small:

```text
one ReleaseSafe Zig binary
one embedded Turso database
one asset-free runtime directory
one systemd service behind Caddy
```

See [`docs/OPERATIONS.md`](docs/OPERATIONS.md) and [`deploy/`](deploy/). Keep a
single writer for a database file; stop the service for backup, restore, or
offline replay commands.
