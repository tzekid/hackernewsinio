# Product specification

Status: proposed

Working product name: HN Continuity

Normative language: **must**, **must not**, **should**, and **may** are used in
their ordinary requirements sense.

## 1. Product statement

HN Continuity is an unofficial, server-rendered Hacker News client that
remembers where a reader was and shows what changed while they were away.

It combines three ledgers:

1. **News ledger** — ranked-feed observations and story first-seen history.
2. **Conversation ledger** — replies, branch activity, watched-story activity,
   and their causal relationships.
3. **Attention ledger** — visit boundaries, thread markers, notification state,
   and watches.

The primary promise is:

> Return to Hacker News without reconstructing what happened from scratch.

“What changed” always means what this service durably observed. Ranked-feed
history has the precision of the configured capture interval. New item
creation is recovered from the durable numeric cursor. Edits and deletions are
best-effort observations because the upstream API does not expose a replayable
change history.

## 2. Product goals

### G1. Discovery continuity

Answer: which stories entered the configured ranked-feed depth since the
reader's previous News visit?

### G2. Conversation continuity

Answer, in priority order:

1. Was there a direct reply to a tracked identity's comment or story?
2. Did a specifically watched comment branch receive descendants?
3. Did a watched story receive discussion elsewhere?

### G3. Reading continuity

When an account holder reopens a previously rendered thread, highlight comments
whose HN item IDs are later than the prior committed thread marker.

### G4. Explainability

Every notification must expose the source event and all reasons it matched. A
reader can inspect the reply, parent, relevant ancestor/watch, root story, and
tracked identity without relying on hidden scoring.

### G5. Operational simplicity

The supported deployment is one Zig service, one local embedded Turso
database, embedded assets, systemd, and Caddy. No other durable service is
required.

## 3. Users and identity

### 3.1 Anonymous reader

An anonymous reader can browse News, History, stories, and threads without an
account and without JavaScript. A first-party marker cookie supports the global
"since your previous News visit" boundary. The cookie is not an HN credential
and does not identify an HN user.

Anonymous readers do not receive Inbox notifications, persist thread markers,
or create watches. Those actions lead to application account registration and
return to the original route afterward.

### 3.2 Application account holder

An application account stores private attention state and authenticates with a
passkey. It is independent of Hacker News. The account holder can:

- track exact public HN usernames;
- receive a durable Inbox;
- follow stories or comment branches;
- persist thread markers across devices;
- generate/revoke private Atom feed tokens;
- export or delete application-owned state.

WebAuthn requires JavaScript. This is the only JavaScript requirement for
account authentication; public reading remains server-complete.

### 3.3 Tracked HN identity

A tracked HN identity is an exact, case-sensitive username found in the public
HN API. Tracking does **not** prove ownership. The product must say “track this
identity” and must not say “log in to HN,” “connect HN,” or “verified HN
account.”

Inbox context names the actual username (for example, “`alice` wrote”) rather
than asserting “You wrote.” A user may label an identity “me” privately, but
that label is not verification.

### 3.4 Operator

The operator installs releases, runs migrations, inspects freshness/gaps,
creates backups, rehearses restores, rotates service secrets, and diagnoses
upstream or storage failures. Operator actions use the local CLI and service
manager, not a public admin dashboard in v1.

## 4. Core definitions

| Term | Normative meaning |
| --- | --- |
| Observed | Successfully fetched, normalized, and committed locally |
| New item cursor | Highest HN item ID for which every earlier ID is stored or represented by a durable retryable gap record |
| Feed capture | One timestamped observation of an upstream ranked list at a configured depth |
| First observed | First local feed capture containing a story; not a reconstructed upstream timestamp |
| Event | Immutable normalized fact derived from one observed source state |
| Notification | User projection of an event, with one or more causal reasons |
| Unread | Explicit notification state; not a synonym for unseen comment |
| Thread marker | Cursor boundary committed when a thread snapshot is rendered for an account |
| New comment | A comment in the current rendered snapshot whose ID is greater than the previous thread marker |
| Watch marker | Event boundary through which Following activity has been acknowledged |
| Muted | Activity remains durably explainable but is excluded from default unread delivery/counts |

