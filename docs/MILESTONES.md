# Implementation milestones

Status: proposed

The milestone order protects the product contract from being buried under auth,
live delivery, or visual polish. A later milestone may begin only when the
earlier exit criteria have concrete evidence.

Effort ranges are rough focused-development planning ranges, not commitments.
They include design, failure handling, and verification—not only the happy-path
code. The total public-v1 range is approximately **24–40 focused days** from the
current documentation-only repository. The original 14–23 day estimate is
possible only by dropping some stated passkey, sanitizer, crash-recovery,
history, or deployment acceptance.

## Release map

| Milestone | Outcome | Rough range |
| --- | --- | --- |
| M0 | Exact stack, product states, source/storage/security viability | 2–4 days |
| M1 | Deterministic HN adapter, graph, cursor, reducer, and replay core | 4–6 days |
| M2 | News ledger and public server-rendered News/History | 3–5 days |
| M3 | Passkey account, identity backfill, and durable Inbox | 4–7 days |
| M4 | Thread markers, branch/story watches, and Following | 5–8 days |
| M5 | App SSE, private Atom, accessibility and interaction completion | 3–5 days |
| M6 | Release/operations qualification and public handoff | 3–5 days |

The first genuinely useful personal dogfood build is the end of M3. M2 is a
useful public chronological reader, but it has not yet proved conversation
continuity.

## Verification doctrine

The preferred evidence order is:

1. real-process end-to-end journeys using the real database and HTTP server;
2. integration tests at the source/store/protocol boundaries;
3. focused unit/fuzz tests for pure parsers, escaping, matching, and markers.

Browser acceptance is added only for behavior an HTTP harness cannot prove:
JavaScript-disabled rendering, WebAuthn, CSP/runtime errors, HTMX replacement,
focus, and SSE reconnect. It stays narrow. The project does not collect broad
smoke tests, add a generic frontend framework, or introduce CI/npm metadata by
default.

Before invoking a custom Zig step, inspect the implemented build graph with
`zig build -l`. Step names below are target contracts and do not exist until the
milestone implements them.

## M0. Product and stack viability

### Outcome

Turn the prose into a buildable, measured foundation and resolve the few risks
that would otherwise force a rewrite: exact compiler/dependencies, local Turso
ownership, HN SSE/redirect parsing, sanitizer safety, and information hierarchy.

### Work

1. Initialize the repository deliberately and preserve this documentation.
2. Pin the exact Zig build in `.zigversion` plus official archive checksums.
3. Pin immutable `web.zig` and `turso.zig` revisions/package hashes; pin HTMX
   `4.0.0-beta6`, Passcay, and zbor only when first used.
4. Prove both Turso source and supported prebuilt-system linkage on the target
   Linux platform.
5. Build the process-scoped database + fixed pool ownership spike and exercise
   concurrent bounded reads/writes, graceful shutdown, and forced termination.
6. Implement a loopback fake HN server that can emit exact item/user/feed JSON,
   Firebase SSE envelopes, `307`, disconnect, null, malformed, and delayed
   responses.
7. Check in minimal synthetic fixtures shaped like observed HN data. Avoid
   copying real comment prose where structure alone is sufficient.
8. Spike the strict HN HTML tokenizer/rewriter against documented/observed tag,
   entity, malformed, URL, and hostile inputs.
9. Reproduce the five accepted mobile views from `docs/DESIGN.md` in static
   semantic HTML at 375px and 390px. Keep the fixtures suitable for later
   renderer acceptance; do not start another visual exploration.
10. Record baseline binary size, startup, idle RSS, pool behavior, and cold/warm
    dependency build cost.

### Definition of done

- [ ] A clean checkout installs/verifies the exact compiler and resolves no
      moving dependency branch/CDN.
- [ ] `zig build -Doptimize=Debug` and ReleaseSafe build a minimal real binary.
- [ ] Source and system Turso linkage each pass fresh-file, transaction,
      reopen, contention, crash, and owner-destruction checks.
- [ ] The HN adapter receives a live JSON response and initial maxitem SSE event
      through the same parsing path as the fixture server.
- [ ] Redirect/disconnect/null/malformed fixtures are classified under bounds.
- [ ] Sanitizer fixtures prove no source tag/attribute/URL can cross the trusted
      renderer boundary unless explicitly allowed.
- [ ] The five screen states match the accepted mobile hierarchy, tokens,
      new/unread language, watch levels, and no-JavaScript actions at 375px and
      390px without horizontal page scrolling.
- [ ] Candidate performance/storage budgets are based on measurements.
- [ ] D03 is revisited if the Turso spike misses a named gate; there is no
      fallback driver hidden in the implementation.

## M1. Durable source, graph, event, and replay core

### Outcome

