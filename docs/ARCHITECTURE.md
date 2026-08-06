# Architecture

Status: proposed

This document describes the smallest architecture that can satisfy
`SPEC.md`. It deliberately keeps one deployable service while preserving
testable module boundaries.

## 1. Runtime shape

```text
                         Hacker News Firebase API
                    maxitem SSE  item/user GET  feeds/updates
                           |          |             |
                           +----------+-------------+
                                      |
                           bounded HN source adapter
                                      |
                       +--------------+---------------+
                       |                              |
               item ingestion                  feed/reconcile jobs
                       |                              |
                       +--------------+---------------+
                                      |
                      normalize -> resolve graph -> match/reduce
                                      |
                         local embedded Turso database
                           |          |             |
                       SSR routes  durable state  Atom projections
                           |
                    optional app SSE invalidation
                           |
                   browser: complete HTML + HTMX enhancement
```

One executable owns:

- listener and bounded connection tasks;
- process-scoped database and connection pool;
- upstream SSE supervisor;
- polling/catch-up ingestion supervisor;
- ranked-feed capture scheduler;
- changed-item reconciliation scheduler;
- authenticated application SSE broadcaster;
- signal handling and coordinated shutdown.

No long-lived task is detached. Shutdown stops accepting work, cancels
upstream/live connections, waits for in-flight database transactions, joins all
tasks, closes every connection, and deinitializes the database last.

## 2. Proposed source layout

```text
build.zig
build.zig.zon
.zigversion
.zig-sha256
assets/
  app.css
  keyboard.js
  passkeys.js
deploy/
  Caddyfile
  hn-continuity.service
docs/
src/
  main.zig
  app.zig
  config.zig
  lifecycle.zig
  cli/
    root.zig
    replay.zig
    backup.zig
    status.zig
  hn/
    client.zig
    json.zig
    sse.zig
    types.zig
    sanitize.zig
  ingest/
    supervisor.zig
    batch.zig
    graph.zig
    matcher.zig
    feeds.zig
    reconcile.zig
    backfill.zig
  domain/
    events.zig
    notifications.zig
    attention.zig
    watches.zig
  store/
    database.zig
    pool.zig
    migrations.zig
    items.zig
    feeds.zig
    users.zig
    projections.zig
  web/
    routes.zig
    request.zig
    auth.zig
    handlers/
    views/
    assets.zig
    sse.zig
tests/
  fixtures/
  e2e/
```

This is an ownership map, not permission to create empty abstraction files.
M0/M1 should add a file only when its responsibility exists.

## 3. Process lifecycle

### 3.1 Startup order

1. Parse bounded CLI/configuration and validate mutually exclusive options.
2. Configure process logging before worker tasks start.
3. Open the database file once and acquire an application lock that rejects a
   second writer process.
4. Create the fixed connection pool, configure busy timeout/foreign keys, and
   run or validate ordered migrations.
5. Run a local readiness query and load durable cursors/configuration.
6. Bind the loopback HTTP listener.
7. Start the accept group and background supervisors.
8. Mark readiness true only after listener, schema, and supervisors are owned by
   the lifecycle group.

The service may serve stored data while HN is unavailable. It reports
freshness separately.

### 3.2 Shutdown order

1. On SIGTERM/SIGINT, flip the single stopping state.
2. Stop accepting HTTP and new scheduled jobs.
3. Close/cancel upstream HN SSE and application SSE streams.
4. Allow the current bounded fetch batch to finish or cancel before commit.
5. Finish current database transactions; do not begin another batch.
6. Join task groups and close pooled connections.
7. Checkpoint/close according to the pinned Turso contract.
8. Release the application lock and database owner.

Shutdown has a measured deadline. A forced systemd kill is treated as a crash
recovery case and covered by replay tests.

## 4. HN source adapter

All upstream access passes through one application-owned adapter. Domain and
rendering modules never construct Firebase URLs.

### 4.1 Supported operations

```text
getMaxItem()
streamMaxItem()
getItem(id)
getUser(exact_id)
getFeed(top | new | best | ask | show | job)
getUpdates()
```

The adapter returns typed normalized source values or a classified error. It
does not write the database or decide notification meaning.

### 4.2 HTTP contract

- HTTPS only; exact host `hacker-news.firebaseio.com` by default.
- Requests and redirects have fixed limits.
- Firebase `307` redirects are followed only to an allowed HTTPS Firebase host
  and never forward credentials (none are required for the public API).