## 5. Information architecture

| Screen | Primary question | Public? |
| --- | --- | --- |
| News | Which observed front-page stories appeared since my previous visit? | Yes |
| Inbox | Which direct replies concern the identities I track? | Account |
| Following | Which watched stories or branches changed meaningfully? | Account |
| Thread | What does this discussion contain, and which comments are new to me? | Yes; markers/watches require account |
| History | What did the observed ranked feeds look like at a chosen time? | Yes |
| Settings | Which identities, passkeys, feed tokens, and preferences do I own here? | Account |

Inbox and Following remain separate. A direct reply should not disappear into a
large chronological activity stream.

On narrow screens, the persistent navigation contains News, Inbox, Following,
and Settings. Thread is contextual rather than a fifth tab. History remains a
real public route but appears through the `Now / History` mode inside News. The
accepted visual and interaction details are defined in `DESIGN.md`.

## 6. Route contract

Routes are HTML unless explicitly identified as an asset, Atom, SSE, or
WebAuthn transport. Query values and request bodies are bounded and unknown
form fields are rejected.

| Method | Route | Purpose | Auth |
| --- | --- | --- | --- |
| GET | `/` | Redirect to `/news` | Public |
| GET | `/news` | Chronological observed-feed view and filters | Public |
| GET | `/history` | Capture timeline and date selection | Public |
| GET | `/history/:story_id` | Story rank/score/comment trajectory | Public |
| GET | `/item/:story_id` | Thread page | Public |
| GET | `/item/:story_id?focus=:comment_id` | Focused ancestor/branch context | Public |
| GET | `/inbox` | Direct-reply list | Account |
| GET | `/inbox/:notification_id` | Notification context | Account |
| POST | `/inbox/:notification_id/open` | Mark read and redirect to context | Account + CSRF |
| POST | `/inbox/:notification_id/unread` | Mark unread | Account + CSRF |
| POST | `/inbox/:notification_id/dismiss` | Dismiss locally while preserving provenance | Account + CSRF |
| POST | `/inbox/read-all` | Mark the current bounded result set read | Account + CSRF |
| GET | `/following` | Watched scopes ordered by meaningful activity | Account |
| POST | `/watches` | Create story/direct-child/branch watch | Account + CSRF |
| POST | `/watches/:watch_id/remove` | Remove watch | Account + CSRF |
| POST | `/watches/:watch_id/seen` | Advance its activity marker | Account + CSRF |
| POST | `/watches/:watch_id/mute` | Mute or unmute | Account + CSRF |
| GET | `/settings` | Identities, passkeys, Atom tokens, account state | Account |
| POST | `/settings/identities` | Validate and add exact HN username | Account + CSRF |
| POST | `/settings/identities/:id/remove` | Stop tracking an identity | Account + CSRF |
| POST | `/settings/feeds` | Create a private Atom token | Account + CSRF |
| POST | `/settings/feeds/:id/revoke` | Revoke Atom token | Account + CSRF |
| POST | `/settings/passkeys/rename` | Rename one active passkey | Account + CSRF |
| POST | `/settings/passkeys/revoke` | Revoke a non-last passkey | Account + CSRF |
| POST | `/settings/sessions/revoke` | Revoke one application session | Account + CSRF |
| POST | `/settings/export` | Request/download bounded state export | Account + CSRF |
| POST | `/settings/delete` | Confirm account-state deletion | Account + CSRF |
| GET | `/auth/register` | Passkey registration page | Public |
| GET | `/auth/login` | Passkey login page | Public |
| POST | `/auth/*/options` | Bounded WebAuthn options JSON | Context-dependent |
| POST | `/auth/*/finish` | Verify WebAuthn response | Context-dependent |
| POST | `/auth/passkeys/options` | Begin adding another passkey | Account + exact Origin |
| POST | `/auth/passkeys/finish` | Verify and add another passkey | Account + exact Origin |
| POST | `/auth/logout` | Revoke current session | Account + CSRF |
| GET | `/feeds/:token/inbox.atom` | Private Inbox feed | Bearer token in path |
| GET | `/feeds/:token/following.atom` | Private Following feed | Bearer token in path |
| GET | `/events` | Authenticated application SSE invalidation | Account |
| GET | `/healthz` | Process liveness | Public, minimal |
| GET | `/readyz` | Local store/migration readiness | Public, minimal |