Given a deterministic sequence of HN max/item/user/update envelopes, build the
same graph, events, gaps, cursors, notifications, and reasons through any replay
or restart.

### Work

1. Implement migrations for source/progress/event tables and the connection
   lease contract.
2. Implement bounded typed HN JSON normalization and conditional content
   materialization.
3. Implement maxitem SSE supervisor plus ordinary polling watchdog.
4. Implement fixed contiguous batches, durable gaps, retry scheduling, and
   processed-through cursor advancement.
5. Implement iterative parent/root resolution with cycle/depth/fetch bounds.
6. Implement the pure matcher and transactionally coupled item/event/projection
   reducer using synthetic users/identities/watches.
7. Implement `replay`, canonical projection report, and named fault injection
   points.
8. Implement `/updates` reconciliation for materialized fixture items and state
   revision events.
9. Measure replay throughput, cursor catch-up, graph/content bytes per item, and
   database contention.

### Definition of done

- [ ] Normal item, comment, story, job, poll, poll option, deleted/dead, absent
      optional field, additional unknown field, and malformed required field
      fixtures are classified correctly.
- [ ] Direct reply to comment, comment on tracked story, self-reply,
      direct/branch/story watch, and overlapping matches produce the exact
      event/projection/reason model in `DATA_MODEL.md`.
- [ ] Duplicate delivery and repeated complete replay do not change the
      canonical projection report.
- [ ] Missing parent, deleted parent, deep ancestry, invalid cycle, temporary
      null, and older gap resolution are visible and recoverable.
- [ ] A large max jump remains within configured fetch/queue/memory bounds.
- [ ] Forced crashes before transaction, during transaction, after commit, and
      before batch cursor advancement recover without missed/duplicate effects.
- [ ] `/updates` state changes are observed, while the non-durable-edit
      limitation remains documented and tested as a limitation, not hidden.
- [ ] Debug and ReleaseSafe real-process replay gates pass on isolated temp
      databases.

## M2. News ledger and public SSR

### Outcome

Serve a useful no-account chronological News experience based on locally
observed ranked-feed history, plus an inspectable History view.

### Work

1. Implement complete feed capture publication, membership lists, aggregates,
   milestones, stale/failure status, and scheduler lifecycle.
2. Implement public HTTP listener, explicit route table, embedded asset
   registry, security headers, and health/readiness.
3. Implement typed News and History view models/renderers using `web.zig`.
4. Implement rank/Ask/Show/Job filters, stable cursor paging, freshness and
   observation-precision copy.
5. Implement account marker schema plus bounded anonymous News marker cookie.
6. Implement stored capture time-machine page and accessible story trajectory
   table/SVG.
7. Add ETag/conditional GET where semantics are fixed and prove complete
   first-response state with no startup request.
8. Add the first real-process HTTP journey: fake HN captures -> News/History
   HTML -> restart -> same history/marker semantics.

### Definition of done

- [ ] A story is ordered by first observed configured-feed appearance, not HN
      submission time.
- [ ] Top 10/top 20/Ask/Show/Jobs filters use stored rank/membership evidence.
- [ ] The previous-visit boundary uses prior marker state and the page clearly
      says “new since previous visit,” not “unread.”
- [ ] A failed/partial capture never appears complete; stale/gap state is
      visible while stored pages remain usable.
- [ ] A selected capture renders exactly its stored ranks/count samples; a
      trajectory renders first/best/last and reappearance without interpolation.
- [ ] Public News, History, and bounded thread shell are complete with
      JavaScript disabled and have no same-origin first-view data waterfall.
- [ ] Security headers, URL escaping, HN sanitized content, cache validators,
      HEAD/method handling, body/target bounds, and 404/5xx pages pass real HTTP.
- [ ] Measured capture storage growth informs a retained/changed policy; no
      speculative compactor is added.

## M3. Passkey accounts, identity backfill, and Inbox

### Outcome

An application account can track an exact public HN identity and receive one
durable, contextual direct-reply notification without handling HN credentials.

### Work

1. Implement app user, Passcay/zbor credential, challenge, session, CSRF, and
   quota migrations/services.
2. Implement passkey registration, authentication, second credential,
   rename/revoke, session list/revoke, logout, and safe return-route handling.
3. Implement Settings full HTML and the small WebAuthn JavaScript boundary.
4. Implement exact case-sensitive HN identity preview/confirmation/removal.
5. Implement bounded durable onboarding backfill with progress/restart.
6. Connect identity direct/story matching to Inbox projections and materialize
   bounded parent/ancestor/root context.
7. Implement Inbox list/detail, explicit open/read/unread/bounded read-all, and
   source deleted/dead state.
8. Implement exact-Origin, CSRF, form/body/field, session-token hashing, and
   restrictive CSP/cookie policy.
9. Add real-process HTTP and narrow virtual-authenticator browser journeys.

### Definition of done