- Connect, header, body, idle-SSE, and total request deadlines are separate.
- Response headers/body and JSON nesting/strings have explicit byte limits.
- Successful JSON content type and SSE content type are validated.
- Unknown JSON fields are ignored, as the official API recommends.
- Missing optional fields are normal; invalid required ID/type relationships
  are quarantined with diagnostics.
- The adapter applies bounded exponential backoff with jitter for retryable
  network/5xx/429 failures and never retries malformed permanent input in a
  tight loop.

The official API currently documents no rate limit, but this application still
uses bounded concurrency and identifies itself with a stable User-Agent and
project/operator contact URL.

### 4.3 Upstream SSE parser

`streamMaxItem` sends `Accept: text/event-stream` and handles:

- `put` and `patch` JSON envelopes;
- `keep-alive` events;
- comments/blank-line event boundaries;
- bounded `data:` accumulation;
- initial value and repeated/equal/decreasing values;
- connection close, read timeout, malformed event, redirect, and reconnect.

Only a larger valid max value schedules work. A lower/equal value is logged at
bounded frequency and ignored; it never moves the durable cursor backward.

## 5. Global item ingestion

### 5.1 Cursor terms

- `observed_max`: latest valid max ID seen by SSE or polling.
- `processed_through`: highest ID for which every ID at or below it is either
  stored or represented by an unresolved durable gap row.
- `materialized`: content body/title is stored, not merely graph metadata.

The cursor is not “last number observed.”

### 5.2 Initialization

On an empty database:

1. fetch max item `H0`;
2. transactionally insert the cursor with `observed_max = processed_through =
   H0`;
3. start live/watchdog ingestion from `H0 + 1`;
4. run identity/thread backfills independently.

The service does not ingest all historical HN IDs. This is visible in status
and in the beginning of authoritative global history.

Capturing `H0` before onboarding prevents the backfill race: new IDs allocated
while backfill runs are in the global cursor range.

### 5.3 Batch algorithm

Use a fixed batch size (candidate: 128) and fixed fetch concurrency (candidate:
16). Values are configuration with hard safety maxima.

```text
while processed_through < observed_max:
    range = next contiguous batch
    fetch every ID in range concurrently
    sort successful typed results by ID
    resolve/store/match results in ascending order
    record retryable gap state for every unresolved ID
    in one final transaction, advance processed_through to batch end
```

Ascending reduction means a normal comment's lower-ID parent is already
available when both are in the same batch. Database uniqueness makes re-fetch
and re-reduction safe after a crash.

The batch may advance past a temporarily null ID only after an `ingest_gaps`
row is committed. That row has attempts, next retry, error class, and first/last
attempt time. Gap retries continue independently; resolving an older gap may
emit a new event below the current cursor without duplicating any effect.

There is no “permanent null” assumption. Operator policy may eventually mark an
old gap dormant, but it remains visible and manually retryable.

### 5.4 Item normalization

For every returned item:

- validate response ID equals requested ID;
- validate known item type;
- preserve exact case-sensitive author;
- convert Unix seconds with range checks;
- normalize absent booleans to false without inventing absent author/text;
- retain `parent`, score, descendants, dead, deleted, and source content hash;
- parse/sanitize materialized title/text and URL under the security contract;
- ignore unknown fields;
- store the time fetched and source-state revision hash.

Core graph metadata is retained for every globally ingested item. Full source
and sanitized content are retained only when the item is relevant to a feed,
tracked identity, notification, watch, rendered thread, or operator fixture.
This keeps parent/root matching durable without mirroring every HN body.

### 5.5 Parent and root resolution

For a comment:

1. start at `parent_id`;
2. load graph metadata locally;
3. if absent, fetch/normalize the parent through the same adapter and store it;
4. track visited IDs to reject cycles;
5. walk iteratively until a story/poll root is found;
6. store `root_story_id` and depth on the comment.

The walk has a generous hard depth bound (candidate: 1,024) and a total fetch
bound. Exceeding it produces visible unresolved graph state and retry work; it
does not silently classify the comment under an invented root.

No closure table is created. For a newly ingested comment, the reducer already
holds the bounded ancestor slice used to match branch watches.

### 5.6 Materialization triggers

Full item content is materialized when:

- the story occurs in a retained feed capture;
- an item is a parent/ancestor/source for an Inbox notification;
- an item is a watch root or activity beneath one;
- a user opens a thread/focused branch;
- a changed materialized item is reconciled;
- an explicit bounded replay fixture requires it.

Materialization is idempotent and records sanitizer version. A sanitizer
upgrade reprocesses stored source HTML in a bounded maintenance command.

## 6. Onboarding backfill

Backfill is a durable job per tracked identity, not a request that holds an HTTP
connection open.

### 6.1 Flow

1. Fetch exact user record and verify returned case-sensitive ID.
2. Capture/display the source `submitted` count.
3. Select at most the first 500 IDs returned by the API.
4. Fetch those items in bounded batches.
5. Keep items authored by the exact identity; materialize them.
6. Inspect their current direct `kids`, fetch those children, and pass each
   through the normal comment matcher.
7. Tag notifications as `backfill` and preserve original occurrence time plus
   later detection time.
8. Commit progress so restart resumes at the next list position.

Backfill does not rely on undocumented list ordering or the approximate age at
which HN disables comments. The UI states its exact item-count boundary.

### 6.2 Duplicate boundary

A child discovered by both global ingestion and backfill has the same source
event key. Unique event/notification/reason constraints collapse it to one
effect. The earlier detection path does not matter.

### 6.3 Removal

Removing a tracked identity marks the user-to-identity relationship removed and
stops future matching. The relationship row remains as private historical
provenance until account deletion, so existing notifications can render their
reason as a removed tracked identity rather than losing causality.

## 7. Feed capture

### 7.1 Schedule

Candidate default:

- every five minutes, fetch `/topstories` and store ranks 1–30;
- in the same capture cycle, fetch Ask/Show/Job membership lists;
- fetch/materialize current story metadata for retained top entries with
  bounded concurrency;
- do not overlap capture cycles; a slow cycle records a missed/late schedule
  rather than starting concurrent copies.

All timestamps use UTC and come from the application clock. Clock rollback is
detected; capture IDs provide the stable sequence.

### 7.2 Atomic publication

One successful feed capture transaction inserts:

- capture header and source hash;
- ordered entries with observed score/comment count;
- Ask/Show/Job membership for those stories;
- aggregate first/last/best-rank updates;
- first-observed and first-crossed milestone events.

A partially fetched cycle is stored as a failed run in operational state but is
not published as a complete capture. History displays a gap.

### 7.3 First observation

`feed.first_observed` is inserted only when no prior aggregate row exists for
the `(feed, story)` pair. A story leaving and returning does not create a second
first event; capture rows still make the reappearance derivable.

### 7.4 Storage growth

v1 stores complete capture entries because the time-machine feature requires
them. M1 measures daily growth. Compaction is not introduced until a retention
decision can preserve the promised capture views. Any later hourly/daily
rollup must leave recent exact captures and visibly label its lower precision.

## 8. Reconciliation

Global numeric ingestion discovers new objects; it does not discover every
later state mutation.

### 8.1 `/updates` loop

At a candidate five-minute interval:

1. fetch `/updates`;
2. deduplicate item/profile IDs within the response;
3. prioritize materialized items, watched roots, tracked profiles, and active
   story roots;
4. refetch under a bounded per-cycle budget;
5. compare source revision/dead/deleted/content hashes;
6. insert deterministic state-change events and update sanitized content in one
   transaction.

### 8.2 Direct refresh

Because `/updates` is not durable, periodically refetch currently active watch
roots and recent notification sources even if absent from `/updates`. This is
also bounded and staggered.

### 8.3 Honest limitation

If an item changes and changes back entirely while the service is offline, the
API provides no reliable way to discover that history. The service guarantees
current reconciled state and locally observed transitions, not an upstream
edit audit log.

## 9. Event matcher and reducer

The matcher is a pure decision layer over:

- normalized source item;
- resolved parent/root and ancestor IDs;
- exact author values;
- applicable tracked identities and watches;
- current cursor/detection metadata.

It does not send SSE, render HTML, or perform external delivery.

### 9.1 Comment transaction

For one comment, the store transaction:

1. upserts normalized item graph/content state;
2. inserts `comment.created:<item_id>` event if absent;
3. finds each account tracking the exact parent author;
4. matches direct-child, branch-ancestor, and story watches;
5. suppresses default unread projection when the source author equals the
   relevant tracked identity;
