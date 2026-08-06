pub const version: i64 = 1;

pub const bootstrap =
    \\PRAGMA foreign_keys = ON;
    \\PRAGMA journal_mode = WAL;
    \\CREATE TABLE IF NOT EXISTS schema_migrations (
    \\  version INTEGER PRIMARY KEY,
    \\  name TEXT NOT NULL UNIQUE,
    \\  applied_at INTEGER NOT NULL,
    \\  app_version TEXT NOT NULL
    \\);
;

pub const migration_1 =
    \\CREATE TABLE runtime_state (
    \\  key TEXT PRIMARY KEY CHECK (key IN ('instance_id', 'authoritative_history_started_at')),
    \\  value TEXT NOT NULL,
    \\  updated_at INTEGER NOT NULL
    \\);
    \\CREATE TABLE items (
    \\  id INTEGER PRIMARY KEY CHECK (id >= 0),
    \\  kind TEXT NOT NULL CHECK (kind IN ('story','comment','job','poll','pollopt')),
    \\  author TEXT COLLATE BINARY,
    \\  created_at INTEGER,
    \\  parent_id INTEGER CHECK (parent_id IS NULL OR parent_id >= 0),
    \\  root_story_id INTEGER CHECK (root_story_id IS NULL OR root_story_id >= 0),
    \\  depth INTEGER CHECK (depth IS NULL OR depth >= 0),
    \\  score INTEGER,
    \\  comment_count INTEGER CHECK (comment_count IS NULL OR comment_count >= 0),
    \\  dead INTEGER NOT NULL DEFAULT 0 CHECK (dead IN (0,1)),
    \\  deleted INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0,1)),
    \\  graph_state TEXT NOT NULL CHECK (graph_state IN ('resolved','unresolved_parent','unresolved_root','invalid')),
    \\  source_revision TEXT NOT NULL,
    \\  first_fetched_at INTEGER NOT NULL,
    \\  last_fetched_at INTEGER NOT NULL,
    \\  materialization_reason TEXT
    \\);
    \\CREATE INDEX items_parent ON items(parent_id, created_at, id);
    \\CREATE INDEX items_root ON items(root_story_id, created_at, id);
    \\CREATE INDEX items_author ON items(author COLLATE BINARY, created_at, id);
    \\CREATE INDEX items_fetched ON items(last_fetched_at);
    \\CREATE TABLE item_content (
    \\  item_id INTEGER PRIMARY KEY,
    \\  title_text TEXT,
    \\  url TEXT,
    \\  source_html TEXT,
    \\  safe_html TEXT,
    \\  sanitizer_version INTEGER NOT NULL CHECK (sanitizer_version >= 1),
    \\  source_hash TEXT NOT NULL,
    \\  safe_hash TEXT NOT NULL,
    \\  materialized_at INTEGER NOT NULL,
    \\  FOREIGN KEY (item_id) REFERENCES items(id)
    \\);
    \\CREATE TABLE feed_captures (
    \\  id INTEGER PRIMARY KEY,
    \\  feed TEXT NOT NULL CHECK (feed IN ('top','ask','show','job')),
    \\  captured_at INTEGER NOT NULL,
    \\  depth INTEGER NOT NULL CHECK (depth > 0),
    \\  entry_count INTEGER NOT NULL CHECK (entry_count >= 0 AND entry_count <= depth),
    \\  source_hash TEXT NOT NULL,
    \\  duration_ms INTEGER NOT NULL CHECK (duration_ms >= 0),
    \\  source_maxitem INTEGER,
    \\  UNIQUE(feed, captured_at)
    \\);
    \\CREATE TABLE feed_entries (
    \\  capture_id INTEGER NOT NULL,
    \\  story_id INTEGER NOT NULL,
    \\  rank INTEGER NOT NULL CHECK (rank > 0),
    \\  score INTEGER,
    \\  comment_count INTEGER CHECK (comment_count IS NULL OR comment_count >= 0),
    \\  PRIMARY KEY(capture_id, story_id),
    \\  UNIQUE(capture_id, rank),
    \\  FOREIGN KEY(capture_id) REFERENCES feed_captures(id) ON DELETE CASCADE
    \\);
    \\CREATE INDEX feed_entries_story ON feed_entries(story_id, capture_id);
    \\CREATE TABLE story_feed_stats (
    \\  story_id INTEGER NOT NULL,
    \\  feed TEXT NOT NULL CHECK (feed IN ('top','ask','show','job')),
    \\  first_capture_id INTEGER NOT NULL,
    \\  last_capture_id INTEGER NOT NULL,
    \\  first_rank INTEGER NOT NULL CHECK (first_rank > 0),
    \\  best_rank INTEGER NOT NULL CHECK (best_rank > 0),
    \\  last_rank INTEGER NOT NULL CHECK (last_rank > 0),
    \\  capture_count INTEGER NOT NULL CHECK (capture_count > 0),
    \\  PRIMARY KEY(story_id, feed),
    \\  FOREIGN KEY(first_capture_id) REFERENCES feed_captures(id),
    \\  FOREIGN KEY(last_capture_id) REFERENCES feed_captures(id)
    \\);
    \\CREATE TABLE ingest_cursors (
    \\  stream TEXT PRIMARY KEY CHECK (stream IN ('hn_items')),
    \\  processed_through INTEGER NOT NULL CHECK (processed_through >= 0),
    \\  observed_max INTEGER NOT NULL CHECK (observed_max >= processed_through),
    \\  checked_at INTEGER NOT NULL,
    \\  advanced_at INTEGER NOT NULL
    \\);
    \\CREATE TABLE ingest_gaps (
    \\  item_id INTEGER PRIMARY KEY CHECK (item_id >= 0),
    \\  state TEXT NOT NULL CHECK (state IN ('retryable','dormant','resolved')),
    \\  error_class TEXT NOT NULL CHECK (length(error_class) BETWEEN 1 AND 64),
    \\  first_failed_at INTEGER NOT NULL,
    \\  last_attempt_at INTEGER NOT NULL,
    \\  next_attempt_at INTEGER NOT NULL,
    \\  attempt_count INTEGER NOT NULL CHECK (attempt_count BETWEEN 1 AND 1000000),
    \\  resolved_at INTEGER
    \\);
    \\CREATE INDEX ingest_gaps_retry ON ingest_gaps(state, next_attempt_at, item_id);
    \\CREATE TABLE app_users (
    \\  id TEXT PRIMARY KEY CHECK (length(id) BETWEEN 22 AND 128),
    \\  created_at INTEGER NOT NULL,
    \\  deleted_at INTEGER
    \\);
    \\CREATE TABLE background_jobs (
    \\  id TEXT PRIMARY KEY CHECK (length(id) BETWEEN 22 AND 128),
    \\  kind TEXT NOT NULL CHECK (kind IN ('identity_backfill','sanitize_reprocess','feed_capture','reconcile')),
    \\  owner_user_id TEXT,
    \\  subject TEXT NOT NULL CHECK (length(subject) BETWEEN 1 AND 512),
    \\  state TEXT NOT NULL CHECK (state IN ('pending','running','succeeded','failed','cancelled')),
    \\  position INTEGER NOT NULL DEFAULT 0 CHECK (position >= 0),
    \\  limit_value INTEGER NOT NULL CHECK (limit_value >= 0),
    \\  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    \\  last_error_class TEXT,
    \\  created_at INTEGER NOT NULL,
    \\  started_at INTEGER,
    \\  updated_at INTEGER NOT NULL,
    \\  finished_at INTEGER,
    \\  FOREIGN KEY(owner_user_id) REFERENCES app_users(id) ON DELETE CASCADE
    \\);
    \\CREATE INDEX background_jobs_ready ON background_jobs(state, updated_at, id);
    \\CREATE TABLE auth_credentials (
    \\  credential_id TEXT PRIMARY KEY CHECK (length(credential_id) BETWEEN 1 AND 2048),
    \\  user_id TEXT NOT NULL,
    \\  public_key TEXT NOT NULL CHECK (length(public_key) BETWEEN 1 AND 32768),
    \\  algorithm INTEGER NOT NULL CHECK (algorithm IN (-7,-257)),
    \\  sign_count INTEGER NOT NULL CHECK (sign_count >= 0),
    \\  transports TEXT NOT NULL CHECK (length(transports) <= 256),
    \\  aaguid TEXT CHECK (aaguid IS NULL OR length(aaguid) <= 128),
    \\  backup_eligible INTEGER NOT NULL CHECK (backup_eligible IN (0,1)),
    \\  backup_state INTEGER NOT NULL CHECK (backup_state IN (0,1)),
    \\  label TEXT NOT NULL CHECK (length(label) BETWEEN 1 AND 64),
    \\  created_at INTEGER NOT NULL,
    \\  last_used_at INTEGER,
    \\  revoked_at INTEGER,
    \\  FOREIGN KEY(user_id) REFERENCES app_users(id) ON DELETE CASCADE
    \\);
    \\CREATE INDEX auth_credentials_user ON auth_credentials(user_id, revoked_at, created_at);
    \\CREATE TABLE auth_challenges (
    \\  id TEXT PRIMARY KEY CHECK (length(id) BETWEEN 22 AND 128),
    \\  purpose TEXT NOT NULL CHECK (purpose IN ('register','authenticate','add_credential')),
    \\  challenge_hash TEXT NOT NULL UNIQUE CHECK (length(challenge_hash) = 64),
    \\  user_id TEXT,
    \\  binding_hash TEXT NOT NULL CHECK (length(binding_hash) = 64),
    \\  created_at INTEGER NOT NULL,
    \\  expires_at INTEGER NOT NULL,
    \\  used_at INTEGER,
    \\  FOREIGN KEY(user_id) REFERENCES app_users(id) ON DELETE CASCADE
    \\);
    \\CREATE INDEX auth_challenges_expiry ON auth_challenges(expires_at, used_at);
    \\CREATE TABLE sessions (
    \\  token_hash TEXT PRIMARY KEY CHECK (length(token_hash) = 64),
    \\  user_id TEXT NOT NULL,
    \\  csrf_hash TEXT NOT NULL CHECK (length(csrf_hash) = 64),
    \\  created_at INTEGER NOT NULL,
    \\  last_seen_at INTEGER NOT NULL,
    \\  expires_at INTEGER NOT NULL,
    \\  revoked_at INTEGER,
    \\  label TEXT CHECK (label IS NULL OR length(label) <= 64),
    \\  FOREIGN KEY(user_id) REFERENCES app_users(id) ON DELETE CASCADE
    \\);
    \\CREATE INDEX sessions_user ON sessions(user_id, revoked_at, expires_at);
    \\CREATE INDEX sessions_expiry ON sessions(expires_at);
    \\CREATE TABLE hn_identities (
    \\  id TEXT PRIMARY KEY CHECK (length(id) BETWEEN 22 AND 128),
    \\  user_id TEXT NOT NULL,
    \\  username TEXT COLLATE BINARY NOT NULL CHECK (length(username) BETWEEN 1 AND 64),
    \\  private_label TEXT CHECK (private_label IS NULL OR length(private_label) <= 64),
    \\  state TEXT NOT NULL CHECK (state IN ('pending_preview','active','backfilling','error','removed')),
    \\  profile_created_at INTEGER,
    \\  profile_karma INTEGER,
    \\  added_at INTEGER NOT NULL,
    \\  removed_at INTEGER,
    \\  backfill_job_id TEXT,
    \\  FOREIGN KEY(user_id) REFERENCES app_users(id) ON DELETE CASCADE,
    \\  FOREIGN KEY(backfill_job_id) REFERENCES background_jobs(id)
    \\);
    \\CREATE UNIQUE INDEX hn_identities_active ON hn_identities(user_id, username COLLATE BINARY) WHERE removed_at IS NULL;
    \\CREATE TABLE watches (
    \\  id TEXT PRIMARY KEY CHECK (length(id) BETWEEN 22 AND 128),
    \\  user_id TEXT NOT NULL,
    \\  scope_kind TEXT NOT NULL CHECK (scope_kind IN ('comment_direct','comment_branch','story')),
    \\  scope_item_id INTEGER NOT NULL,
    \\  root_story_id INTEGER NOT NULL,
    \\  created_item_boundary INTEGER NOT NULL CHECK (created_item_boundary >= 0),
    \\  created_event_boundary INTEGER NOT NULL CHECK (created_event_boundary >= 0),
    \\  muted INTEGER NOT NULL DEFAULT 0 CHECK (muted IN (0,1)),
    \\  created_at INTEGER NOT NULL,
    \\  removed_at INTEGER,
    \\  FOREIGN KEY(user_id) REFERENCES app_users(id) ON DELETE CASCADE
    \\);
    \\CREATE UNIQUE INDEX watches_active ON watches(user_id, scope_kind, scope_item_id) WHERE removed_at IS NULL;
    \\CREATE TABLE events (
    \\  id INTEGER PRIMARY KEY,
    \\  event_key TEXT NOT NULL UNIQUE CHECK (length(event_key) BETWEEN 1 AND 256),
    \\  kind TEXT NOT NULL CHECK (kind IN ('comment_created','item_state_changed','feed_first_observed','feed_milestone')),
    \\  source_item_id INTEGER,
    \\  parent_item_id INTEGER,
    \\  root_story_id INTEGER,
    \\  relevant_item_id INTEGER,
    \\  source_revision TEXT,
    \\  occurred_at INTEGER NOT NULL,
    \\  detected_at INTEGER NOT NULL,
    \\  source_class TEXT NOT NULL CHECK (source_class IN ('live','gap_retry','backfill','thread_load','reconcile','feed_capture'))
    \\);
    \\CREATE INDEX events_kind ON events(kind, detected_at, id);
    \\CREATE INDEX events_root ON events(root_story_id, id);
    \\CREATE INDEX events_source ON events(source_item_id, kind);
    \\CREATE TABLE notifications (
    \\  id INTEGER PRIMARY KEY,
    \\  user_id TEXT NOT NULL,
    \\  event_id INTEGER NOT NULL,
    \\  category TEXT NOT NULL CHECK (category IN ('inbox','following')),
    \\  suppressed INTEGER NOT NULL DEFAULT 0 CHECK (suppressed IN (0,1)),
    \\  created_at INTEGER NOT NULL,
    \\  read_at INTEGER,
    \\  dismissed_at INTEGER,
    \\  UNIQUE(user_id,event_id,category),
    \\  FOREIGN KEY(user_id) REFERENCES app_users(id) ON DELETE CASCADE,
    \\  FOREIGN KEY(event_id) REFERENCES events(id)
    \\);
    \\CREATE INDEX notifications_unread ON notifications(user_id, category, suppressed, read_at, id);
    \\CREATE INDEX notifications_feed ON notifications(user_id, category, id);
    \\CREATE TABLE notification_reasons (
    \\  notification_id INTEGER NOT NULL,
    \\  reason_kind TEXT NOT NULL CHECK (reason_kind IN ('identity_direct','identity_story','watch_direct','watch_branch','watch_story')),
    \\  tracked_identity_id TEXT,
    \\  watch_id TEXT,
    \\  relevant_item_id INTEGER NOT NULL,
    \\  reason_key TEXT NOT NULL,
    \\  PRIMARY KEY(notification_id, reason_key),
    \\  FOREIGN KEY(notification_id) REFERENCES notifications(id) ON DELETE CASCADE,
    \\  FOREIGN KEY(tracked_identity_id) REFERENCES hn_identities(id),
    \\  FOREIGN KEY(watch_id) REFERENCES watches(id)
    \\);
    \\CREATE TABLE watch_markers (
    \\  user_id TEXT NOT NULL,
    \\  watch_id TEXT NOT NULL,
    \\  seen_through_event_id INTEGER NOT NULL CHECK (seen_through_event_id >= 0),
    \\  rendered_at INTEGER NOT NULL,
    \\  PRIMARY KEY(user_id,watch_id),
    \\  FOREIGN KEY(user_id) REFERENCES app_users(id) ON DELETE CASCADE,
    \\  FOREIGN KEY(watch_id) REFERENCES watches(id) ON DELETE CASCADE
    \\);
    \\CREATE TABLE news_markers (
    \\  user_id TEXT NOT NULL,
    \\  feed TEXT NOT NULL CHECK (feed IN ('top','ask','show','job')),
    \\  seen_through_capture_id INTEGER NOT NULL,
    \\  rendered_at INTEGER NOT NULL,
    \\  PRIMARY KEY(user_id,feed),
    \\  FOREIGN KEY(user_id) REFERENCES app_users(id) ON DELETE CASCADE,
    \\  FOREIGN KEY(seen_through_capture_id) REFERENCES feed_captures(id)
    \\);
    \\CREATE TABLE thread_markers (
    \\  user_id TEXT NOT NULL,
    \\  root_story_id INTEGER NOT NULL,
    \\  seen_through_item_id INTEGER NOT NULL CHECK (seen_through_item_id >= 0),
    \\  rendered_at INTEGER NOT NULL,
    \\  PRIMARY KEY(user_id,root_story_id),
    \\  FOREIGN KEY(user_id) REFERENCES app_users(id) ON DELETE CASCADE
    \\);
    \\CREATE TABLE feed_tokens (
    \\  id TEXT PRIMARY KEY CHECK (length(id) BETWEEN 22 AND 128),
    \\  token_hash TEXT NOT NULL UNIQUE CHECK (length(token_hash) = 64),
    \\  user_id TEXT NOT NULL,
    \\  scope TEXT NOT NULL CHECK (scope IN ('inbox','following')),
    \\  label TEXT NOT NULL CHECK (length(label) BETWEEN 1 AND 64),
    \\  created_at INTEGER NOT NULL,
    \\  last_used_at INTEGER,
    \\  revoked_at INTEGER,
    \\  FOREIGN KEY(user_id) REFERENCES app_users(id) ON DELETE CASCADE
    \\);
;
