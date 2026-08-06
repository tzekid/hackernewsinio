# Data model

Status: proposed logical schema

The first implementation milestone converts this model into ordered SQL
migrations and tests them against the exact pinned local Turso engine. This
document is normative about ownership, identities, uniqueness, and transaction
boundaries; column spelling may change before migration 1 if the meaning is
preserved and the decision is recorded.

## 1. Global conventions

- HN item IDs, cursor values, capture IDs, and event IDs use checked signed
  64-bit integers in storage and non-negative typed values in Zig.
- Times are UTC Unix seconds unless a higher-resolution local duration is
  explicitly needed for measurements.
- Boolean columns are `INTEGER NOT NULL CHECK (value IN (0, 1))`.
- Enum-like text columns have `CHECK` constraints and corresponding Zig enums.
- HN usernames use binary/case-sensitive comparison. They are never lowercased
  for identity matching.
- User-supplied and HN-supplied values are always bound parameters.
- Foreign keys are enabled and tested. Cascades are used only for genuinely
  user-owned projections; shared HN facts do not cascade from account deletion.
- Unknown newer migration versions fail closed.
- Migrations are append-only after release.

## 2. Schema ownership map

```text
shared source facts
  items -> item_content
  feed_captures -> feed_entries -> story_feed_stats
  events

source progress
  ingest_cursors
  ingest_gaps
  background_jobs
  thread_backfills

private application state
  app_users
    -> auth_credentials / auth_challenges / sessions
    -> hn_identities
    -> watches
    -> notifications -> notification_reasons
    -> news_markers / thread_markers / watch_markers
    -> feed_tokens
```

## 3. Migration and runtime metadata

### `schema_migrations`

| Column | Meaning |
| --- | --- |
| `version` PK | Monotonic application schema version |
| `name` | Stable migration name |
| `applied_at` | UTC application time |
| `app_version` | Binary version that applied it |

The primary key prevents reapplication. Startup refuses a database with a
version newer than the binary.

### `runtime_state`

Small typed key/value runtime facts that are not domain events, for example
the instance ID and beginning of authoritative local history. It is not a
generic settings dump. Supported keys are enumerated in code.

## 4. HN items and graph

### `items`

| Column | Constraints/meaning |
| --- | --- |
| `id` PK | Exact HN item ID |
| `kind` | `story`, `comment`, `job`, `poll`, or `pollopt` |
| `author` nullable | Exact case-sensitive HN `by` value |
| `created_at` nullable | HN item time |
| `parent_id` nullable | HN parent for comments/poll options |
| `root_story_id` nullable | Resolved story/poll root |
| `depth` nullable | Checked parent depth from root |
| `score` nullable | Last observed story/poll score |
| `comment_count` nullable | Last observed descendants value |
| `dead` | Last observed dead state |
| `deleted` | Last observed deleted state |
| `graph_state` | `resolved`, `unresolved_parent`, `unresolved_root`, `invalid` |
| `source_revision` | Hash of normalized source fields used for change detection |
| `first_fetched_at` | First successful local fetch |
| `last_fetched_at` | Latest successful local fetch |
| `materialization_reason` nullable | Last reason full content was retained |

Indexes:

- `(parent_id, created_at, id)` for deterministic child traversal;
- `(root_story_id, created_at, id)` for story activity/counts;
- `(author, created_at, id)` using binary collation for backfill/context;
- `(last_fetched_at)` for bounded reconciliation/retention.

`parent_id` is intentionally not a strict immediate foreign key to `items`:
the API can expose a child while its parent is temporarily unavailable. The
graph state/retry contract represents that condition honestly. Once resolved,
application tests enforce parent/root invariants.

### `item_content`

| Column | Constraints/meaning |
| --- | --- |
| `item_id` PK/FK | Materialized item |
| `title_text` nullable | Plain-text decoded title |
| `url` nullable | Canonical validated external URL |
| `source_html` nullable | Bounded original HN text for re-sanitization |
| `safe_html` nullable | Canonical sanitizer output |
| `sanitizer_version` | Code-defined sanitizer contract |
| `source_hash` | Hash of source title/url/text input |
| `safe_hash` | Hash of canonical output |
| `materialized_at` | First/most recent materialization time |

