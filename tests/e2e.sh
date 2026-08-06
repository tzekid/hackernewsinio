#!/usr/bin/env bash
set -euo pipefail

app=$1
fixture=$2
work=$(mktemp -d)
fixture_pid=
app_pid=
origin=http://127.0.0.1:19084
cleanup() {
  if [[ -n "$app_pid" ]]; then kill -TERM "$app_pid" 2>/dev/null || true; wait "$app_pid" 2>/dev/null || true; fi
  if [[ -n "$fixture_pid" ]]; then kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true; fi
  rm -rf -- "$work"
}
trap cleanup EXIT

"$fixture" 19083 >"$work/fixture.log" 2>&1 & fixture_pid=$!
for _ in $(seq 1 100); do curl -fsS http://127.0.0.1:19083/v0/maxitem.json >/dev/null 2>&1 && break; sleep 0.02; done

"$app" init "$work/app.db" >/dev/null
"$app" sync "$work/app.db" http://127.0.0.1:19083/v0 >/dev/null
cookie=$("$app" dev-session "$work/app.db")
csrf=${cookie##*hnc_csrf=}

"$app" serve "$work/app.db" --listen 127.0.0.1:19084 --hn-base http://127.0.0.1:19083/v0 >"$work/app.log" 2>&1 & app_pid=$!
for _ in $(seq 1 200); do curl -fsS http://127.0.0.1:19084/readyz >/dev/null 2>&1 && break; sleep 0.02; done

wrong_origin_status=$(curl -sS -o /dev/null -w '%{http_code}' -H "Cookie: $cookie" -H 'Origin: https://wrong.example' -X POST \
  --data-urlencode "csrf=$csrf" --data-urlencode 'scope=inbox' http://127.0.0.1:19084/settings/feeds)
test "$wrong_origin_status" = 403
curl -fsS -H "Origin: $origin" -H 'Content-Type: application/json' -d '{}' \
  http://127.0.0.1:19084/auth/register/options >"$work/passkey-options.json"
grep -q '"challenge"' "$work/passkey-options.json"
grep -q '"rp"' "$work/passkey-options.json"
curl -fsS -H "Cookie: $cookie" -H "Origin: $origin" -H 'Content-Type: application/json' -d '{}' \
  http://127.0.0.1:19084/auth/passkeys/options >"$work/add-passkey-options.json"
grep -q '"excludeCredentials"' "$work/add-passkey-options.json"
curl -fsS http://127.0.0.1:19084/auth/register >"$work/register.html"
grep -q 'Create account' "$work/register.html"

curl -fsS http://127.0.0.1:19084/news >"$work/news.html"
grep -q 'SQLite 3.46' "$work/news.html"
grep -q 'CURRENT OBSERVED STORIES' "$work/news.html"
curl -fsS http://127.0.0.1:19084/history >"$work/history.html"
grep -q 'top capture' "$work/history.html"
curl -fsS 'http://127.0.0.1:19084/history?capture=1' >"$work/capture.html"
grep -q 'Exact stored observation' "$work/capture.html"
grep -q 'SQLite 3.46' "$work/capture.html"
curl -fsS http://127.0.0.1:19084/history/100 >"$work/trajectory.html"
grep -q 'Observed front-page rank over time' "$work/trajectory.html"
grep -q 'Rank 1' "$work/trajectory.html"

curl -fsS -H "Cookie: $cookie" -H "Origin: $origin" -X POST \
  --data-urlencode "csrf=$csrf" --data-urlencode 'username=awce' \
  http://127.0.0.1:19084/settings/identities >"$work/identity-preview.html"
grep -q 'Track this public identity?' "$work/identity-preview.html"
grep -q 'does not prove that you own' "$work/identity-preview.html"
curl -fsS -H "Cookie: $cookie" -H "Origin: $origin" -X POST \
  --data-urlencode "csrf=$csrf" --data-urlencode 'username=awce' --data-urlencode 'confirm=yes' \
  http://127.0.0.1:19084/settings/identities -o /dev/null
curl -fsS -H "Cookie: $cookie" -H "Origin: $origin" -X POST \
  --data-urlencode "csrf=$csrf" --data-urlencode 'scope_kind=comment_branch' --data-urlencode 'scope_item_id=101' \
  http://127.0.0.1:19084/watches -o /dev/null

# Stop at a commit boundary, replay an upstream sequence, and prove recovery.
kill -TERM "$app_pid"
wait "$app_pid"
app_pid=
"$app" replay "$work/app.db" tests/fixtures/replay.ndjson >/dev/null
"$app" serve "$work/app.db" --listen 127.0.0.1:19084 --hn-base http://127.0.0.1:19083/v0 >"$work/app-restarted.log" 2>&1 & app_pid=$!
for _ in $(seq 1 200); do curl -fsS http://127.0.0.1:19084/readyz >/dev/null 2>&1 && break; sleep 0.02; done

curl -fsS -H "Cookie: $cookie" http://127.0.0.1:19084/inbox >"$work/inbox.html"
grep -q 'relaxed parser' "$work/inbox.html"
grep -q 'You wrote' "$work/inbox.html"
grep -q 'Why this is here' "$work/inbox.html"
curl -fsS -H "Cookie: $cookie" http://127.0.0.1:19084/events >"$work/events.txt"
grep -Eq '[1-9][0-9]* unread continuity update' "$work/events.txt"
notification_id=$(sed -n 's|.*action="/inbox/\([0-9][0-9]*\)/open".*|\1|p' "$work/inbox.html" | head -1)
through=$(sed -n 's|.*name="through" value="\([0-9][0-9]*\)".*|\1|p' "$work/inbox.html" | head -1)
from=$(sed -n 's|.*name="from" value="\([0-9][0-9]*\)".*|\1|p' "$work/inbox.html" | head -1)
test -n "$notification_id"
test -n "$through"
test -n "$from"
curl -fsS -H "Cookie: $cookie" -H "Origin: $origin" -X POST --data-urlencode "csrf=$csrf" --data-urlencode "from=$from" --data-urlencode "through=$through" \
  http://127.0.0.1:19084/inbox/read-all -o /dev/null
curl -fsS -H "Cookie: $cookie" -H "Origin: $origin" -X POST --data-urlencode "csrf=$csrf" \
  "http://127.0.0.1:19084/inbox/$notification_id/unread" -o /dev/null
curl -fsS -D "$work/notification-headers" -H "Cookie: $cookie" \
  "http://127.0.0.1:19084/inbox/$notification_id" -o /dev/null
grep -q '^location: /item/100?focus=102#comment-102' "$work/notification-headers"
curl -fsS -H "Cookie: $cookie" http://127.0.0.1:19084/following >"$work/following.html"
grep -q 'new comments' "$work/following.html"
curl -fsS -H "Cookie: $cookie" http://127.0.0.1:19084/item/100 >"$work/thread-first.html"
curl -fsS -H "Cookie: $cookie" http://127.0.0.1:19084/item/100 >"$work/thread-second.html"
grep -q 'Open on Hacker News to reply' "$work/thread-second.html"
grep -q '<details open>' "$work/thread-second.html"
grep -q 'HN ↗' "$work/thread-second.html"

curl -fsS -D "$work/headers" http://127.0.0.1:19084/news -o /dev/null
grep -qi '^content-security-policy:' "$work/headers"
grep -qi '^x-content-type-options: nosniff' "$work/headers"
curl -fsS -H "Cookie: $cookie" -H "Origin: $origin" -X POST --data-urlencode "csrf=$csrf" --data-urlencode 'scope=inbox' \
  http://127.0.0.1:19084/settings/feeds >"$work/feed-token.html"
feed_token=$(grep -oE '[0-9a-f]{48}' "$work/feed-token.html" | head -1)
test -n "$feed_token"
curl -fsS -D "$work/atom-headers" "http://127.0.0.1:19084/feeds/$feed_token/inbox.atom" >"$work/inbox.atom"
grep -q '<feed xmlns="http://www.w3.org/2005/Atom">' "$work/inbox.atom"
grep -q '<updated>20[0-9][0-9]-' "$work/inbox.atom"
atom_etag=$(sed -n 's/^[Ee][Tt][Aa][Gg]: \(.*\)\r$/\1/p' "$work/atom-headers")
test -n "$atom_etag"
atom_status=$(curl -sS -o /dev/null -w '%{http_code}' -H "If-None-Match: $atom_etag" "http://127.0.0.1:19084/feeds/$feed_token/inbox.atom")
test "$atom_status" = 304
curl -fsS -H "Cookie: $cookie" -H "Origin: $origin" -X POST --data-urlencode "csrf=$csrf" \
  "http://127.0.0.1:19084/inbox/$notification_id/dismiss" -o /dev/null
curl -fsS -H "Cookie: $cookie" 'http://127.0.0.1:19084/inbox?all=1' >"$work/inbox-dismissed.html"
! grep -q "action=\"/inbox/$notification_id/open\"" "$work/inbox-dismissed.html"
curl -fsS -H "Cookie: $cookie" -H "Origin: $origin" -X POST --data-urlencode "csrf=$csrf" \
  http://127.0.0.1:19084/settings/export >"$work/export.json"
grep -q '"identities"' "$work/export.json"
grep -q '"watches"' "$work/export.json"
grep -q '"thread_markers"' "$work/export.json"
grep -Eq '"dismissed_at":[0-9]+' "$work/export.json"
kill -TERM "$app_pid"
wait "$app_pid"
app_pid=
"$app" status "$work/app.db" | grep -q 'notifications='
"$app" backup "$work/app.db" "$work/backup.db" >/dev/null
"$app" restore "$work/backup.db" "$work/restored.db" >/dev/null
"$app" status "$work/restored.db" | grep -q 'notifications='