Native state-changing forms use POST and return `303 See Other`. Fragment
responses, when later added, use the same controller operation and typed view
model as the corresponding full page.

## 7. News requirements

### N1. First response

`GET /news` must render a complete chronological list from stored captures. It
must not require a startup request for titles, scores, visit markers, or filter
state.

### N2. Default feed meaning

The default ledger observes the first 30 IDs of `/topstories` every five
minutes. Both values are configuration, but the UI must state them when showing
history. “Front page” in this application means “rank 1–30 in a successful
`topstories` capture,” not an unverifiable continuous HN state.

### N3. Ordering

Stories are ordered by first-observed capture descending, then first-observed
rank, then story ID. HN submission time is displayed but is not the primary
chronological key.

### N4. Filters

v1 supports:

- any observed rank 1–30;
- reached top 20;
- reached top 10;
- Ask HN;
- Show HN;
- Jobs.

Ask/Show/Jobs use captured membership in the corresponding official endpoint,
not title substring classification alone.

### N5. Previous-visit boundary

The response reads the prior marker before rendering and draws a clear boundary
between stories first observed after and at/before that marker. After the
response snapshot is constructed, it advances the account marker or bounded
anonymous cookie to the newest included capture.

The marker means “previous News visit,” not “every story above this line was
read.” The UI must use “new since your previous visit,” never “unread stories.”

### N6. Paging

History is cursor-paged by `(first_capture_id, story_id)`. No request can ask
for an unbounded date range or result count. Native `Older` and `Newer` links
are required.

### N7. Freshness

If captures are stale, the page remains usable and shows the last successful
capture time plus a plain-language stale warning. It must not silently present
old data as current.

## 8. Inbox requirements

### I1. Direct reply

A new comment is a direct-reply candidate when its parent is a comment authored
by an exact tracked HN username.

### I2. Comment on tracked story

A new comment is a tracked-story reply candidate when its parent is a story
authored by an exact tracked HN username.

### I3. Self activity

If the new comment author equals the matched tracked username, the event is
stored but the default notification is suppressed. The deterministic replay
must produce the same suppression every time.

### I4. Context

An Inbox entry and detail page must include:

- root story title and native HN link;
- exact tracked identity and original parent item;
- new reply author, time, sanitized text, and source status;
- enough ancestors to locate the exchange, up to a documented bound;
- every matching reason;
- actions to open the focused local branch, mark read/unread, mute the related
  scope, and open native HN.

If a parent or ancestor is unavailable, the card renders the known IDs and an
honest unavailable state; it does not invent context.

### I5. Read semantics

Rendering the list does not mark entries read. `POST /inbox/:id/open` marks one
notification read and redirects to its context. `read-all` applies only to the
bounded result set identified by a server-issued filter/cursor token; it must
not race across an unbounded future Inbox.

### I6. Durable deletion behavior

Deleting or killing the upstream reply/parent later does not delete the event
or notification. The source body becomes `[deleted]` or `[dead]`, with its
provenance and occurrence time retained.

## 9. Following requirements

### F1. Watch scopes

v1 supports exactly three scopes:

| Scope | Matches |
| --- | --- |
| Direct children | New comments whose parent is the watched comment |
| Branch | New comments whose ancestor chain contains the watched comment |
| Story | New comments whose resolved root is the watched story |

Tracked-user activity inside a story and global user-submission tracking are
deferred.

### F2. No duplicate activity cards

When one event matches several watches, Following shows one event contribution
for the user and exposes all reasons. Direct-reply Inbox state and Following
state may both refer to the event because they answer different questions, but
the UI cross-links them and does not claim two replies occurred.

### F3. Ordering

Following is ordered by priority and latest meaningful event:

1. branch with a direct child reply;
2. branch descendants;
3. watched-story activity;
4. rank milestone, if enabled later.

Raw story age is not the ordering key.

### F4. Aggregates

Each watch shows counts since its marker. A branch row can distinguish direct
children, descendants below the branch, and other comments in the root story.
Counts derive from durable events through a captured event boundary so the
same page cannot change underneath itself.

### F5. Watch creation boundary

Creating a watch records the current committed item/event cursor. Existing
comments provide context but do not become unread activity. An explicit
bounded import action may be designed later; silent historical notification
storms are forbidden.

## 10. Thread requirements

### T1. Source and ordering

Threads render from the local normalized parent graph. Missing historical
content is fetched on demand through the same bounded source adapter. Siblings
are ordered by `(created_at, id)` for stable continuity.

### T2. Bounded rendering

A response has fixed limits for total comments, ancestor depth, body bytes,
and render allocations. Large threads are segmented by top-level branch and
focused continuation links. The server never builds or sends an unbounded
comment tree.

### T3. New-comment marker

For an authenticated reader:

1. capture the previous `seen_through_item_id`;
2. capture the current committed global item cursor for this response;
3. mark rendered comments with `id > previous` using semantic `<mark>` and
   explanatory text available to assistive technology;
4. commit the current cursor as the next marker only after the response view
   model has been successfully constructed.

The marker does not advance when an SSE event arrives while the page is open.
The event displays a small “new activity available” banner. Reloading or using
a native refresh link constructs the next authoritative snapshot.

### T4. First visit

On the first account visit to a thread, existing comments are not styled as
new. The first marker is the current committed cursor. A user may still inspect
capture/creation times normally.

### T5. Collapse and focus

Branches use semantic `<details>`/`<summary>` where that structure remains
accessible. A focus link renders the selected comment, bounded ancestors, and
its descendant branch. Collapse state is not synchronized across devices in
v1.

### T6. Native HN boundary

Every story/comment context provides a link to the canonical HN item. Reply,
vote, favorite, flag, edit, delete, and account actions occur only on native
HN. The application never proxies HN credentials or actions.

## 11. History requirements

### H1. Time machine

History can select a successful feed capture and render its exact locally
stored ranks, score values, and comment counts. Missing/failed capture periods
are shown as gaps, not interpolated silently.

### H2. Story trajectory

A story detail shows:

- first and last observed captures;
- first and best observed rank;
- rank/score/comment-count samples;
- locally observed top-20/top-10 milestones;
- reappearance after one or more absent captures.

Small trajectories may be rendered as accessible server-generated SVG with a
text/table equivalent. No charting framework is required.

### H3. Retention disclosure

The page states the beginning of authoritative local history and the retention
policy. Imported or approximate history, if ever supported, is a separate
source class and visibly labeled.

## 12. Settings and account requirements

### S1. Add identity

The form preserves the user's exact case, fetches `/user/:id`, and shows a
profile preview before confirmation. The confirmed stored ID must exactly match
the API's returned case-sensitive `id`. Unknown/private-no-activity users are
rejected with an honest explanation.

### S2. Onboarding backfill

Backfill is explicit and bounded. v1 processes at most the first 500 item IDs
returned in `submitted`, with a visible count, time, and completion/error state.
It inspects authored comments/stories and their current direct children.