- [ ] UI consistently says tracking a public identity is not HN login or
      ownership verification.
- [ ] Username matching is case-sensitive and stores the exact API-returned ID.
- [ ] Backfill freezes and displays its 500-ID maximum, resumes after restart,
      and deduplicates against global ingestion.
- [ ] A synthetic/live-safe direct reply and top-level comment on tracked story
      appear once with exact parent/ancestors/root/reasons and detection/source
      times.
- [ ] A self-reply records the event but is suppressed from default unread
      counts.
- [ ] Rendering Inbox does not mark items read; the open POST marks exactly the
      authorized item and redirects with `303`.
- [ ] Passkey challenge replay, wrong origin/RP, wrong purpose/session binding,
      expired challenge, revoked credential/session, quota races, and last
      credential removal fail safely.
- [ ] Native authenticated forms work with JavaScript disabled after an
      existing session; only WebAuthn ceremony requires JavaScript.
- [ ] Browser acceptance proves CSP, cookies, passkey login, focus/errors, and
      the authenticated complete first view without console/page errors.
- [ ] The end-of-M3 build is dogfooded against an explicitly chosen public HN
      identity without claiming ownership verification.

## M4. Thread continuity and Following

### Outcome

An account holder can revisit a bounded thread, see exactly which committed
comments are later than the prior marker, and follow direct children, one
branch, or a whole story independently.

### Work

1. Implement historical on-demand thread load/materialization under node/depth/
   time/body bounds.
2. Implement stable chronological parent-tree query and top-level/focused
   continuation cursors.
3. Implement account thread markers and semantic new-comment rendering.
4. Implement watch creation/removal/mute and creation boundaries.
5. Implement branch ancestor matching using the reducer's bounded path; do not
   add a closure table.
6. Implement Following aggregation through captured event boundaries, ordering,
   causal reasons, and explicit seen actions.
7. Implement `<details>` branch collapse, focused context, canonical HN links,
   and narrow mobile indentation.
8. Exercise overlapping story/branch/direct reply, deletion, missing parent,
   and huge/deep thread fixtures through real HTTP and restart.

### Definition of done

- [ ] First thread visit creates a marker without styling all historical
      comments as new.
- [ ] Second visit after replayed comments highlights only IDs after the
      previous marker; comments arriving while the response is open do not
      silently advance it.
- [ ] A direct-child, branch, and whole-story watch have distinct deterministic
      matches and creation boundaries.
- [ ] One comment matching identity + branch + story produces no duplicate
      card within a category and exposes every reason.
- [ ] Following counts and seen transitions are evaluated through the rendered
      boundary, so concurrent future events remain new.
- [ ] Deleted reply/parent/watch root remains explainable without unsafe HTML.
- [ ] Very deep ancestry terminates under the documented bound with an honest
      unresolved state.
- [ ] A thread larger than one response uses native continuation/focus links
      and stays within measured allocation/response limits.
- [ ] Desktop/mobile/keyboard/no-JavaScript interaction and accessibility match
      the approved M0 states.

## M5. Live invalidation, private Atom, and interface completion

### Outcome

Connected account pages learn that durable state changed without manual HN
refresh, and users can subscribe through revocable private feeds, while reload
remains authoritative.

### Work

1. Implement bounded authenticated application SSE broadcaster and `/events`.
2. Vendor/serve the exact HTMX 4 `hx-sse` extension and use small
   server-rendered count/banner fragments.
3. Implement reconnect/initial-state semantics, event IDs, slow-client bounds,
   heartbeat, proxy timeout, and graceful shutdown.
4. Add normal reload/native refresh actions and conditional ETag polling where
   useful; do not add `hx-ptag` in v1.
5. Implement hashed, labeled, revocable Inbox/Following Atom tokens and proxy
   log redaction.
6. Implement optional keyboard navigation, focus preservation, reduced motion,
   canonical light/device styling, and the accessibility pass. Do not invent a
   dark theme without a separately accepted design.
7. Implement private state export and account deletion.
8. Record product dogfood measures and remove/noise-tune whole-story watches
   based on evidence rather than adding notification classes.

### Definition of done

- [ ] Commit after browser-SSE publication failure/restart still appears on
      initial page/reconnect exactly once.
- [ ] SSE disconnect, reconnect, background/resume, last-event boundary,
      deployment close, and slow client never block ingestion or lose durable
      state.
- [ ] The browser receives only small invalidation/count/banner HTML, never a
      pushed mutable thread tree.
- [ ] Removing HTMX/SSE assets leaves M4 full-page/native behavior complete.
- [ ] Atom feed tokens are shown once, hashed at rest, individually revocable,
      absent from app/proxy logs, conditional-GET capable, and do not mark state
      read.
- [ ] Export excludes the mirrored public corpus; deletion removes every
      user-owned join and credential/token/session.
