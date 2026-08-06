# Implementation status and evidence

This file records what the repository actually does. The source discussion and
milestone checklist preserve the broader product design; this is the evidence
ledger for the current `0.1.0-dev` implementation.

## Delivered product surface

All five required mobile views are server-rendered: News, Inbox, Following,
Thread, and Settings. History is the News secondary mode and includes exact
captures plus per-story rank/score/comment trajectories. Public views and all
authenticated state-changing forms retain complete native HTML behavior.

The news, conversation, and attention ledgers are represented by durable
tables and transactionally derived projections. Notifications retain their
source event and every matching identity/watch reason. Inbox entries render
the original parent, response, story, and an inspectable causal explanation;
the focused thread supplies bounded ancestor and descendant context.

The source adapter, cursor, gap retry, feed capture, reconciliation, backfill,
replay, sanitizer, passkey verification, sessions, watches, markers, Atom,
export/deletion, and deployment operations are implemented in the single
binary. Identity backfills are durable jobs and can be resumed after a process
restart.

Thread acquisition is also durable and restart-safe, but deliberately separate
from the HTTP path. Opening `/item/:id` queues a deduplicated bounded backfill
and immediately renders the stored snapshot. If nothing is stored yet, the
server returns an honest loading state with refresh and native-HN links. The
background worker checks for new work each second; slow Firebase item requests
cannot monopolize the HTTP listener.

Inbox dismissal is a local attention-ledger state: dismissed cards leave
unread/live/Atom projections but their source event and reasons remain in the
database and account export. Thread comments are rendered in deterministic
parent order as native collapsible branch trees, with focused local and native
HN links. External story/comment URLs are parsed and restricted to credential-
free HTTP(S) origins before they can become links.

## Verification gates

The following gates passed on 2026-08-06 with the pinned toolchain:

```text
zig build test -Doptimize=Debug
zig build e2e -Doptimize=Debug
zig build e2e -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseSafe
git diff --check
```

A separate live official-API run also passed on 2026-08-06: it negotiated the
current HTTPS endpoint, observed `/maxitem`, captured all four configured feeds,
and stored 105 unique real items with 232 deterministic feed/item events and no
cursor gaps. The run took 31.95 seconds at 25,300 KiB maximum resident set;
network time and 120 bounded item requests dominate that measurement.

The real-process end-to-end journey covers fixture acquisition, feed capture,
mobile SSR routes, exact-Origin rejection, WebAuthn registration options,
identity tracking and durable backfill, branch following, stop/replay/restart,
direct-reply context and reasons, read/unread/dismiss markers, focused and
collapsible threads,
authenticated live count state, private Atom, user-state export, response
security headers, and verified backup/restore.

The thread regression journey restarts against a fixture that delays the root
HN item by three seconds. The saved thread and a second readiness request must
both complete within two seconds and one second respectively while acquisition
continues in the background.

Production proxy qualification found and fixed one connection-lifecycle defect
before acceptance: the single-connection accept loop had allowed an upstream
keep-alive socket to wait for more requests, which let Caddy monopolize the
server. The server now ends each accepted connection after one response. Twenty
sequential and sixteen concurrent public readiness requests then passed through
Caddy, followed by successful News, History, and registration requests.

Unit/integration tests separately cover migration durability, strict HN item
parsing, sanitizer active-content rejection, Firebase SSE envelope parsing,
contiguous cursors and retry gaps, feed milestone idempotence, overlapping
identity/watch reasons, replay idempotence, and passkey policy.

## Measured local baseline

On the development host, the accepted ReleaseSafe statically linked binary is
31,581,464 bytes. An empty initialized database begins at 4,096 bytes before
normal WAL/checkpoint growth. A measured fresh initialization completed in
0.01 seconds at 20,624 KiB maximum resident set; an integrity-checked status
read completed below the timer's 0.01-second resolution at 16,216 KiB maximum
resident set. These are a local baseline, not universal performance claims.

## Explicit runtime boundaries

- Upstream correctness uses a 30-second `/maxitem` polling watchdog, durable
  gap retry, and five-minute `/updates` reconciliation. The Firebase SSE parser
  is implemented and tested, but a long-lived upstream SSE transport is not
  enabled in this single-threaded v1 server; polling is authoritative.
- Browser live state uses the pinned HTMX 4 `hx-sse` extension with a small,
  authenticated, reconnecting SSE snapshot every five seconds. Reload remains
  authoritative and no comment tree is pushed.
- Passkey cryptographic/policy code and HTTP option issuance are automated;
  a physical production authenticator and public TLS origin still require the
  deployment owner's acceptance test.
- Historical homepage claims begin with the first successful local capture.
  The application never reconstructs or labels earlier history as exact.
- HN posting, voting, editing, and password handling are deliberately absent
  and deep-link to native Hacker News.

These boundaries keep failure behavior honest without adding Redis, a broker,
another deployable service, or a client-side application state system.