The UI says exactly what range was inspected; it does not call the result “all
historical replies.” New global ingestion begins from the cursor captured
before backfill, so replies created during onboarding are not missed.

### S3. Quotas

Initial limits are configuration with conservative defaults:

- 5 tracked HN identities per application account;
- 200 active watches;
- 5 active passkeys;
- 10 active sessions;
- 5 active private feed tokens.

Limits are enforced transactionally and rendered before a request can create
unbounded upstream or database work.

### S4. Passkeys and sessions

Registration/login verify challenge, origin, RP ID, credential, signature,
user verification, and sign-count/backup state according to the pinned
Passcay contract. Challenges are single-use, expiring, purpose-bound, and
bounded in number. Session tokens and feed tokens are random, stored hashed,
revocable, and never logged.

Users can name passkeys, add another, revoke any non-last active passkey, list
sessions, revoke sessions, and log out.

### S5. Export and deletion

Export contains account-owned settings, identities, watches, markers, and
notification metadata. It does not duplicate the entire public HN corpus.

Deletion revokes credentials/sessions/feed tokens and removes or anonymizes all
user-specific projections in one controlled operation. Shared public items,
feed captures, and normalized source events remain because they are not owned
by one user; all joins to the deleted user are removed.

## 13. Notification event semantics

| Event | Deterministic trigger | Default projection |
| --- | --- | --- |
| `comment.created` | A newly observed item has type `comment` and a resolved parent/root | Matcher input only |
| `reply.direct` | Parent comment author equals an exact tracked identity | Inbox |
| `reply.story` | Parent story author equals an exact tracked identity | Inbox |
| `watch.direct_child` | Parent ID equals a direct-child watch target | Following |
| `watch.branch` | Any ancestor ID equals a branch watch target | Following |
| `watch.story` | Root story ID equals a story watch target | Following |
| `feed.first_observed` | First successful configured feed capture containing story | News/History only |
| `feed.milestone` | Best observed rank first crosses a configured threshold | History; delivery deferred |
| `item.state_changed` | A materialized/watched item changes content hash/dead/deleted state | Quiet status; best effort |

Mentions are not a v1 event. HN has no structured mention relation, and text
matching would create false authority.

Each user-visible reason can render a causal sentence such as:

> Shown because HN comment 49123456 replies to comment 49120111, authored by
> tracked identity `alice`, under story 49110000.

## 14. Interface and interaction contract

### 14.1 Visual character

The accepted first interface is the light, mobile-first system in `DESIGN.md`
and `design/style-guides/mobile-v1-overview.png`. It is dense, textual, fast,
and recognizably compatible with HN reading habits. It uses white surfaces,
near-black system typography, one orange-red accent, divided lists, metadata
lines, capped indentation, and compact text status. It must not become a
generic card feed, poster layout, or decorative dashboard.

### 14.2 Responsive behavior

At narrow widths, metadata wraps, branch indentation is capped, focus controls
remain reachable, and no essential action relies on hover. Desktop density is
not achieved by making mobile text too small. The first acceptance widths are
`375px` and `390px`; the supported narrow range is `320px` through `430px`
without horizontal page scrolling. Desktop later derives from the same tokens
and components rather than introducing a separate style.

### 14.3 Keyboard enhancement

A small optional script may add `j`/`k` movement and focused open/follow
shortcuts. Every target remains a real link or form control. Keyboard state is
not a second navigation model.

### 14.4 Accessibility

Required behavior includes:

- one logical heading hierarchy and skip link;
- visible focus and current navigation state;
- semantic lists, times, marks, details, forms, and status messages;
- new/unread meaning conveyed by text as well as color;
- sufficient contrast in the accepted light mode; any future dark mode needs
  its own accepted design and equivalent contrast;
- no focus theft or silent scroll jumps after HTMX/SSE updates;
- reduced-motion behavior for any enhancement.

### 14.5 Five required design states