- [ ] Browser acceptance covers JavaScript on/off, HTMX full/fragment semantic
      equivalence, reconnect, history/focus/scroll, console/page errors, and
      passkey regression without becoming a broad screenshot suite.
- [ ] The interface resolves all five required states using the accepted light
      mobile system on real iPhone-class WebKit, derived desktop, keyboard,
      reduced motion, empty/error/stale/deleted, and no-JavaScript variants.
      Dark mode remains separate unapproved design work.

## M6. Portfolio/public release qualification

### Outcome

Produce an immutable, reproducible, reversible self-hosted release with honest
measurements and a public architecture/replay demonstration.

### Work

1. Implement release packaging with binary, licenses/notices, exact version
   manifest, service/Caddy examples, and operator docs.
2. Implement offline `migrate`, stopped-writer `backup`, isolated `verify`,
   `status`, and restore/rehearsal scripts around explicit paths.
3. Rehearse fresh install, upgrade, migration-twice, backup/restore,
   deliberately invalid backup/schema, and previous binary + pre-migration
   rollback.
4. Deploy through systemd behind Caddy with protected persistent/private temp
   directories, resource limits, canonical origin, SSE proxy policy, and Atom
   log redaction.
5. Run accelerated deterministic replay, stop during ingestion, restart, and
   inspect source event/notification causality.
6. Record startup/RSS/DB growth/lag/detection/SSR/SSE/replay/recovery/backup
   measurements against exact fixture scale and release hash.
7. Perform sustained post-launch checks after the invoking deployment command
   exits.
8. Write concise public project/architecture/operations docs without claiming
   remote CI or long-term production behavior that was not observed.

### Definition of done

- [ ] Release can be built from a clean checkout with verified immutable inputs
      and no Node runtime, CDN, cloud DB, Redis, or external queue.
- [ ] Fresh install and restored install serve useful News while offline from
      HN and visibly report stale data.
- [ ] Backup is published only after isolated reopen/inventory/integrity checks;
      a wrong path cannot create a false source database.
- [ ] Candidate migration and rollback are rehearsed on disposable copies with
      exact schema/count/hash/projection evidence.
- [ ] systemd owns the intended immutable executable after the launch command
      exits; listener/database/sidecars/health/readiness/public/auth/SSE/Atom
      behavior remain healthy through the observation window.
- [ ] The replay demonstration proves no missed/duplicate notification across
      restart and exposes a human-readable causal reason.
- [ ] Public measurements include hardware, build mode, exact release/dependency
      versions, dataset/fixture size, sampling method, and tails—not theoretical
      rendering-speed claims.
- [ ] Every acceptance item in `SPEC.md` has an evidence path or is explicitly
      marked out of scope; no unchecked box is relabeled complete.

## Cross-milestone reliability matrix

The owning milestone must cover each row through deterministic real-process or
focused integration/browser evidence.

| Case | Owner |
| --- | --- |
| Direct reply to tracked comment | M1/M3 |
| Top-level comment on tracked story | M1/M3 |
| Self-reply suppression | M1/M3 |
| Duplicate source delivery | M1 |
| Deleted parent/reply | M1/M4 |
| Missing parent then resolution | M1 |
| Very deep ancestry/cycle | M1/M4 |
| Branch and story watches overlapping | M1/M4 |
| Case-sensitive username | M1/M3 |
| SSE `307`, disconnect, reconnect | M0/M1 |
| Application SSE disconnect/restart | M5 |
| Temporary Firebase null/malformed item | M1 |
| Large max ID jump | M1 |
| Crash after fetch before commit | M1 |
| Crash during reduction | M1 |
| Crash after commit before live publication | M1/M5 |
| Feed partial/failure/gap/reappearance | M2 |
| Full page and fragment semantic equivalence | M5 |
| JavaScript-disabled public/native flow | M2–M5 |
| Wrong Origin/CSRF/content type/unknown field | M3–M5 |
| Unsafe/malformed HN HTML and URL | M0 onward |
| Passkey replay/origin/RP/revocation/quota | M3 |
| Atom token leak/revocation/cache | M5 |
| Disk full/DB busy/forced termination | M0/M1/M6 |
| Backup corruption/newer schema/rollback | M6 |

## Deliberate post-v1 queue

Revisit only with observed demand:

- Web Push or email with a transactional delivery outbox;
- explainable typed domain/title filters;
- tracked-user activity inside one watched story;
- feed snapshot compaction with explicit precision labels;
- browser extension that adds “Track in HN Continuity” links only;
- saved scroll/collapse state;
- HN ranked sibling-order observations;
- additional deployment/platform targets.

Native HN actions, AI comment writing/editing, broad social aggregation,
opaque recommendations, and multi-service infrastructure remain non-goals, not
backlog promises.