`safe_html` is trusted only when its version is supported and its source/output
relationship was produced by the sanitizer. SQL callers cannot manufacture a
renderer trusted type merely because a string came from this column.

Full content can be deleted by later retention only if no feed entry,
notification context, active watch, thread marker, or retained event requires
it. Graph metadata remains.

## 5. Feed history

### `feed_captures`

| Column | Constraints/meaning |
| --- | --- |
| `id` PK | Monotonic local capture sequence |
| `feed` | `top`, `ask`, `show`, or `job` |
| `captured_at` | UTC start/publication time |
| `depth` | Requested retained depth |
| `entry_count` | Successfully stored entries |
| `source_hash` | Hash of ordered upstream ID list |
| `duration_ms` | Measured capture duration |
| `source_maxitem` nullable | Max item observed near capture |

Unique: `(feed, captured_at)`.

Only complete successful captures appear here. Failed/partial attempts belong
in operational job history so a time gap remains visible.

### `feed_entries`

| Column | Constraints/meaning |
| --- | --- |
| `capture_id` FK | Owning capture |
| `story_id` | HN story/job item |
| `rank` | 1-based rank inside capture |
| `score` nullable | Score observed for this capture |
| `comment_count` nullable | Descendants observed for this capture |

Primary key: `(capture_id, story_id)`.

Unique: `(capture_id, rank)`.

Index: `(story_id, capture_id)` for trajectories.

### `feed_memberships`

Captures Ask/Show/Job membership independently of top rank.

| Column | Meaning |
| --- | --- |
| `capture_id` | Capture-cycle sequence or feed-specific capture |
| `feed` | `ask`, `show`, `job` |
| `story_id` | Story ID |
| `rank` | Rank in that official list |

Primary key: `(capture_id, feed, story_id)`.

This table may be folded into `feed_entries` if implementation uses one capture
header per official list; the meaning and unique rank remain the same.

### `story_feed_stats`

| Column | Meaning |
| --- | --- |
| `story_id`, `feed` PK | Aggregate identity |
| `first_capture_id` | First local capture containing story |
| `last_capture_id` | Latest local capture containing story |
| `first_rank` | Rank at first observation |
| `best_rank` | Minimum observed rank |
| `last_rank` | Latest observed rank |
| `capture_count` | Number of captures containing story |

This is a projection rebuilt from captures in deterministic replay. It is not
the only copy of history.

## 6. Ingestion progress and jobs

### `ingest_cursors`

| Column | Meaning |
| --- | --- |
| `stream` PK | `hn_items` initially |
| `processed_through` | Contiguous stored-or-gap high-water ID |
| `observed_max` | Latest valid max observed |
| `checked_at` | Last successful max check |
| `advanced_at` | Last cursor advancement |

Invariant: `processed_through <= observed_max` except during an explicitly
recorded upstream reset investigation; normal code rejects regression.

### `ingest_gaps`

| Column | Meaning |
| --- | --- |
| `item_id` PK | Missing/failed ID |
| `state` | `retryable`, `dormant`, `resolved` |
| `error_class` | Bounded typed reason such as `null`, `timeout`, `malformed` |
| `first_failed_at` | First failure |
| `last_attempt_at` | Latest attempt |
| `next_attempt_at` | Scheduler eligibility |
| `attempt_count` | Checked bounded counter |
| `resolved_at` nullable | Resolution time |

An unresolved gap is never silently deleted. Index `(state, next_attempt_at,
item_id)` supports the retry queue.

### `background_jobs`

Durable bounded jobs that must resume, initially identity backfill and sanitizer
reprocessing.

| Column | Meaning |
| --- | --- |
| `id` PK | Opaque job ID |
| `kind` | Enumerated job type |
| `owner_user_id` nullable | User owner for private jobs |
| `subject` | Typed bounded subject ID encoded by the owning module |
| `state` | `pending`, `running`, `succeeded`, `failed`, `cancelled` |
| `position` | Next bounded work index |
| `limit_value` | Frozen maximum work for this job |
| `attempt_count` | Attempts |
| `last_error_class` nullable | Bounded diagnostic |
| timestamps | Created/started/updated/finished |

Do not use this as a generic distributed queue. One process claims/executes
known job types, and all state transitions are transactionally checked.