Before broad implementation, static semantic HTML must reproduce the accepted
mobile hierarchy for:

1. News after a three-day absence with a visible boundary and stale/fresh time;
2. Inbox with expanded direct-reply, original-parent, and ancestor context;
3. Following with branch and whole-story activity levels;
4. a large Thread with 14 new comments and one watched branch;
5. Settings with tracked identity, passkey, private Atom, mute, export, and
   deletion state.

The canonical overview fixes the visual direction. The HTML exercise tests
whether real content, native controls, no-JavaScript behavior, and edge cases
fit it without visual novelty or a second state model.

## 15. Security and privacy requirements

### SEC1. HN trust boundary

HN titles, profile text, story text, and comment text are untrusted. Source HTML
is never rendered directly. Only sanitizer-versioned output may use the trusted
HTML renderer type. All other dynamic strings use context-specific text,
attribute, and URL escaping from `web.zig`.

### SEC2. URL policy

Parse URLs; do not validate them with string prefixes. External content links
allow `http` and `https`. Application action URLs are constructed locally.
Unsafe, malformed, credential-bearing, or control-character URLs are rendered
as non-clickable text.

### SEC3. Browser policy

Production responses use a restrictive CSP with self-hosted scripts/styles,
`base-uri 'none'`, `object-src 'none'`, `frame-ancestors 'none'`, and
`form-action 'self'`. Also send `X-Content-Type-Options: nosniff`, a restrictive
Permissions Policy, HSTS at the HTTPS boundary, and
`Referrer-Policy: same-origin`.

The `same-origin` referrer policy is deliberate: native POST navigations must
retain a usable same-origin `Origin` value for exact-Origin validation.

### SEC4. Application writes

Every authenticated POST requires:

- valid, unexpired session;
- exact expected `Origin`;
- session-bound CSRF token using constant-time comparison;
- expected form or JSON content type;
- bounded body/field counts/decoded bytes;
- rejection of duplicate and unknown fields;
- authorization against the user-owned target;
- `303` redirect after a successful form commit.

### SEC5. Cookies

Production session cookies are `Secure`, `HttpOnly`, host-only (`__Host-`
prefix), `Path=/`, and `SameSite=Lax`. Lax is chosen so a reader returning from
a native HN/story link remains signed in; CSRF and exact-Origin checks protect
writes. Anonymous News marker cookies contain only a bounded opaque/numeric
continuity value and no HN identity.

### SEC6. Secrets and logs

Logs must not contain passkey challenges/responses, session or Atom tokens,
CSRF tokens, raw comment bodies, or complete upstream response bodies. Error
logs use item IDs, state names, retry counts, and bounded diagnostics.

### SEC7. Privacy

Tracked identities and watches are private application state. There are no
public profiles, follower counts, global watch popularity, cross-user
recommendations, or sale/use of attention data. Atom tokens are credentials and
may be individually revoked.

## 16. Reliability and performance requirements

### R1. Idempotence

Replaying the same source envelopes any number of times produces the same item,
event, notification, reason, and marker projections. Unique constraints are the
last line of defense; the matcher itself must also be deterministic.

### R2. Cursor recovery

After restart, ingestion resumes at the committed processed-through cursor.
Fetched-but-uncommitted work is replayed. A null/failed item is represented by
a durable retry record before the cursor can pass it and remains eligible for
later resolution.

### R3. Crash boundaries

At minimum, automated real-process tests cover:

- crash after fetch and before database transaction;
- crash during item/event/notification transaction;
- crash after commit and before app-SSE publication;
- restart with a partially completed numeric batch.

No case may duplicate user-visible notifications or permanently skip a new HN
item.

### R4. Upstream degradation

SSE disconnect, `307` redirect, timeout, malformed JSON, temporary null,
connection reset, and a large `maxitem` jump are bounded and retried. The
polling watchdog and cursor are correctness mechanisms; SSE is a latency
mechanism.

