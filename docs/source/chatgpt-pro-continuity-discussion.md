# Source discussion: Hacker News continuity client

Captured locally: 2026-08-04

Provenance: text supplied by the repository owner from an earlier ChatGPT Pro
conversation.

This file preserves the source discussion as supplied. It is non-normative and
contains estimates, product references, and version statements that may age.
The reviewed project contract is in `../SPEC.md` and the verified source/stack
notes are in `../STACK-RESEARCH.md`.

---

# Verdict

Build it, but frame it as a Hacker News continuity client, not merely “Hacker News with reply notifications.”

The product promise should be:

A server-rendered Hacker News client that remembers where you were and tells you exactly what changed since you left.

That combines three related problems:

1. Discovery continuity: Which worthwhile stories appeared while I was away?
2. Conversation continuity: Did anyone reply to me or continue a branch I care about?
3. Reading continuity: What is new inside a thread I already opened?

This is stronger than “another HN frontend,” and it fits your broader project story unusually well: you would be making hidden state—front-page appearances, reply relationships, branch activity, and personal reading state—explicit and inspectable.

## Why notifications alone are not enough

hckrnews already has a strong product insight: chronological presentation is often more useful than the volatile ranked homepage. Its creator describes the original problems as missing stories when not visiting regularly and not knowing what is new when visiting frequently. Its browser extension also experimented with highlighting comments added since a previous visit.

HN itself has the manual threads?id=username route, but that is not a real notification system. It has no durable unread inbox, delivery mechanism, branch subscriptions, or unified “since I left” model. Existing products have also begun filling the obvious notification gap: HNswered provides a local reply inbox, while Hacki and Gem include reply notifications and new-comment highlighting.

Therefore, the differentiator should not be:

“I notify you when someone replies.”

It should be:

“I preserve the continuity of your relationship with Hacker News.”

## The conceptual model: three ledgers

A useful way to design the application is as three small, interlocking ledgers.

### 1. The news ledger

This records when stories appeared in the relevant feeds:

* First appearance on the HN homepage
* First rank and best rank
* Last appearance
* Score and comment count at each snapshot
* Whether it reached the top 10, top 20, first page, Ask HN, Show HN, and so on

This produces the hckrnews-style chronological view and eventually supports a front-page time machine.

### 2. The conversation ledger

This records meaningful public events:

* Comment B directly replied to comment A
* Comment C was added to story S
* A watched branch received another descendant
* A watched comment was edited or deleted
* A tracked user submitted something new

Every notification should contain a causal explanation:

You received this because comment 48123456 replies to comment 48120111, authored by your_username, under story 48110000.

That traceability is part of the product, not merely debugging information.

### 3. The attention ledger

This records what the application user has already consumed:

* Last story-feed snapshot viewed
* Last comment ID seen in each thread
* Inbox notifications opened or dismissed
* Stories and branches followed
* Muted stories, users, domains, or notification classes
* Saved reading position or collapsed branches

This is the ledger most existing HN interfaces lack.

## Recommended information architecture

| Screen | Purpose |
| --- | --- |
| News | Chronological homepage history, hckrnews-style filters, and a clear “new since your previous visit” boundary |
| Inbox | Direct replies and comments on the user’s own submissions, presented with conversational context |
| Following | Watched stories and individual branches, ordered by meaningful activity rather than raw age |
| Thread | Server-rendered comment tree with new-comment highlighting, branch collapse, focus mode, and follow controls |
| History | Front-page timeline, rank history, and optional time-machine view |
| Settings | Tracked HN identities, notification channels, filters, muting, retention, and application account settings |

The interface should remain recognizably HN-like: information-dense, textual, quick, and keyboard-friendly. It should not become a generic card-based social feed.

## Primary user journeys

### 1. Anonymous reading

The first request returns a complete server-rendered chronological feed.

The user can:

* Open stories and comment threads
* Filter to top 10, top 20, Ask HN, Show HN, Jobs, or all homepage stories
* See which entries are newer than their previous visit
* Collapse previously read items
* Use j and k navigation as an enhancement

No account and no JavaScript are required for the basic experience.

### 2. Tracking an HN identity

The user enters an HN username. The application fetches the public profile and shows a preview to reduce mistakes.

This must be worded as “track this identity”, not “log in to HN.” Entering a public username does not prove ownership. That is acceptable because all the relevant HN activity is public.

For cross-device state, the user creates a separate application account using a passkey or magic link. The application should never request the user’s HN password.

### 3. Receiving a direct reply

The user writes a comment on native Hacker News.

Later, a new HN comment appears whose parent points to that comment. The application detects the relationship, creates an idempotent notification, and updates any connected browser sessions.