### `thread_backfills`

Durable, globally deduplicated acquisition state for an HN story's bounded
comment tree. This is separate from user-owned `background_jobs`: opening a
public thread may enqueue it, but the HTTP request only renders the stored
snapshot and never waits on Hacker News.

| Column | Meaning |
| --- | --- |
| `story_id` PK | HN root story and deduplication key |
| `state` | `pending`, `running`, `succeeded`, or `failed` |
| `position` | Number of comments materialized by the completed attempt |
| `limit_value` | Frozen maximum comments for the job |
| `attempt_count` | Bounded retry counter |
| `last_error_class` nullable | Typed diagnostic without upstream content |
| timestamps | Created/started/updated/finished |

A process restart resumes `pending` or `running` work. A user may explicitly
retry a failed row by reopening the thread; a succeeded row is not requeued
because the global item cursor handles comments created afterward.

### `job_runs`

Optional operational attempt history for feed captures/reconciliation if M1
shows it is needed to render gaps and diagnose failures. It must remain bounded
by retention and contain no raw HN/user content.

## 7. Application users and authentication

### `app_users`

| Column | Meaning |
| --- | --- |
| `id` PK | Random opaque application user ID |
| `created_at` | Registration completion |
| `deleted_at` nullable | Tombstone only if required for audit/referential safety |

There is no required email, display profile, HN username, role graph, follower
count, or billing state in v1.

### `auth_credentials`

| Column | Meaning |
| --- | --- |
| `credential_id` PK | WebAuthn credential ID bytes/encoded canonical form |
| `user_id` FK | Owner |
| `public_key` | Verified credential public key |
| `algorithm` | Accepted COSE algorithm |
| `sign_count` | Latest verified count |
| `transports` | Validated bounded transport encoding |
| `aaguid` | Authenticator identifier if supplied |
| `backup_eligible`, `backup_state` | WebAuthn flags |
| `label` | User-owned bounded plain text |
| timestamps | Created, last used, revoked |

Index `(user_id, revoked_at, created_at)`.

The last active credential cannot be revoked through the normal settings flow.

### `auth_challenges`

| Column | Meaning |
| --- | --- |
| `id` PK | Random challenge record ID |
| `purpose` | `register`, `authenticate`, `add_credential` |
| `challenge_hash` | Hash of random challenge or exact representation required by verifier |
| `user_id` nullable | Bound owner for authenticated operations |
| `binding_hash` | Request/session/return-route binding |
| timestamps | Created, expiry, used |

Unique/transaction semantics make consumption single-use. Expired/used rows are
pruned under a global and per-session count bound.

### `sessions`

| Column | Meaning |
| --- | --- |
| `token_hash` PK | Hash of opaque cookie token |
| `user_id` FK | Owner |
| `csrf_hash` | Hash of session CSRF secret |
| `created_at`, `last_seen_at`, `expires_at`, `revoked_at` | Lifecycle |
| `label` nullable | Bounded user-readable device/session hint |

Indexes `(user_id, revoked_at, expires_at)` and `(expires_at)`.

Tokens/CSRF secrets are never recoverable from logs or export.

## 8. Tracked identities

### `hn_identities`

| Column | Meaning |
| --- | --- |
| `id` PK | Internal identity relationship ID |
| `user_id` FK | Application owner |
| `username` | Exact API-returned case-sensitive HN ID |
| `private_label` nullable | Optional local label such as `me` |
| `state` | `pending_preview`, `active`, `backfilling`, `error`, `removed` |
| `profile_created_at` nullable | Last public profile creation value |
| `profile_karma` nullable | Last public preview value; not product scoring |
| `added_at`, `removed_at` | Relationship lifecycle |
| `backfill_job_id` nullable | Current/last bounded job |

Unique active relationship: `(user_id, username)` with binary collation.

The table does not say the user owns the HN identity. No global unique
constraint prevents several app users from tracking the same public identity.

## 9. Watches and mutes

### `watches`

