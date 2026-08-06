# Decision register

Status: proposed

Consequential dependencies, protocols, durable schemas, security boundaries,
and product semantics belong here. Reversible local implementation details do
not need an ADR.

## Summary

| ID | Decision | Choice |
| --- | --- | --- |
| D01 | Product boundary | Continuity client, not generic HN clone or notification widget |
| D02 | Runtime topology | One Zig service with joinable background tasks |
| D03 | Durable store | Local embedded Turso through `turso.zig`; no cloud sync |
| D04 | Web architecture | Complete SSR and native forms; optional HTMX 4 enhancement |
| D05 | Upstream detection | Hybrid global cursor, bounded onboarding backfill, and reconciliation |
| D06 | Feed history semantics | Interval-based first observation, never reconstructed certainty |
| D07 | Application identity | Passkey account separate from public HN identities |
| D08 | Notification projection | One user-visible record with one or more causal reasons |
| D09 | Thread ordering | Stable chronological sibling order in v1 |
| D10 | HN content | Strict sanitizer output is the only trusted rendering form |
| D11 | Live browser updates | Durable DB state plus optional app SSE invalidation |
| D12 | First external delivery | Private Atom feed; Web Push/email deferred |
| D13 | Testing emphasis | Deterministic real-process replay and HTTP/browser journeys first |
| D14 | Deployment | Embedded assets, systemd, Caddy, verified offline backup/restore |
| D15 | Mobile interface | Canonical light, mobile-first list UI with four persistent destinations |

## D01. Product boundary

Build discovery, conversation, and reading continuity as one model. News,
Inbox, Following, Thread, History, and Settings all project the same event and
attention ledgers. Do not compete on voting, posting, article mirroring,
algorithmic recommendations, or a broad replacement for every HN route.

The working name is **HN Continuity**. It is descriptive and provisional. The
public UI must identify the project as unofficial and unaffiliated with Hacker
News or Y Combinator.

## D02. Runtime topology

Use one Zig executable for HTTP, upstream ingestion, feed capture,
reconciliation, app SSE, and maintenance commands. Tasks are modular but remain
one deployable process. Every long-lived task is cancelable and joined during
shutdown; no detached worker is allowed to own unflushed state.

Revisit only after measured load or fault isolation demonstrates a process
boundary is necessary.

## D03. Durable store

Select local embedded Turso through the exact `turso.zig` package pin used by
the current house stack. Disable cloud/replica sync. Keep one process-scoped
`Database` and a small application-owned connection pool; materialize bounded
view models before releasing a connection.

Why this over stock SQLite:

- it dogfoods the maintained Zig binding already used by SparkDate and
  Analytico;
- typed parameter binding/decoding and explicit ownership already exist;
- it retains the desired one-process, one-local-file deployment shape.

Costs accepted:

- cold source builds require Cargo and substantial cache space;
- rows and values are borrowed and one connection has one active execution;
- stock `sqlite3` must never write concurrently to the live file;
- backup, migration, mixed-version access, sidecars, and rollback need the
  Turso-specific qualification already learned in adjacent projects.

There is no dual-driver abstraction and no SQLite fallback. If the M0
compatibility/fault spike fails a named acceptance gate, revisit the decision
before domain code is built.

## D04. Web architecture

Use `web.zig` modules where their existing contracts fit. The application owns
routes, sessions, authorization, view models, CSS, HTML components, SSE, and
HN-specific behavior.

Every page and ordinary mutation works through normal HTTP and complete HTML.
HTMX `4.0.0-beta6` is self-hosted and optional. If a route varies its response
for HTMX, it renders from the same view model and sends the required `Vary`
header. WebAuthn is the one required JavaScript boundary for account login.

## D05. Upstream detection

Use a hybrid model:

1. initialize a durable cursor at an observed `/maxitem` value;
2. ingest every later allocated ID in bounded batches;
3. backfill a new tracked identity from a visibly bounded portion of its
   `submitted` list;
4. reconcile recently changed/materialized objects through `/updates` and
   periodic direct refresh.

The per-user data spike exercises the same normalizer and matcher; it is not a
second permanent polling architecture.

## D06. Feed history semantics

Capture current ranked lists at a fixed interval. Call timestamps
`first_observed_at`, `last_observed_at`, and `captured_at`. The UI may say
"first seen on our front page ledger" but must not claim the precise entry time
between captures. Imported data, if ever added, is visibly labeled and never
merged into authoritative local observations.