The inbox entry should show:

* The story title
* “You wrote”
* The new response
* Enough ancestors to understand the context
* Actions for opening the complete branch, marking read, muting the thread, and opening native HN to respond

The user should not need to reconstruct the conversation from an isolated reply.

### 4. Following one branch instead of an entire thread

This is one of the most useful differentiators.

Large HN threads often contain multiple unrelated conversations. Following the whole story creates noise. The user should be able to follow:

* Direct replies only
* A specific comment and all descendants beneath it
* The entire story
* A tracked user’s activity inside that story

A watched branch receives a compact status such as:

6 new comments: 2 in the branch you followed, 1 direct reply, 3 elsewhere in the story.

### 5. Returning after several hours or days

The landing dashboard should answer, in order:

1. Did anyone reply directly to me?
2. Did a branch I explicitly followed change?
3. Did a previously visited story receive substantial new discussion?
4. Which front-page stories appeared while I was away?

That ordering is much better than mixing every event into one chronological notification stream.

## Notification semantics

Define the terms precisely before implementation.

| Event | Exact trigger | Default treatment |
| --- | --- | --- |
| Direct reply | New comment’s parent is a comment authored by the tracked identity | Inbox notification |
| Comment on my story | New comment’s parent is a story authored by the tracked identity | Inbox notification |
| Branch update | A watched comment occurs anywhere in the new comment’s ancestor chain | Following update, optionally push |
| Story update | New comment’s root story is watched | Aggregated following update |
| Front-page appearance | Story appears inside the configured homepage depth for the first time | News timeline only |
| Front-page milestone | Story crosses a configured rank such as top 10 | Optional following update |
| Mention | Comment text appears to mention a username | Experimental, off by default |
| Edit or deletion | Previously stored watched item changes state | Quiet status update unless materially relevant |

Mentions are inherently unreliable because Hacker News does not expose a structured mention relation. Treating @username as authoritative would create false positives.

“Unread” should also be explicit:

* Opening one inbox item marks that notification read.
* Opening a thread stores the highest item ID included in that rendered snapshot.
* Comments with later IDs are highlighted next time.
* New comments arriving while the page is open do not silently move the marker.
* “Mark thread seen” is available as an explicit action.

## Why the HN data model is favorable

The official Firebase API exposes precisely the relationships needed:

* Comments have parent
* Stories and comments have kids
* User profiles have submitted
* Items have stable IDs and authors
* /maxitem exposes the latest item ID
* /updates exposes recently changed items and profiles
* The data is documented as near real time and supports change events

That means direct-reply detection is deterministic:

```text
new comment
    └── parent item
          ├── parent.by == tracked username
          └── parent.type == comment or story
```

You do not need text classification or an LLM for the core feature.

## Detection strategies

There are three viable approaches.

| Strategy | How it works | Advantages | Disadvantages |
| --- | --- | --- | --- |
| Per-user polling | Poll the user’s submitted list, track their recent items, and periodically inspect each item’s kids | Very small initial implementation; excellent for personal dogfooding | Upstream work increases with users and authored items; detection is delayed |
| Global cursor | Observe /maxitem, fetch every newly allocated item, resolve each comment’s parent, and match against tracked identities | Work is largely independent of user count; detects new replies naturally | Requires a reliable ingestion cursor, parent caching, and recovery logic |
| Hybrid | Global cursor for live events, user-specific backfill during onboarding, and /updates reconciliation | Best correctness and scaling characteristics | More components than the smallest possible prototype |

### Recommendation

Use per-user polling for the first data spike, then move directly to the hybrid model for the public application.

The onboarding backfill can remain user-centric:

1. Read the profile’s submitted list.
2. Fetch recent authored comments and stories.
3. Inspect their direct kids.
4. Insert already-existing replies into the inbox.
5. Record the latest global cursor.
6. Let global ingestion handle future events.

HN normally closes commenting on threads after approximately two weeks, which gives you a naturally bounded set of recent authored items to inspect during the simple polling phase.

## Recommended architecture

Use one Zig service initially. Keep it modular, but do not split it into deployable microservices.

```text
                      Hacker News Firebase API
                         │              │
                   maxitem stream    feed snapshots
                         │              │
                         ▼              ▼
                 ┌──────────────────────────┐
                 │     HN source adapter    │
                 └────────────┬─────────────┘
                              │
                    bounded fetch pipeline
                              │
                              ▼
                 ┌──────────────────────────┐
                 │ item normalizer + graph  │
                 │ parent/root resolution   │
                 └────────────┬─────────────┘
                              │
                              ▼
                 ┌──────────────────────────┐
                 │ deterministic event      │
                 │ matcher / reducer        │
                 └────────────┬─────────────┘
                              │
                              ▼
                 ┌──────────────────────────┐
                 │ SQLite                   │
                 │ state + event outbox     │
                 └───────┬──────────┬───────┘
                         │          │
                    SSR routes    delivery worker
                         │          │
                   HTML/htmx    SSE / Push / Atom
```