| Column | Meaning |
| --- | --- |
| `id` PK | Opaque watch ID |
| `user_id` FK | Owner |
| `scope_kind` | `comment_direct`, `comment_branch`, `story` |
| `scope_item_id` | Comment/story target |
| `root_story_id` | Resolved root at creation |
| `created_item_boundary` | Global cursor at creation |
| `created_event_boundary` | Event max at creation |
| `muted` | Exclude from default counts/live delivery |
| `created_at`, `removed_at` | Lifecycle |

Unique active relationship: `(user_id, scope_kind, scope_item_id)`.

The application verifies the target kind/root before insertion and applies the
per-user active-watch quota in the same transaction.

Story/domain/user filter rules beyond these scopes are deferred rather than
stored in a generic JSON rules table.

### `watch_markers`

| Column | Meaning |
| --- | --- |
| `user_id`, `watch_id` PK | Owner/watch |
| `seen_through_event_id` | Last acknowledged bounded event |
| `rendered_at` | Last advancement time |

Removing a watch cascades its marker and prevents new reasons; prior
notification reasons retain their historical watch ID/text snapshot as needed.

## 10. Events and user projections

### `events`

| Column | Meaning |
| --- | --- |
| `id` PK | Monotonic local event ID |
| `event_key` UNIQUE | Deterministic typed key |
| `kind` | `comment_created`, `item_state_changed`, `feed_first_observed`, `feed_milestone` |
| `source_item_id` nullable | HN item causing event |
| `parent_item_id` nullable | Relevant parent |
| `root_story_id` nullable | Resolved root |
| `relevant_item_id` nullable | Milestone/watch/source-state target |
| `source_revision` nullable | Revision/milestone identifier |
| `occurred_at` | HN item time or feed capture time |
| `detected_at` | Local commit observation time |
| `source_class` | `live`, `gap_retry`, `backfill`, `thread_load`, `reconcile`, `feed_capture` |

Indexes `(kind, detected_at, id)`, `(root_story_id, id)`, and
`(source_item_id, kind)`.

Events are shared public-derived facts and survive account deletion.

### `notifications`

| Column | Meaning |
| --- | --- |
| `id` PK | Opaque/monotonic notification ID |
| `user_id` FK | Owner |
| `event_id` FK | Shared event |
| `category` | `inbox` or `following` |
| `suppressed` | Self/mute policy excluded it from default unread counts |
| `created_at` | Projection time |
| `read_at` nullable | Inbox read state or explicit following state where applicable |
| `dismissed_at` nullable | Optional local dismissal, not source deletion |

Unique: `(user_id, event_id, category)`.

Indexes:

- `(user_id, category, suppressed, read_at, id)`;
- `(user_id, category, id)` for bounded feeds/paging.

### `notification_reasons`

| Column | Meaning |
| --- | --- |
| `notification_id` FK | Owning projection |
| `reason_kind` | `identity_direct`, `identity_story`, `watch_direct`, `watch_branch`, `watch_story` |
| `tracked_identity_id` nullable | Matched identity relationship |
| `watch_id` nullable | Matched watch |
| `relevant_item_id` | Parent/ancestor/root responsible |
| `reason_key` | Stable deterministic key |

Primary key: `(notification_id, reason_key)`.

At least one reason must exist for every non-system notification before the
transaction commits. Rendering computes the causal sentence from typed fields;
there is no opaque reason JSON or pre-rendered HTML.

### Projection overlap

One `comment_created` event may own:

```text
user A / inbox     -> identity_direct
user A / following -> watch_branch + watch_story
user B / following -> watch_story
```

This is one source comment, three user/category projections, and four explicit
causes—not four source events.

## 11. Attention state

### `news_markers`

| Column | Meaning |
| --- | --- |
| `user_id`, `feed` PK | Account/feed marker |
| `seen_through_capture_id` | Previous successful News view boundary |
| `rendered_at` | Advancement time |

The anonymous equivalent is a bounded host-only cookie for the default News
ledger and does not create a database user/session.

### `thread_markers`

| Column | Meaning |
| --- | --- |
| `user_id`, `root_story_id` PK | Account/thread |
| `seen_through_item_id` | Global committed item cursor at last successful view-model construction |
| `rendered_at` | Advancement time |

This marker defines “new comments” and is not a stored scroll position. Saved
positions/collapse state are deferred.

### Notification read state

Inbox read state remains on `notifications` because it is per notification.
Following acknowledgment remains on `watch_markers` because it is an aggregate
through a stable event boundary.

