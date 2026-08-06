# Stack and source research

Status: evidence snapshot for the proposed specification

Observed: 2026-08-04 UTC

This document records why the specification selects its stack. It is not a
claim that adjacent dirty working trees, public APIs, or prerelease packages
will remain unchanged. Implementation must lock and re-qualify every input.

## 1. Starting state

`/home/kid/Projects/hackernewsinio` was empty and was not a Git repository when
this specification began. There was no application code or existing local work
to preserve. The parent directory contained the relevant owned projects.

## 2. Adjacent project evidence

| Project | Inspected revision | Reusable pattern | Boundary for this project |
| --- | --- | --- | --- |
| `web.zig` | `bed5729051202c397d10b6ee8f1310701bca8efd` | Context-safe writer-first HTML, bounded request parsing, route matching, cache validators, explicit security headers, optional HTMX semantics, and a small `std.http` connection loop | It intentionally owns no auth, database, SSE, product components, or application state |
| `turso.zig` | `f1b82da9f9207bee085808ad6a8686a9780ed76d` | Local embedded database, typed parameters and decoding, explicit transactions, diagnostics, and visible ownership | Rows are borrowed; a connection permits one active execution; all connections must end before the database owner |
| SparkDate | `991c9d00348e04c4b373d239f4b7752d4e438dcf` | Exact Zig pin, local embedded Turso, complete SSR first views, native forms, bounded browser-only islands, deterministic fixture and HTTP parity testing | Its domain modules, large route inventory, release controller, and visual system are not copied |
| Cloudio | `5dfd3e3a6ba1f0e257de62b4446e3e1c7fd22940` | `web.zig` HTML, passkeys, session-bound CSRF, exact-Origin form checks, `303` POST/Redirect/GET, explicit assets and server-owned views | Its current stock-SQLite store and control-plane architecture are application-specific; the working tree also contained unrelated changes |
| plosca.ru | `f4b6f6fae60db976a7af18090142d83b129ed52d` | Exact Zig pin, self-hosted HTMX, embedded/generated first-response content, ETag/Last-Modified handling, precompressed assets, CSP, and a small `web.zig` server | It is a static generator/file server, not a durable multi-user application |
| Analytico | `8f7a68db376c95fff5ebddb9081e32e20928b5b6` | Consequential decision register, milestone exit criteria, local Turso ownership, Passcay/zbor passkeys, systemd+Caddy operations, release and rollback documentation | DuckDB and analytics-specific privacy/session semantics do not belong here |

These SHAs anchor the inspected HEADs; they are not cleanliness claims.
Cloudio and SparkDate had substantial existing working-tree changes, and
plosca.ru had untracked work. No sibling file was modified. Where current source
was inspected, this research treats it as working-tree evidence and does not
attribute every observed line to the named commit.

The current adjacent projects converge on Zig
`0.17.0-dev.1509+bb296ab9b`. That is the candidate compiler for the first
compatibility spike, not a floating-channel instruction.

### Candidate package inputs

These are candidates to reproduce in `build.zig.zon`; the implementation
milestone must calculate and commit the actual package hashes.

| Input | Candidate observed |
| --- | --- |
| Zig | `0.17.0-dev.1509+bb296ab9b` |
| `web.zig` | package `0.1.0-dev`, local revision `bed5729051202c397d10b6ee8f1310701bca8efd` |
| `turso.zig` | package `0.1.1`, revision `f1b82da9f9207bee085808ad6a8686a9780ed76d` |
| Turso native source behind that binding | commit `6e527a75595576790566f3d36560fbe95c5d87a2` |
| HTMX | `4.0.0-beta6`, self-hosted; Zig package hash candidate `N-V-__8AAAhgEwAkQvSpCBDH3yfm0iALwvlZfmscrzeb7Csg` |
| Passcay | `3.1.0` |
| zbor | `0.21.2` |

Cold source builds of the candidate Turso dependency require Rust/Cargo and are
materially heavier than the application build. Development and deployment must
also qualify a prebuilt `turso.zig` system-prefix mode, as SparkDate does.

## 3. House-style conclusions

The following are adopted because they are implemented across real neighboring
applications, not because they are generic preferences:

1. The first successful response contains all useful state already known to
   the server.