## HN ingestion loop

The live path should work as follows:

1. Subscribe to changes to /v0/maxitem.json.
2. When the maximum rises from N to M, schedule all IDs from N + 1 through M.
3. Fetch with bounded concurrency.
4. Normalize each item.
5. For comments, fetch or load the parent.
6. Resolve the root story by walking cached parents.
7. Evaluate notification and watch rules.
8. Commit the item, derived events, notifications, outbox rows, and cursor progress idempotently.
9. Publish newly committed notifications to connected application clients.

Firebase’s REST interface supports Server-Sent Events by requesting text/event-stream; its documentation also notes that clients must follow temporary redirects. That allows the Zig backend to consume live changes without requiring a Firebase SDK.

Still keep a slow polling watchdog. An SSE connection is a latency optimization, not your only correctness mechanism.

## Cursor correctness

Do not merely store “last number observed.”

Maintain a contiguous high-water mark:

* Advance it only after all preceding item IDs are stored or deliberately marked as tombstones.
* Retry temporary null or failed responses.
* Allow a permanent tombstone after a defined retry policy.
* Use unique constraints so replaying a batch cannot duplicate events.
* On restart, resume from the committed high-water mark.

This produces at-least-once fetching with effectively-once database effects.

## Reconciliation

The global item stream detects new objects. A periodic reconciliation task should inspect /updates for:

* Edited comments
* Deleted or dead items
* Changed story scores
* Changed descendant counts
* Profile changes relevant to tracked identities

Notifications should not silently vanish if their source is later deleted. Preserve the event and render the source as deleted.

## Feed snapshotter

The API exposes current story lists, not historical front-page appearances. Your application must create that history itself.

At a fixed interval:

1. Fetch the current ranked story list.
2. Select the configured homepage depth.
3. Store each story’s rank, score, comment count, and snapshot time.
4. Update first_seen, best_rank, and last_seen.
5. Emit milestone events when appropriate.

Do not try to reconstruct exact historical homepage membership purely from story creation timestamps. Start the authoritative ledger when your service launches, with any earlier history clearly marked as imported or approximate.

## SQLite data model

SQLite in WAL mode is sufficient for the initial and likely medium-scale product. It also gives the project an attractive deployment shape: one binary, one database, no Redis, and no message broker.

| Table | Important fields |
| --- | --- |
| items | id, type, author, created_at, parent_id, root_story_id, title, url, text_html, dead, deleted, fetched_at |
| story_snapshots | story_id, captured_at, feed, rank, score, comment_count |
| story_appearances | story_id, feed, first_seen_at, last_seen_at, first_rank, best_rank |
| app_users | Application identity and preferences |
| hn_identities | app_user_id, exact HN username, tracking state |
| watches | user_id, scope_type, scope_id, notification mode, mute state |
| events | Normalized event type, source item, parent, root story, occurrence time |
| notifications | User, event, reason, read state, delivery state |
| thread_markers | User, root story, previous snapshot item ID and timestamp |
| ingest_cursors | Stream name, contiguous high-water mark, check time |
| delivery_outbox | Notification delivery attempts for push, email, or feeds |
| sessions | Application session and authentication state |

Critical uniqueness constraints include:

```text
events(kind, source_item_id, relevant_parent_id)
notifications(user_id, event_id, reason)
story_snapshots(story_id, feed, captured_at)
```

For branch subscriptions, start by walking the parent chain when a new comment arrives. Cache the resolved path. A closure table is unnecessary until measurement proves the parent walk is material.

## SSR and htmx 4 design

Your chosen frontend model fits this application well.

### Baseline behavior

Every meaningful route returns complete HTML:

* Feed browsing
* Thread rendering
* Inbox
* Following
* Mark read
* Follow or unfollow
* Mute
* Filter changes

Forms and links should remain functional without JavaScript. htmx then enhances those same endpoints.

A handler can construct one view model and choose between:

* Full document with layout
* Fragment response for an htmx request
* 304 Not Modified when the fragment state has not changed

### Live updates

Use one application SSE connection for small state changes:

* New reply count
* New inbox row
* “8 new comments” thread banner
* Followed-story activity count

Do not push an entire changing comment tree into the browser. When activity arrives, show a small banner and let the user request a deterministic server-rendered delta or refreshed branch.