## 12. Private Atom feed tokens

### `feed_tokens`

| Column | Meaning |
| --- | --- |
| `id` PK | Internal token record ID |
| `token_hash` UNIQUE | Hash of bearer token |
| `user_id` FK | Owner |
| `scope` | `inbox` or `following` |
| `label` | Bounded user-owned label |
| `created_at`, `last_used_at`, `revoked_at` | Lifecycle |

Raw tokens are shown only once at creation. Token path values are redacted from
application and proxy logs. Reading a feed does not change read/watch markers.

## 13. Deliberately absent tables

v1 does not create:

- ancestry closure/materialized path for every comment;
- external delivery outbox or delivery-attempt rows;
- mention detection;
- generalized filter/rules JSON;
- social profiles/follows;
- mirrored articles;
- search vectors/embeddings;
- client synchronization log;
- separate raw event-bus payload table;
- passkey recovery email state;
- cloud replication state.

These are added only with a concrete feature and transaction/retention
contract.

## 14. Transaction boundaries

### 14.1 Item reduction

Atomic:

```text
item graph/content upsert
+ source event insert
+ per-user notification upsert
+ reason inserts
+ resolved gap update, when applicable
```

The numeric batch cursor advances only after every item in the batch has one of
the required terminal local representations.

### 14.2 Feed capture

Atomic:

```text
capture header
+ all ranked entries/memberships
+ story aggregate updates
+ first/milestone events
```

A partial capture never becomes queryable as complete history.

### 14.3 Identity creation

Atomic:

```text
quota check
+ exact identity relationship
+ bounded backfill job at frozen limit
```

Network profile preview occurs before this transaction and is revalidated at
confirmation if stale.

### 14.4 Watch creation

Atomic:

```text
target/root validation from stored graph
+ quota check
+ watch with current item/event boundaries
+ initial watch marker
```

### 14.5 Auth completion

Atomic:

```text
single-use challenge consumption
+ user/credential mutation
+ session issuance/rotation
```

### 14.6 Account deletion

Atomic where supported in a bounded transaction:

```text
revoke sessions/credentials/tokens
+ delete identities/watches/markers/notifications/reasons
+ delete or tombstone app user
```

If row volume exceeds the bounded transaction limit, registration quotas should
make that a design defect. Do not silently convert deletion into an untracked
eventual job.

## 15. Deterministic projection checks

The replay harness produces a canonical, PII-free projection report containing:

- table row counts;
- schema/index/constraint inventory;
- cursor/max/gap state;
- ordered event keys;
- notification `(synthetic-user, event-key, category)` keys;
- ordered reason keys;
- feed capture/entry aggregate hashes;
- marker boundaries;
- hashes of sanitized fixture output, not source bodies.

Running the same fixture on a fresh database, twice on one database, and across
forced restarts must produce the same report. This is stronger evidence than
asserting only that no SQL error occurred.

## 16. Retention and compaction

Initial policy:

- keep graph metadata, source events, and feed captures needed for the product
  promise;
- keep materialized content referenced by retained context/watches/history;
- expire sessions/challenges and resolved operational job detail on short
  documented schedules;
- keep private user state until explicit deletion;
- record daily storage growth before adopting content/capture compaction.

Any later compaction migration must prove, against a copied database, which
public pages and event explanations remain byte/semantically equivalent. It
must not make old notifications inexplicable or relabel rolled-up history as
exact five-minute captures.

## 17. Required schema tests

- fresh migration and reopen;
- applying every migration twice is rejected/no-op according to the migration
  runner contract;
- newer schema fails closed;
- case-sensitive identity uniqueness/matching;
- item parent can be unresolved then resolved;
- event, notification, and reason duplicate constraints;
- overlapping watch/identity reasons;
- self-activity suppression without event loss;
- watch/identity/session/passkey/feed-token quotas under concurrent attempts;
- account deletion removes every private join but leaves shared facts valid;
- borrowed rows are copied before another execution/lease release;
- failed transaction leaves cursor/marker unchanged;
- feed capture is all-or-nothing;
- backup/restore preserves constraints, counts, hashes, cursor, and sanitizer
  versions under the pinned Turso engine.