6. upserts at most one Inbox and one Following notification per user/event;
7. inserts every distinct causal reason;
8. commits all effects together.

There is no window in which an item is committed but its deterministic
notification is missing.

### 9.2 Event keys

Examples:

```text
comment.created:49123456
item.state:49123456:<revision-hash>
feed.top.first:49110000
feed.top.top10:49110000
```

Keys are application-generated from typed fields, not arbitrary JSON. They are
unique and stable across replay.

### 9.3 Reason keys

Examples:

```text
identity.direct:<identity-id>:<parent-id>
identity.story:<identity-id>:<story-id>
watch.direct:<watch-id>:<comment-id>
watch.branch:<watch-id>:<ancestor-id>
watch.story:<watch-id>:<story-id>
```

A notification can own several reason rows. Removing a watch prevents future
matches but does not rewrite prior causality.

## 10. Attention markers

### 10.1 News

The handler loads `previous_capture_id`, constructs a bounded view through
`current_capture_id`, and renders the boundary. The account/cookie marker
advances to that current ID after successful view-model construction. It does
not claim per-story consumption.

### 10.2 Thread

Thread comments are classified against the previous account marker and the
committed global processed-through cursor captured for the view. The response
updates the marker to that cursor after view-model construction. A new item
that commits while rendering is intentionally outside the snapshot and appears
on the next load.

### 10.3 Following

Each watch has `seen_through_event_id`. Aggregates query through a captured
current maximum event ID. `POST /watches/:id/seen` advances only to the boundary
issued with the rendered row/page, never to an unbounded latest value supplied
by the client.

### 10.4 Inbox

Notifications have individual read timestamps. The open/read POST verifies the
notification belongs to the session user. Bulk read similarly carries a
server-issued bounded page/filter boundary.

## 11. Thread loading and rendering

### 11.1 Historical on-demand load

If the local graph does not have a requested story/thread:

1. fetch and materialize the root;
2. breadth/depth walk source `kids` under fixed fetch/node/depth/time limits;
3. normalize every fetched child through ordinary storage/matching with a
   historical-load flag;
4. do not create unread watch activity for objects older than a newly created
   watch boundary;
5. render the locally committed bounded snapshot.

The first request may return a complete bounded thread or an honest partial
state with native continuation/retry links. It never holds an unbounded fetch
fan-out.

### 11.2 Query model

The store materializes a typed `ThreadView` containing:

- root story metadata;
- previous/current marker;
- bounded flat comment rows with IDs, parent/depth, author/time, safe content,
  source status, and new/watch flags;
- truncation/continuation information;
- account-authorized form tokens/actions.

Rendering receives only this model and a writer. It does not retain a database
Rows lease.

### 11.3 Continuation

The preferred pagination boundary is a top-level branch cursor. If one branch
alone exceeds the node limit, a focused continuation cursor contains the last
emitted `(depth-first-id, root, boundary-version)` signed/validated by the
server. Clients cannot use cursors to escape the requested root or request an
unbounded range.

## 12. HN HTML sanitizer

The sanitizer is security-sensitive and receives its own pure fixtures and
fuzz/property testing.

### 12.1 Pipeline

```text
source HTML bytes
  -> UTF-8 and size validation
  -> strict tokenization
  -> allowlisted structural tokens
  -> parsed URL policy for links
  -> canonical safe HTML output
  -> sanitizer version + source/output hashes
```

Candidate allowed elements are the subset needed by observed HN output:
paragraph breaks, emphasis, strong text, preformatted/code blocks, and links.
Only `href` is read from source links; output supplies its own `rel` policy.
Style, script, image, iframe, SVG, event attributes, data attributes, arbitrary
classes/IDs, comments, and unknown elements are never interpreted.

Malformed/unknown markup becomes escaped text. This is a fail-closed rendering
rule, not a second permissive parser.

Titles and usernames are always plain text. The renderer's trusted-HTML
constructor is private to the sanitizer-output adapter.

### 12.2 Reprocessing

Changing the allowlist/tokenizer increments `sanitizer_version`. A maintenance
command processes stored source rows in bounded transactions and can be run on
an isolated database copy before production. Old output remains identifiable
until replaced.

## 13. HTTP and server-rendered UI

### 13.1 Connection/request bounds