### htmx 4-specific opportunities

The official htmx 4 documentation currently still presents v4 as beta and identifies the documented build as 4.0.0-beta6. Pin the exact vendored build rather than following an unversioned CDN URL.

Two features are especially relevant:

* hx-sse for receiving server-rendered notification fragments over SSE
* hx-ptag for attaching a server-issued state tag to a polling element; the server can return 304 when nothing changed, causing no DOM swap and almost no response body

That maps directly to your desired behavior:

```html
<section
  hx-get="/fragments/news-since-last-visit"
  hx-trigger="every 60s"
  hx-ptag="feed:2026-08-04T12:00:00Z:48123456">
  ...
</section>
```

The correctness of the client must not depend on experimental htmx behavior. A normal reload should always produce the same authoritative state.

### Native HTML before custom JavaScript

Use:

* `<details>` for branch collapse
* `<time>` for timestamps
* `<mark>` for new comments
* Real links and forms
* Sticky but unobtrusive thread navigation
* CSS counters or server-rendered counts
* Small optional keyboard-navigation script

The application does not need a client-side state store, virtual DOM, hydration, or JSON API for its own frontend.

## Security and privacy boundaries

The documented HN API is public-data and read-oriented. Make native posting, editing, and voting non-goals for the first version.

The application should:

* Never receive or proxy HN credentials
* Deep-link users to native HN for replies, votes, and account actions
* Treat tracked usernames as public watches, not verified ownership
* Use a separate passkey or magic-link account for private application state
* Sanitize HN-provided HTML through a strict allowlist
* Permit only expected URL schemes
* Use a restrictive Content Security Policy
* Protect application writes against CSRF
* Allow export and deletion of user-specific application state
* Treat private Atom-feed tokens and Web Push subscriptions as credentials

HN has published multiple historical content-escaping and XSS-related security incidents, so upstream HTML should not be treated as intrinsically safe merely because it came from Hacker News.

Also avoid an AI comment-writing feature. The current HN guidelines explicitly prohibit generated and AI-edited text in submissions and comments. A private, read-only thread summary could potentially be explored later, but comment generation would directly conflict with the community’s rules and with the product’s human-conversation premise.

## Recommended implementation roadmap

The estimates below are focused development days, assuming heavy LLM assistance but still allowing for product design, testing, and failure handling.

| Phase | Approx. effort | Deliverable and exit criterion |
| --- | --- | --- |
| 0. Product contract and data spike | 1–2 days | Five-screen prototype, captured HN fixtures, precise notification semantics, and a synthetic direct reply correctly classified |
| 1. News ledger | 2–3 days | HN source adapter, SQLite migrations, ranked-feed snapshots, chronological SSR feed, filters, and previous-visit boundary |
| 2. Conversation inbox | 3–4 days | Username tracking, onboarding backfill, direct-reply matching, contextual inbox, read/unread state, and duplicate-safe restart |
| 3. Thread continuity | 3–5 days | Thread rendering, seen markers, new-comment highlighting, story watches, branch watches, mute controls |
| 4. Live delivery and polish | 2–4 days | Application SSE, htmx fragments, optional Web Push or private Atom feed, keyboard navigation, accessibility pass |
| 5. Portfolio release | 3–5 days | Replay harness, fault tests, measurements, self-hosting documentation, architecture essay, polished public demo |

A usable personal dogfood version should exist after phases 0–2: roughly 6–9 focused days. A credible public release is more realistically 14–23 focused days.

## Validation before broadening the scope

### Prototype only the important states

Create five screens in Figma or static HTML:

1. Chronological feed after a three-day absence
2. Inbox containing a direct reply
3. Inbox item expanded with parent and ancestor context
4. Large thread with 14 new comments and one watched branch
5. Following page with several levels of activity

The design question is not primarily visual. It is whether the hierarchy makes the right information obvious.

### Dogfood against your own HN identity

Track:

* How often the client finds a reply you would otherwise have missed
* Detection latency
* Missed or duplicate notifications
* How often whole-story follows become noisy
* How often branch follows are useful
* Time from opening a notification to understanding its context
* Whether “new comments since last visit” changes how often you return to older threads

The key validation is whether users value continuity, not merely the novelty of receiving a notification.

### Reliability test matrix

At minimum, cover:

* Direct reply to a comment
* Top-level comment on the user’s story
* Self-reply
* Duplicate item delivery
* Deleted parent
* Deleted reply
* Missing parent during initial fetch
* Very deep ancestry
* Branch and story watches overlapping
* SSE disconnect and reconnect
* Temporary Firebase redirect
* Maximum item ID jumping by a large amount
* Process crash after fetch but before commit
* Process crash after commit but before delivery
* HTML full-page and htmx-fragment semantic equivalence
* Case-sensitive HN usernames