### R5. Local availability

Stored pages remain available during an HN outage. Freshness timestamps and
warnings remain honest. Readiness fails for an unusable/mismatched local store,
not merely because upstream is temporarily unavailable.

### R6. Resource bounds

Every queue, fetch batch, database result, thread render, ancestor walk, body,
header set, SSE client set, backfill, export, and maintenance job has an
explicit limit. Limits return a useful state and do not silently truncate while
claiming completeness.

### R7. Measurements

The release records, without preselecting flattering targets:

- startup and shutdown time;
- idle and replay peak RSS;
- database growth per day split by graph/content/captures/user projections;
- upstream cursor lag and unresolved gap count/age;
- feed-capture duration/failure rate;
- direct-reply detection latency;
- full-page and fragment response p50/p95/p99 plus bytes;
- active/peak app SSE connections;
- replay throughput and catch-up time after a simulated outage;
- backup, restore, and integrity-check duration.

Budgets become release gates only after M0/M1 measure the chosen stack and
representative fixtures.

## 17. Explicit non-goals

v1 must not include:

- HN password/session-cookie handling;
- programmatic posting, editing, voting, flagging, or favoriting;
- AI-generated or AI-edited comments;
- article mirroring or reader mode;
- native mobile/desktop clients;
- Reddit, Lobsters, Slashdot, or general feed aggregation;
- semantic/vector search, embeddings, or opaque recommendations;
- mentions inferred from `@username` text;
- global tracked-user activity alerts;
- social profiles, public follows, or popularity counts;
- email delivery, Web Push, or a delivery worker before Atom is validated;
- Redis, Kafka, a message broker, a separate worker deployment, or cloud DB;
- a closure table for all comment ancestry;
- an ORM, template language, client router, hydration, virtual DOM, or browser
  state store;
- multiple thread-ordering modes;
- CI, a browser-test framework, or npm project metadata merely for appearance.

## 18. Product success signals

Dogfooding records:

- direct replies found that the user had not already noticed;
- median and tail detection latency;
- missed and duplicate notification count (target: zero in deterministic
  replay and observed dogfood evidence);
- branch watches retained versus muted/removed;
- whole-story watches muted because of noise;
- time from opening an Inbox item to identifying parent/branch context;
- revisits to older threads prompted by accurate new-comment state;
- News visits in which the chronological ledger surfaced a worthwhile story
  no longer present at the current rank depth.

These are product observations, not engagement goals. The application does not
optimize time-on-site or notification volume.

## 19. Public v1 acceptance

The release is not complete until all of the following are evidenced:

- a direct reply created after the committed cursor appears once in the correct
  user's Inbox with source, parent, bounded ancestors, root story, and reasons;
- restart/replay across named fault points produces no missed or duplicate
  reply notification;
- a story, direct children of one comment, and a whole descendant branch can be
  watched independently;
- overlapping identity/branch/story matches create one visible record per
  category with all causes attached;
- reopening a thread highlights exactly the comments later than the previous
  rendered cursor and does not advance that marker on live banner arrival;
- News orders by first observed ranked-feed appearance, shows the previous
  visit boundary, and discloses capture precision/freshness;
- History can render a stored capture and a story trajectory without inventing
  missing intervals;
- core public pages and ordinary state-changing forms work with JavaScript
  disabled; passkey and optional live-enhancement boundaries are explicit;
- HN source HTML and unsafe URLs cannot cross the rendering trust boundary;
- application SSE disconnect/reconnect cannot lose durable state;
- private Atom tokens are hashed, revocable, non-indexed, and never logged;
- export/deletion and identity/watch quotas work through real HTTP;
- backup, restore, migration, rollback, and sustained systemd+Caddy operation
  are rehearsed on an isolated release;
- measured resource/freshness/recovery results are published with the exact
  binary, schema, toolchain, dependency pins, and fixture scale.