Reuse `web.zig` for the per-connection loop, target/form decoding, response
headers, cache helpers, security policy, route matching, HTML escaping, and
HTMX request semantics where compatible.

Application limits include:

- header bytes/count and requests per keep-alive connection;
- target/query/body bytes and form field count;
- per-route content types;
- response/view allocation budgets;
- authenticated rate limits for passkey challenge and mutation routes;
- total concurrent connections and application SSE connections.

### 13.2 Controller sequence

```text
route -> parse bounded input -> authenticate -> authorize -> exact Origin/CSRF
      -> domain/store operation -> reload authoritative view -> render
      -> 200 HTML/fragment or 303 redirect
```

Validation errors return a complete page with safe submitted values and
field/global errors. HTMX enhancement receives the equivalent fragment from
the same error view model.

When one URL selects a fragment through HTMX 4's `HX-Request-Type`, the response
uses `Vary: HX-Request-Type`. A separate fragment URL may be used only where it
materially simplifies caching or SSE invalidation; it must still share the
controller and view model.

### 13.3 Caching

- Authenticated/attention pages: `Cache-Control: private, no-store`.
- Public current News/threads: revalidate with short freshness and ETags where
  safe.
- Historical capture/story pages: immutable or long-revalidate when their
  underlying capture IDs are fixed.
- Fingerprinted embedded assets: long immutable caching.
- All fragment-varying routes send the relevant `Vary` value.

Conditional fragment polling uses HTTP `ETag` and `If-None-Match`. A `304`
contains no body and causes no swap. The v1 does not add the `hx-ptag`
extension.

### 13.4 Assets

CSS, HTMX core, the v4 `hx-sse` extension, passkey JavaScript, and optional
keyboard JavaScript are exact build inputs and embedded in the executable.
There is no CDN, runtime asset compilation, bundler, or Node runtime.

Each script has a narrow role:

- `passkeys.js`: WebAuthn browser API serialization only;
- `keyboard.js`: optional focus/navigation convenience only;
- HTMX core/`hx-sse`: optional partial/live response handling.

## 14. Application SSE

App SSE is distinct from upstream Firebase SSE.

### 14.1 Contract

`GET /events` requires an authenticated session and returns
`text/event-stream`. The source element uses the exactly pinned HTMX 4
`hx-sse:connect` extension. The server sends:

- an initial server-rendered current-count/banner fragment;
- event IDs derived from the latest durable notification/event boundary;
- small invalidation fragments after relevant commits;
- periodic comments/heartbeat within proxy timeouts;
- a retry hint and graceful close during deployment.

The stream never sends tokens, raw HN source HTML, or a complete thread tree.

### 14.2 Recovery

On connect/reconnect, query durable state. `Last-Event-ID` can reduce redundant
work but is not trusted as authorization or completeness proof. If an event was
committed and the process crashed before broadcasting it, the initial reconnect
state still exposes the correct unread/activity count.

### 14.3 Bounds

Limit streams per user, total streams, write-buffer bytes, and idle/maximum
connection lifetime. A slow client is disconnected and may reconnect; it never
blocks ingestion or holds a database connection.

## 15. Passkey authentication

Follow the already qualified Passcay/zbor shape from adjacent applications,
while keeping account/user ownership application-specific.

### 15.1 Registration

1. issue single-use registration challenge with RP ID, exact origin, user
   handle candidate, expiry, and request-binding hash;
2. browser calls `navigator.credentials.create`;
3. finish endpoint validates challenge/purpose/origin/RP/user verification and
   attestation response under the selected policy;
4. transactionally create user + first credential + session;
5. redirect to the saved safe same-origin return route.

### 15.2 Authentication

1. issue bounded single-use authentication challenge;
2. browser calls `navigator.credentials.get`;
3. validate credential, challenge, origin, RP ID, signature, user verification,
   sign count, backup state, expiry, and one-time use;
4. rotate/issue session and redirect.

### 15.3 Session model

Store only token hashes. A session has a separate CSRF secret/hash, user ID,
created/last-seen/expiry/revocation timestamps, and bounded metadata useful for
the user session list. Rotate on authentication and privilege changes. Never
accept session IDs from URLs.

## 16. Database ownership and transactions

### 16.1 Owners

```text
process Database
  -> fixed Connection pool
     -> short Lease
        -> Transaction or Statement/Rows
           -> copied typed view/domain values
```