2. Renderers accept typed application view models and a writer; they do not
   query the database, inspect sessions, call HN, or mutate state.
3. Links and ordinary forms are the baseline. Mutations validate, commit, and
   use `303 See Other`; HTMX may enhance the same operation later.
4. JavaScript remains application-owned and is limited to browser-only APIs,
   keyboard convenience, and live-update enhancement.
5. Shared code is imported only where its existing contract fits. This project
   does not add HN, auth, database, or SSE concerns to `web.zig`.
6. Toolchains and browser assets are immutable inputs with checksums. There is
   no unversioned CDN or production package manager.
7. A production claim requires more than readiness: verify the sustained PID,
   executable, database, listener, health, public route, and real browser
   behavior after the launcher has exited.

## 4. Verified Hacker News contracts

The [official Hacker News API](https://github.com/HackerNews/API) documents the
following properties used by the design:

- items have stable integer IDs; comments expose `parent`; stories/comments
  expose `kids`; item text and titles may contain HTML;
- user IDs are case-sensitive and user records expose `submitted`;
- `/v0/maxitem` exposes the largest current item ID;
- `/v0/topstories`, `/newstories`, `/beststories`, `/askstories`,
  `/showstories`, and `/jobstories` expose current ranked lists;
- `/v0/updates` exposes a current list of changed items and profiles;
- the API is described as near real time and currently documents no rate
  limit.

On 2026-08-04, direct checks against the public API observed:

- `GET /v0/maxitem.json`: `200 application/json`;
- the same resource with `Accept: text/event-stream`: `200
  text/event-stream` followed by an initial `put` event;
- `/v0/topstories.json`: 500 IDs, of which the first 30 can be sampled as the
  configured first-page depth;
- `/v0/updates.json`: both `items` and `profiles` arrays.

Firebase's [REST streaming documentation](https://firebase.google.com/docs/database/rest/retrieve-data#section-rest-streaming)
requires `Accept: text/event-stream` and following HTTP `307` redirects. It
defines `put`, `patch`, `keep-alive`, `cancel`, and `auth_revoked` events. The
application uses upstream SSE for latency and an ordinary polling watchdog for
recovery.

Important limits of the source contract:

- `/updates` is not documented as a durable, replayable change log. It cannot
  prove that every edit/deletion during a long outage was observed.
- ranked-feed endpoints expose current state, not historical membership.
  History begins when this service captures it.
- an interval snapshot proves "first observed by this service", not the exact
  second a story reached the Hacker News homepage.
- HN returns HTML. It is never passed through as trusted application HTML.

## 5. Product-reference check

[hckr news](https://hckrnews.com/about.html) explicitly describes the same two
discovery problems: missing stories between visits and difficulty identifying
what is new during frequent visits. It presents stories chronologically after
they have appeared on the HN homepage and has experimented with new-comment
highlighting.

Reply alerts and new-comment indicators are already present in clients and
services such as [Hacki](https://github.com/Livinglist/Hacki),
[HN Replies](https://www.hnreplies.com/), and
[Hacker News RSS](https://hnrss.github.io/). The defensible product boundary is
therefore the joined continuity model and its inspectable provenance, not a
claim that reply notifications are novel.

The current [Hacker News guidelines](https://news.ycombinator.com/newsguidelines.html)
say not to post generated or AI-edited text. The product remains read-only with
respect to HN and provides no comment-generation or automated-posting feature.

## 6. HTMX status

HTMX 4 remains prerelease in the official v4 documentation observed on
2026-08-04. The proposed input is exactly `4.0.0-beta6`.

- Live browser delivery uses the v4
  [`hx-sse` extension](https://four.htmx.org/extensions/hx-sse) only after core
  product behavior works by reload.
- Conditional fragment polling uses ordinary HTTP `ETag`/
  `If-None-Match`. The documented
  [`hx-ptag` extension](https://four.htmx.org/extensions/hx-ptag) is not needed
  in v1.
- Core correctness never depends on HTMX, its SSE reconnect behavior, or DOM
  swaps.

This differs deliberately from the source discussion's shorthand: `hx-sse`
and `hx-ptag` are extensions, not capabilities to assume merely because the
core HTMX script is present.