## D07. Application identity

A typed HN username is a public watch, not proof of ownership and not HN login.
Create private application accounts with passkeys. Never receive an HN
password, HN session cookie, vote, or comment body.

Passkey-only avoids an email provider in v1. Users are prompted to register a
second passkey; last-passkey deletion is rejected. Formal recovery beyond
synced/secondary passkeys is deferred until a safe design is chosen.

Anonymous News continuity uses a bounded first-party marker cookie. Inbox,
watches, cross-device state, and per-thread markers require an application
account.

## D08. Notification projection

A source event may match several causes: a direct reply, branch watch, and story
watch can overlap. Create one visible notification per user and category, then
attach every causal reason. Never show duplicate cards for one HN comment.

Events and reasons remain after a source item is deleted. Rendering changes to
`[deleted]`; provenance does not disappear.

Self-authored activity is recorded in the event ledger but is suppressed from
the user's default Inbox/Following unread counts.

## D09. Thread ordering

Order sibling comments by `(created_at, id)` in v1. This is stable and makes
new-comment continuity comprehensible; it does not attempt to mirror HN's
volatile ranked `kids` order. Always provide a native-HN link for the canonical
HN presentation.

A later HN-order mode requires a demonstrated user need and separately stored
ordering observations.

## D10. HN content

Store source HTML separately from sanitizer output. Titles become plain text.
Comment/story text passes through a small strict HTML tokenizer/rewriter with a
documented tag and attribute allowlist. Unknown or malformed markup is treated
as text, never trusted HTML. URL schemes are parsed and restricted.

Only sanitizer-versioned output may cross the renderer's trusted-HTML boundary.
Pure escaping and sanitizer fixtures are security gates.

## D11. Live browser updates

The database is authoritative. After commit, an in-memory broadcaster may tell
connected authenticated pages that their Inbox/Following/thread counts are
stale. The browser receives a small server-rendered banner or counter and then
performs an ordinary GET. It never receives or mutates the full thread tree as
client state.

SSE failure may increase latency but cannot lose a notification. Initial load,
reload, and reconnect all derive state from the database.

## D12. First external delivery

Provide revocable, tokenized private Atom feeds after the durable Inbox and
Following projections work. Tokens are stored hashed and treated as
credentials. Atom needs no delivery queue and works without adding SMTP or a
push provider.

Web Push, email, and their outbox/attempt tables are deferred. Add them only
with a concrete delivery requirement and crash/retry contract.

## D13. Testing emphasis

The principal acceptance harness starts the real binary with an isolated real
database, replays deterministic HN/Firebase envelopes, makes real HTTP
requests, kills/restarts the process at named fault points, and inspects durable
results. Browser acceptance is narrow and reserved for behavior HTTP alone
cannot prove: JavaScript-disabled first views, passkeys, HTMX replacement, CSP,
and SSE reconnect.

Unit tests focus on pure parsing, escaping, matching, marker, and aggregation
rules. There is no generic mock framework, broad screenshot suite, or collection
of shallow smoke tests.

## D14. Deployment

Embed immutable CSS and JavaScript assets in the release binary. Run one
unprivileged systemd service on loopback behind Caddy. Ship health/readiness,
an operator status command, explicit migration commands, and a stopped-writer
verified backup/restore/rehearsal flow.

Readiness means the process can safely serve stored state; a temporary HN
outage is reported as stale data, not an automatic readiness failure.

## D15. Mobile interface

Accept `docs/design/style-guides/mobile-v1-overview.png` and `docs/DESIGN.md` as
the canonical first interface direction. Start with iPhone-class mobile web
viewports and one restrained light system: white surfaces, near-black text,
orange-red accent, system sans typography, compact divided rows, and native
links/forms.

The persistent mobile destinations are News, Inbox, Following, and Settings.
Thread is contextual. History remains a real route and appears as a mode inside
News on narrow screens.

The earlier generated style-guide boards are rejected explorations. Do not mix
their condensed poster typography, multiple palettes, dark-console treatment,
or oversized numerals into implementation. Desktop must later derive from the
same tokens and components. Dark mode requires a separate accepted design; it
is not inferred from the explorations.

Generated sample copy is not normative. `SPEC.md` remains authoritative for
identity language, Atom-over-email delivery, native-HN actions, read markers,
and event semantics.