Every Rows iterator is finished/deinitialized before another execution on its
connection. Borrowed text/blob values are copied into application-owned view
models before the lease ends. Database deinit before connections is a panic
worthy lifecycle defect.

### 16.2 Pool

M0 measures the smallest pool that prevents long public reads from starving
the ingestion writer. Candidate: four connections with one reserved for
ingestion/maintenance and three general leases. Pool capacity is fixed;
acquisition has a deadline; a timed-out request returns a service-unavailable
state rather than allocating another connection.

The pool is application code because transaction and priority semantics are
product-specific. It is not added to `turso.zig` or `web.zig`.

### 16.3 Transactions

Use explicit transactions for:

- item + event + notification + reason reduction;
- feed capture publication and aggregate/milestone updates;
- watch creation and its event boundary;
- identity creation/quota + backfill job;
- auth challenge consumption + credential/session issuance;
- account deletion/revocation of private state.

No network call occurs while a database transaction is open. Fetch first,
validate/normalize, then acquire the connection and commit a bounded unit.

There is no automatic transaction retry hidden by the store. Busy/conflict
classification is explicit; a whole idempotent unit may be retried by its
supervisor with a bound.

## 17. Private Atom feeds

Feed URLs contain a high-entropy bearer token. The database stores only its
hash, user, scope, creation, last-use (coarsely updated), and revocation time.

Responses:

- are `private, no-store`, non-indexed, and HTTPS-only;
- contain stable entry IDs derived from notification/event IDs;
- include sanitized bounded context and canonical app/native-HN links;
- support conditional GET without revealing token material in logs;
- never mark Inbox/Following state read.

Reverse-proxy access logs must redact the token path or disable access logging
for these routes. Revocation is immediate at the application database.

## 18. Configuration

Configuration is environment/CLI based and validated at startup. Candidate
names:

```text
HNC_LISTEN_ADDR=127.0.0.1:9332
HNC_BASE_URL=https://continuity.example
HNC_DATABASE_PATH=/var/lib/hn-continuity/continuity.db
HNC_HN_BASE_URL=https://hacker-news.firebaseio.com/v0
HNC_FETCH_CONCURRENCY=16
HNC_ITEM_BATCH_SIZE=128
HNC_FEED_INTERVAL=5m
HNC_FEED_DEPTH=30
HNC_UPDATE_INTERVAL=5m
HNC_SSE_CLIENT_LIMIT=256
HNC_RP_ID=continuity.example
HNC_LOG_LEVEL=info
```

Testing may override HN base URL to a loopback deterministic fixture server.
Production rejects a non-HTTPS upstream unless an explicit development mode is
set. Secrets (cookie/token hashing keys if required by the final design) come
from credential files or protected environment, never committed `.env` files.

## 19. CLI contract

Candidate commands:

```text
hn-continuity serve
hn-continuity migrate --database PATH
hn-continuity backup --database PATH --output PATH
hn-continuity verify --database PATH
hn-continuity status --database PATH
hn-continuity replay --fixture PATH --database PATH
hn-continuity sanitize --database PATH --limit N
```

- `serve` is the only command allowed to own the live application lock.
- migration/backup/verify are offline against a stopped writer in v1.
- commands reject missing/non-database sources before an engine can create a
  new file at a mistyped path.
- backup publishes output atomically only after schema/inventory/integrity
  checks against an isolated reopen.
- replay always requires an explicit fixture and database path and refuses the
  configured production path.

## 20. Health, status, and observability

### 20.1 Health endpoints

- `/healthz`: process can execute the handler; no external network check.
- `/readyz`: listener owns a compatible, queryable database and lifecycle is
  not stopping.

Both responses are minimal and expose no file paths, IDs, usernames, gaps, or
versions useful to attackers.

### 20.2 Operator status

The local `status` command reports:

- schema/app version and database path identity;
- processed-through/observed-max and lag;
- oldest/count of unresolved gaps;
- upstream SSE connected/reconnect state from durable heartbeat data;
- last successful/failed feed capture and reconciliation;
- active tracked identities/watches/users as counts only;
- database file/sidecar sizes and last verified backup metadata.

### 20.3 Logs

Structured log fields use event names, HN numeric IDs, durations, counts, error
classes, and retry attempt. Repeated upstream failures are rate-limited but the
first/latest state transition remains visible. Notification/user IDs in logs
are internal opaque identifiers; exact tracked usernames are omitted by
default.