A deterministic replay test should feed the same captured HN event sequence through the matcher repeatedly and produce the same database projections every time.

## Portfolio-grade differentiators

### 1. Front-page archaeology

Once you have accumulated snapshots, provide:

* A front-page time machine
* Story rank trajectories
* Time to enter the top 10
* Score and discussion velocity
* “Stories that appeared while you were gone”
* Late-blooming stories that became active many hours later

Render small SVG trajectories on the server. No charting framework is necessary.

### 2. Branch-level subscriptions

Most systems understand a story or a direct reply. Treating one comment subtree as a first-class subscribable object is substantially more interesting.

This is both a better product feature and a good demonstration of graph traversal, derived state, and restrained notification design.

### 3. Explainable personal filters

Let users define transparent rules such as:

```text
include domain = github.com
include title contains "Zig"
mute author = example
mute story after 50 unread comments
prioritize Ask HN
```

Every filtered item should be able to answer “why was this shown?” or “why was this hidden?” Avoid an opaque engagement recommender.

### 4. Private Atom or RSS feeds

Generate tokenized feeds for:

* Direct replies
* Followed branches
* Followed stories
* Personalized news filters

That gives the product useful delivery without immediately implementing email infrastructure or native applications.

### 5. Deterministic replay and event provenance

The most persuasive technical demonstration would be:

1. Replay several hours of captured HN items at accelerated speed.
2. Watch front-page appearances and replies materialize.
3. Stop the service during ingestion.
4. Restart it.
5. Show that no event was missed or duplicated.
6. Open a notification and inspect exactly why it exists.

That says far more about engineering quality than a synthetic “Zig rendered this page in 40 microseconds” headline.

### 6. A genuinely small deployment

A strong deployment target would be:

```text
one Zig binary
one SQLite database
one asset directory
one systemd unit or container
no Node runtime
no Redis
no external job queue
```

Later, libSQL/Turso replication could be introduced if multi-region reads become useful, but it is not necessary for the initial architecture.

### 7. Measured performance rather than theoretical speed

Zig rendering speed will probably not be the meaningful bottleneck. HN network latency, parent resolution, SQLite queries, and browser transfer will dominate.

Measure and publish:

* Process startup time
* Idle memory
* Database growth per day
* Ingestion lag
* Notification detection latency
* Full-page SSR p50, p95, and p99
* Fragment render and response sizes
* Number of active SSE clients
* Replay throughput
* Recovery time after simulated outage

The portfolio claim should be predictable resource use and operational simplicity, not “nanosecond rendering” without evidence.

## Features to defer deliberately

Do not include these in the first public version:

* HN password handling
* Programmatic commenting or voting
* Native mobile clients
* General Reddit/Lobsters/Slashdot aggregation
* AI-generated comments
* Vector search or personalized embeddings
* Full article mirroring
* Social profiles and follower counts
* Redis, Kafka, or separate ingestion services
* A notification for every new comment in every followed thread
* Complex recommendation scoring

An optional browser extension could come later. Its useful role would be modest: add “Track in HN Continuity” controls to native HN or hckrnews pages and deep-link back to the application. It should not automate actions through the user’s HN session.

## Concrete recommended v1

### Working description

A chronological, server-rendered Hacker News client with a durable reply inbox and exact new-comment tracking for stories and individual branches.

### Stack

* Zig service
* SQLite in WAL mode
* Official HN Firebase API
* /maxitem SSE plus polling watchdog
* Ranked-feed snapshots
* Server-rendered HTML
* htmx 4 for fragments and application SSE
* Minimal handwritten JavaScript for optional keyboard interactions
* Passkeys or magic links for application accounts
* Native HN for posting and voting

### Five required screens

* News
* Inbox
* Following
* Thread
* Settings

### Release acceptance criteria

* A direct reply becomes visible without manually refreshing HN.
* Every notification includes original comment, reply, ancestors, and root story.
* Restarting ingestion produces no missed or duplicated notifications.
* A story and an individual branch can be followed independently.
* Reopening a thread highlights exactly the comments added since the previous rendered snapshot.
* The news feed records first homepage appearance rather than merely sorting stories by submission time.
* Core browsing and state-changing forms work with JavaScript disabled.
* The public project includes replay tests, failure tests, and measured resource usage.

The central design decision is to model attention and continuity, not just HN content. That is what turns the idea from a familiar client clone into a distinctive product and a credible portfolio project.