## 21. Deployment and data safety

### 21.1 Files and ownership

Candidate layout:

```text
/opt/hn-continuity/releases/<immutable-id>/hn-continuity
/opt/hn-continuity/current -> releases/<immutable-id>
/var/lib/hn-continuity/continuity.db
/var/lib/hn-continuity/backups/
```

The service user owns only its state/log/runtime directories. The release tree
is read-only to the service. systemd supplies private temporary directories and
resource limits. Caddy is the only public listener.

### 21.2 Caddy

Caddy terminates HTTPS, forwards an exact trusted client IP header only from
loopback, configures SSE-friendly buffering/timeouts, redacts private feed
tokens from logs, and adds/overwrites security headers where the application
does not already own them. The application still validates its canonical
origin and does not trust arbitrary forwarding headers.

### 21.3 Backup

v1 uses stopped-writer backup:

1. build/verify candidate without touching live state;
2. stop service and verify no owner/listener remains;
3. use the currently deployed compatible binary to create a verified copy;
4. hash and record source/output metadata without user content;
5. open the copy in isolation and run schema/inventory/integrity checks;
6. restart the unchanged service if no deployment follows.

Stock `sqlite3` is never used as a live writer. Turso-specific sidecars and
mixed-version behavior are part of every engine/toolchain upgrade rehearsal.

### 21.4 Upgrade and rollback

Migrations are additive where possible and ordered. Before promotion, rehearse
on a restored copy, run migrations twice to prove idempotence, start the
candidate against the copy, and run end-to-end replay/HTTP checks. Production
promotion records previous binary and pre-migration backup. Rollback uses both;
an old binary is never pointed blindly at a newer unqualified schema.

### 21.5 Verification after launch

After systemd reports active/readiness:

1. wait beyond initial startup/capture activity;
2. verify MainPID and `/proc/<pid>/exe` identify the intended immutable binary;
3. verify listener and database/sidecar ownership;
4. verify health, readiness, public News, authenticated flow, and app SSE;
5. verify cursor/feed timestamps continue moving;
6. inspect logs/resource/disk state;
7. run the bounded production browser acceptance where authorized.

Initial readiness alone is not deployment success.

## 22. Failure behavior summary

| Failure | Required behavior |
| --- | --- |
| HN SSE disconnects | Poll watchdog continues; reconnect with backoff; cursor unchanged until work commits |
| HN returns `307` | Follow allowed HTTPS Firebase redirect under limit |
| HN item is temporary `null` | Durable gap, cursor may pass only after gap commit, scheduled retry remains |
| Parent missing | Store unresolved comment/gap work; fetch/retry parent; no guessed root/reason |
| Huge max jump | Fixed batches, visible catch-up lag, normal pages serve stored state |
| Duplicate item/event | Idempotent upsert/unique keys; no duplicate notification |
| DB busy | Bounded lease/transaction retry at unit boundary; visible failure after limit |
| Disk full | Transaction fails; cursor does not advance; readiness/status/logs expose local failure |
| Crash before commit | Batch replays |
| Crash after commit before browser SSE | Durable page/reconnect reveals state |
| App SSE slow client | Disconnect client; ingestion never blocks |
| Feed cycle partial | Do not publish capture; record visible gap/failure |
| Upstream item deleted | Preserve event/reason; render deleted status |
| Sanitizer rejects markup | Render escaped safe text; record bounded diagnostic |
| Newer schema | Fail closed before listener readiness |

## 23. Architecture acceptance

The architecture is considered implemented only when real evidence shows:

- exact dependency/toolchain inputs build in Debug and ReleaseSafe;
- the chosen local Turso owner/pool survives concurrent HTTP, ingestion, and
  orderly/forced shutdown without leaked owners or invalid Rows use;
- upstream normal JSON, SSE initial event, `307`, disconnect, null, malformed,
  and jump fixtures drive the same adapter used in production;
- deterministic replay and every named transaction/crash boundary preserve
  projections;
- complete/fragment HTML share view models and remain semantically equivalent;
- JavaScript-disabled public/native flows, passkey browser flow, HTMX update,
  and app-SSE reconnect work in narrow real-browser acceptance;
- backup/restore/migrate/rollback and sustained systemd+Caddy operation are
  rehearsed against an isolated release artifact.
