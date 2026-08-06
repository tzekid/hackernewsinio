const std = @import("std");
const html = @import("web_html");
const database_mod = @import("../store/database.zig");

pub const Page = enum { news, inbox, following, settings, thread, history, auth };

pub const Session = struct {
    user_id: []const u8,
    csrf_token: []const u8,
};

pub fn news(allocator: std.mem.Allocator, store: *database_mod.Store, session: ?Session, history_mode: bool, filter: []const u8, previous_capture: ?i64, before: ?i64, now: i64) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try start(writer, if (history_mode) "History · HN Continuity" else "News · HN Continuity", if (history_mode) .history else .news, session != null, null);
    try writer.writeAll(if (history_mode) "<h1>History</h1>" else "<h1>News</h1>");
    try writer.writeAll("<nav class=\"segments\" aria-label=\"News mode\"><a href=\"/news\"");
    if (!history_mode) try writer.writeAll(" aria-current=\"page\"");
    try writer.writeAll(">Now</a><a href=\"/history\"");
    if (history_mode) try writer.writeAll(" aria-current=\"page\"");
    try writer.writeAll(">History</a></nav>");
    if (history_mode) {
        try renderCaptures(writer, store);
    } else {
        try renderNewsRows(writer, store, filter, previous_capture, before, now);
    }
    try finish(writer, .news, session != null);
    return out.toOwnedSlice();
}

fn renderNewsRows(writer: *std.Io.Writer, store: *database_mod.Store, filter: []const u8, previous_capture: ?i64, before: ?i64, now: i64) !void {
    const condition = if (std.mem.eql(u8, filter, "top10"))
        " AND s.best_rank<=10"
    else if (std.mem.eql(u8, filter, "top20"))
        " AND s.best_rank<=20"
    else if (std.mem.eql(u8, filter, "ask"))
        " AND s.feed='ask'"
    else if (std.mem.eql(u8, filter, "show"))
        " AND s.feed='show'"
    else if (std.mem.eql(u8, filter, "job"))
        " AND s.feed='job'"
    else
        " AND s.feed='top'";
    var sql_buffer: [2048]u8 = undefined;
    const sql = try std.fmt.bufPrint(&sql_buffer,
        \\SELECT s.story_id,COALESCE(c.title_text,'Item '||s.story_id),c.url,i.score,i.comment_count,i.created_at,s.first_rank,s.best_rank,s.first_capture_id,fc.captured_at
        \\FROM story_feed_stats s JOIN feed_captures fc ON fc.id=s.first_capture_id
        \\LEFT JOIN items i ON i.id=s.story_id LEFT JOIN item_content c ON c.item_id=s.story_id
        \\WHERE (?1 IS NULL OR s.first_capture_id<?1){s} ORDER BY s.first_capture_id DESC,s.first_rank,s.story_id DESC LIMIT 60
    , .{condition});
    var fresh_rows = try store.connection.query("SELECT MAX(captured_at) FROM feed_captures WHERE feed='top'", &.{}, .{});
    defer fresh_rows.deinit();
    const latest_capture = if (try fresh_rows.next()) |fresh| try fresh.get(?i64, 0) else null;
    try fresh_rows.finish(null);
    if (latest_capture) |captured_at| {
        try writer.print("<p class=\"meta\">Latest successful top-feed capture: <time datetime=\"{d}\">{d}</time>.</p>", .{ captured_at, captured_at });
        if (now - captured_at > 600) try writer.writeAll("<p class=\"status-banner\">Feed observations are stale. Showing the last successful local capture.</p>");
    }
    try writer.writeAll("<div class=\"actions\" aria-label=\"News filters\"><a class=\"button\" href=\"/news\">Top 30</a><a class=\"button\" href=\"/news?filter=top20\">Top 20</a><a class=\"button\" href=\"/news?filter=top10\">Top 10</a><a class=\"button\" href=\"/news?filter=ask\">Ask</a><a class=\"button\" href=\"/news?filter=show\">Show</a><a class=\"button\" href=\"/news?filter=job\">Jobs</a></div>");
    var rows = try store.connection.queryParams(sql, .{before}, .{});
    defer rows.deinit();
    var count: usize = 0;
    var last_capture: ?i64 = null;
    if (previous_capture != null) try writer.writeAll("<p class=\"boundary\">NEW SINCE YOUR PREVIOUS VISIT</p>") else try writer.writeAll("<p class=\"boundary\">CURRENT OBSERVED STORIES</p>");
    try writer.writeAll("<ol class=\"rows\">");
    var old_boundary_written = false;
    while (try rows.next()) |row| {
        count += 1;
        const id = try row.get(i64, 0);
        const title = try row.get([]const u8, 1);
        const url = try row.get(?[]const u8, 2);
        const score = try row.get(?i64, 3);
        const comments = try row.get(?i64, 4);
        const first_rank = try row.get(i64, 6);
        const best_rank = try row.get(i64, 7);
        const observed = try row.get(i64, 9);
        const first_capture = try row.get(i64, 8);
        last_capture = first_capture;
        const is_new = if (previous_capture) |boundary| first_capture > boundary else false;
        if (!is_new and previous_capture != null and !old_boundary_written) {
            try writer.writeAll("</ol><h2>Older stories</h2><ol class=\"rows\">");
            old_boundary_written = true;
        }
        try writer.writeAll("<li class=\"row");
        if (is_new) try writer.writeAll(" row--new");
        try writer.print("\" data-nav-row><article><p class=\"row__title\"><span class=\"accent\">{d}</span> ", .{first_rank});
        if (url) |external| {
            try writer.writeAll("<a href=\"");
            try html.urlAttribute(writer, external);
            try writer.writeAll("\" rel=\"nofollow noreferrer\">");
            try html.text(writer, title);
            try writer.writeAll("</a>");
        } else {
            try writer.print("<a href=\"/item/{d}\">", .{id});
            try html.text(writer, title);
            try writer.writeAll("</a>");
        }
        try writer.writeAll("</p><p class=\"row__meta\">");
        if (score) |value| try writer.print("{d} points · ", .{value});
        if (comments) |value| try writer.print("<a href=\"/item/{d}\">{d} comments</a> · ", .{ id, value });
        try writer.print("best #{d} · <a href=\"/history/{d}\">trajectory</a> · first observed <time datetime=\"{d}\">{d}</time></p></article></li>", .{ best_rank, id, observed, observed });
    }
    try rows.finish(null);
    if (count == 0) try writer.writeAll("<li class=\"row\"><p>No successful feed capture yet. Run the source sync; this page will remain honest rather than inventing history.</p></li>");
    try writer.writeAll("</ol>");
    if (before != null or (count == 60 and last_capture != null)) {
        try writer.writeAll("<nav class=\"actions\" aria-label=\"News pages\">");
        if (before != null) {
            try writer.writeAll("<a class=\"button\" href=\"/news");
            if (filter.len != 0) {
                try writer.writeAll("?filter=");
                try html.urlAttribute(writer, filter);
            }
            try writer.writeAll("\">Newer</a>");
        }
        if (count == 60 and last_capture != null) {
            try writer.writeAll("<a class=\"button\" href=\"/news?");
            if (filter.len != 0) {
                try writer.writeAll("filter=");
                try html.urlAttribute(writer, filter);
                try writer.writeAll("&amp;");
            }
            try writer.print("before={d}\">Older</a>", .{last_capture.?});
        }
        try writer.writeAll("</nav>");
    }
}

fn renderCaptures(writer: *std.Io.Writer, store: *database_mod.Store) !void {
    var start_rows = try store.connection.query("SELECT MIN(captured_at) FROM feed_captures", &.{}, .{});
    defer start_rows.deinit();
    try writer.writeAll("<p class=\"meta\">Exact local observations. Missing intervals remain visible as gaps. Authoritative local history begins ");
    if (try start_rows.next()) |row| if (try row.get(?i64, 0)) |started| try writer.print("at <time datetime=\"{d}\">{d}</time>", .{ started, started }) else try writer.writeAll("with the first successful capture");
    try start_rows.finish(null);
    try writer.writeAll(". Captures are retained in v1 until an operator adopts and documents a different policy.</p><ol class=\"rows\">");
    var rows = try store.connection.query("SELECT id,feed,captured_at,entry_count,depth,duration_ms FROM feed_captures ORDER BY captured_at DESC,id DESC LIMIT 100", &.{}, .{});
    defer rows.deinit();
    var count: usize = 0;
    while (try rows.next()) |row| {
        count += 1;
        try writer.print("<li class=\"row\"><p class=\"row__title\"><a href=\"/history?capture={d}\">{s} capture</a></p><p class=\"row__meta\"><time datetime=\"{d}\">{d}</time> · {d}/{d} entries · {d} ms</p></li>", .{ try row.get(i64, 0), try row.get([]const u8, 1), try row.get(i64, 2), try row.get(i64, 2), try row.get(i64, 3), try row.get(i64, 4), try row.get(i64, 5) });
    }
    try rows.finish(null);
    if (count == 0) try writer.writeAll("<li class=\"row\">History begins with the first successful capture.</li>");
    try writer.writeAll("</ol>");
}

pub fn capture(allocator: std.mem.Allocator, store: *database_mod.Store, session: ?Session, capture_id: i64) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try start(writer, "Feed capture · HN Continuity", .history, session != null, "/history");
    var capture_rows = try store.connection.queryParams("SELECT feed,captured_at,depth,entry_count,duration_ms FROM feed_captures WHERE id=?1", .{capture_id}, .{});
    defer capture_rows.deinit();
    const capture_row = (try capture_rows.next()) orelse {
        try writer.writeAll("<h1>Capture not found</h1>");
        try finish(writer, .history, session != null);
        return out.toOwnedSlice();
    };
    try writer.writeAll("<h1>Feed capture</h1><p class=\"row__title\">");
    try html.text(writer, try capture_row.get([]const u8, 0));
    try writer.print(" at <time datetime=\"{d}\">{d}</time></p><p class=\"meta\">Exact stored observation: {d}/{d} entries, fetched in {d} ms.</p>", .{ try capture_row.get(i64, 1), try capture_row.get(i64, 1), try capture_row.get(i64, 3), try capture_row.get(i64, 2), try capture_row.get(i64, 4) });
    try capture_rows.finish(null);
    try writer.writeAll("<ol class=\"rows\">");
    var rows = try store.connection.queryParams(
        \\SELECT fe.rank,fe.story_id,COALESCE(c.title_text,'Story '||fe.story_id),fe.score,fe.comment_count
        \\FROM feed_entries fe LEFT JOIN item_content c ON c.item_id=fe.story_id
        \\WHERE fe.capture_id=?1 ORDER BY fe.rank
    , .{capture_id}, .{});
    defer rows.deinit();
    while (try rows.next()) |row| {
        const story_id = try row.get(i64, 1);
        try writer.print("<li class=\"row\" data-nav-row><p class=\"row__title\"><span class=\"accent\">{d}</span> <a href=\"/item/{d}\">", .{ try row.get(i64, 0), story_id });
        try html.text(writer, try row.get([]const u8, 2));
        try writer.writeAll("</a></p><p class=\"row__meta\">");
        if (try row.get(?i64, 3)) |score| try writer.print("{d} points · ", .{score});
        if (try row.get(?i64, 4)) |comments| try writer.print("{d} comments · ", .{comments});
        try writer.print("<a href=\"/history/{d}\">trajectory</a></p></li>", .{story_id});
    }
    try rows.finish(null);
    try writer.writeAll("</ol>");
    try finish(writer, .history, session != null);
    return out.toOwnedSlice();
}

pub fn historyStory(allocator: std.mem.Allocator, store: *database_mod.Store, session: ?Session, story_id: i64) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try start(writer, "Story history · HN Continuity", .history, session != null, "/history");
    var story_rows = try store.connection.queryParams("SELECT COALESCE(title_text,'Story '||?1) FROM item_content WHERE item_id=?1", .{story_id}, .{});
    defer story_rows.deinit();
    const story = (try story_rows.next()) orelse {
        try writer.writeAll("<h1>Story history unavailable</h1><p>This story has not appeared in a captured feed.</p>");
        try finish(writer, .history, session != null);
        return out.toOwnedSlice();
    };
    try writer.writeAll("<h1>History</h1><p class=\"row__title\">");
    try html.text(writer, try story.get([]const u8, 0));
    try writer.print("</p><p><a href=\"/item/{d}\">Open thread</a></p>", .{story_id});
    try story_rows.finish(null);
    var stats_rows = try store.connection.queryParams(
        \\SELECT s.first_rank,s.best_rank,s.last_rank,s.capture_count,first.captured_at,last.captured_at,
        \\(SELECT COUNT(*) FROM feed_captures fc WHERE fc.feed='top' AND fc.id BETWEEN s.first_capture_id AND s.last_capture_id
        \\ AND NOT EXISTS(SELECT 1 FROM feed_entries fe WHERE fe.capture_id=fc.id AND fe.story_id=s.story_id)),
        \\(SELECT COUNT(*) FROM events e WHERE e.kind='feed_milestone' AND e.source_item_id=s.story_id)
        \\FROM story_feed_stats s JOIN feed_captures first ON first.id=s.first_capture_id JOIN feed_captures last ON last.id=s.last_capture_id
        \\WHERE s.story_id=?1 AND s.feed='top'
    , .{story_id}, .{});
    defer stats_rows.deinit();
    if (try stats_rows.next()) |stats| {
        try writer.print("<dl class=\"history-stats\"><div><dt>First rank</dt><dd>{d}</dd></div><div><dt>Best rank</dt><dd>{d}</dd></div><div><dt>Last rank</dt><dd>{d}</dd></div><div><dt>Observations</dt><dd>{d}</dd></div><div><dt>First seen</dt><dd>{d}</dd></div><div><dt>Last seen</dt><dd>{d}</dd></div><div><dt>Missing captures</dt><dd>{d}</dd></div><div><dt>Milestones</dt><dd>{d}</dd></div></dl>", .{ try stats.get(i64, 0), try stats.get(i64, 1), try stats.get(i64, 2), try stats.get(i64, 3), try stats.get(i64, 4), try stats.get(i64, 5), try stats.get(i64, 6), try stats.get(i64, 7) });
        try stats_rows.finish(null);
    }

    const Point = struct { captured_at: i64, rank: i64, score: ?i64, comments: ?i64 };
    var points: std.ArrayList(Point) = .empty;
    defer points.deinit(allocator);
    var rows = try store.connection.queryParams(
        \\SELECT fc.captured_at,fe.rank,fe.score,fe.comment_count FROM feed_entries fe
        \\JOIN feed_captures fc ON fc.id=fe.capture_id WHERE fe.story_id=?1 AND fc.feed='top'
        \\ORDER BY fc.captured_at,fc.id LIMIT 240
    , .{story_id}, .{});
    defer rows.deinit();
    while (try rows.next()) |row| try points.append(allocator, .{
        .captured_at = try row.get(i64, 0),
        .rank = try row.get(i64, 1),
        .score = try row.get(?i64, 2),
        .comments = try row.get(?i64, 3),
    });
    try rows.finish(null);
    if (points.items.len == 0) {
        try writer.writeAll("<p>No top-feed observations exist for this story.</p>");
    } else {
        try writer.writeAll("<svg class=\"trajectory\" viewBox=\"0 0 320 120\" role=\"img\" aria-label=\"Observed front-page rank over time\"><path d=\"M0 0H320M0 40H320M0 80H320M0 119H320\" class=\"trajectory__grid\"/><polyline points=\"");
        for (points.items, 0..) |point, index| {
            const x: i64 = if (points.items.len == 1) 160 else @intCast((index * 320) / (points.items.len - 1));
            const y = @min(@as(i64, 119), @max(@as(i64, 0), (point.rank - 1) * 4));
            try writer.print("{d},{d} ", .{ x, y });
        }
        try writer.writeAll("\" class=\"trajectory__line\"/></svg><p class=\"meta\">Top is rank 1. Gaps between captures are not reconstructed.</p><ol class=\"rows\">");
        var index = points.items.len;
        while (index > 0) {
            index -= 1;
            const point = points.items[index];
            try writer.print("<li class=\"row\"><strong>Rank {d}</strong><p class=\"row__meta\">", .{point.rank});
            if (point.score) |score| try writer.print("{d} points · ", .{score});
            if (point.comments) |comments| try writer.print("{d} comments · ", .{comments});
            try writer.print("observed <time datetime=\"{d}\">{d}</time></p></li>", .{ point.captured_at, point.captured_at });
        }
        try writer.writeAll("</ol>");
    }
    try finish(writer, .history, session != null);
    return out.toOwnedSlice();
}

pub fn thread(allocator: std.mem.Allocator, store: *database_mod.Store, session: ?Session, story_id: i64, focus: ?i64, previous_seen: ?i64) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try start(writer, "Thread · HN Continuity", .thread, session != null, "/news");
    var story_rows = try store.connection.queryParams("SELECT COALESCE(c.title_text,'Item '||i.id),c.url,i.score,i.comment_count,i.author,i.dead,i.deleted FROM items i LEFT JOIN item_content c ON c.item_id=i.id WHERE i.id=?1", .{story_id}, .{});
    defer story_rows.deinit();
    const story = (try story_rows.next()) orelse {
        try writer.writeAll("<h1>Thread unavailable</h1><p>This item has not been materialized locally yet.</p>");
        try story_rows.finish(null);
        try finish(writer, .thread, session != null);
        return out.toOwnedSlice();
    };
    try writer.writeAll("<h1>Thread</h1><article><p class=\"row__title\">");
    try html.text(writer, try story.get([]const u8, 0));
    try writer.writeAll("</p><p class=\"row__meta\">");
    if (try story.get(?i64, 2)) |score| try writer.print("{d} points · ", .{score});
    if (try story.get(?i64, 3)) |comments| try writer.print("{d} comments · ", .{comments});
    if (try story.get(?[]const u8, 4)) |author| try html.text(writer, author);
    try writer.writeAll("</p></article>");
    try story_rows.finish(null);
    if (session) |auth| {
        try writer.print("<form class=\"actions\" method=\"post\" action=\"/watches\"><input type=\"hidden\" name=\"csrf\" value=\"", .{});
        try html.attribute(writer, auth.csrf_token);
        try writer.print("\"><input type=\"hidden\" name=\"scope_kind\" value=\"story\"><input type=\"hidden\" name=\"scope_item_id\" value=\"{d}\"><button class=\"button-accent\">Follow story</button></form>", .{story_id});
    }
    try writer.writeAll("<ol class=\"comment-tree\">");
    var rows = if (focus) |focus_id|
        try store.connection.queryParams(
            \\WITH RECURSIVE tree(id,tree_depth,path) AS (
            \\  SELECT i.id,0,printf('%020d.%020d',COALESCE(i.created_at,0),i.id) FROM items i
            \\  WHERE i.parent_id=?1 AND i.kind='comment'
            \\  UNION ALL
            \\  SELECT i.id,t.tree_depth+1,t.path||'.'||printf('%020d.%020d',COALESCE(i.created_at,0),i.id)
            \\  FROM items i JOIN tree t ON i.parent_id=t.id WHERE i.kind='comment' AND t.tree_depth<63
            \\), ancestors(id) AS (
            \\  SELECT ?2 UNION ALL SELECT i.parent_id FROM items i JOIN ancestors a ON i.id=a.id
            \\  WHERE i.parent_id IS NOT NULL AND i.parent_id!=?1
            \\), descendants(id) AS (
            \\  SELECT ?2 UNION ALL SELECT i.id FROM items i JOIN descendants d ON i.parent_id=d.id
            \\)
            \\SELECT i.id,i.author,i.created_at,t.tree_depth,c.safe_html,i.dead,i.deleted FROM tree t JOIN items i ON i.id=t.id
            \\LEFT JOIN item_content c ON c.item_id=i.id WHERE i.root_story_id=?1
            \\AND i.id IN (SELECT id FROM ancestors UNION SELECT id FROM descendants)
            \\ORDER BY t.path LIMIT 500
        , .{ story_id, focus_id }, .{})
    else
        try store.connection.queryParams(
            \\WITH RECURSIVE tree(id,tree_depth,path) AS (
            \\  SELECT i.id,0,printf('%020d.%020d',COALESCE(i.created_at,0),i.id) FROM items i
            \\  WHERE i.parent_id=?1 AND i.kind='comment'
            \\  UNION ALL
            \\  SELECT i.id,t.tree_depth+1,t.path||'.'||printf('%020d.%020d',COALESCE(i.created_at,0),i.id)
            \\  FROM items i JOIN tree t ON i.parent_id=t.id WHERE i.kind='comment' AND t.tree_depth<63
            \\)
            \\SELECT i.id,i.author,i.created_at,t.tree_depth,c.safe_html,i.dead,i.deleted FROM tree t JOIN items i ON i.id=t.id
            \\LEFT JOIN item_content c ON c.item_id=i.id ORDER BY t.path LIMIT 500
        , .{story_id}, .{});
    defer rows.deinit();
    var prior_depth: ?i64 = null;
    while (try rows.next()) |row| {
        const id = try row.get(i64, 0);
        const depth = try row.get(i64, 3);
        if (prior_depth) |previous| {
            if (depth == previous) {
                try writer.writeAll("</details></li>");
            } else if (depth > previous) {
                try writer.writeAll("<ol>");
            } else {
                try writer.writeAll("</details></li>");
                var current = previous;
                while (current > depth) : (current -= 1) try writer.writeAll("</ol></details></li>");
            }
        }
        const is_new = if (previous_seen) |boundary| id > boundary else false;
        try writer.writeAll("<li class=\"comment");
        if (is_new) try writer.writeAll(" comment--new");
        try writer.print("\" id=\"comment-{d}\"><details open><summary class=\"meta\">", .{id});
        if (is_new) try writer.writeAll("<mark class=\"new-label\">NEW</mark> ");
        try writer.writeAll("<strong>");
        if (try row.get(?[]const u8, 1)) |author| try html.text(writer, author) else try writer.writeAll("[deleted]");
        try writer.print("</strong> · <time datetime=\"{d}\">{d}</time> · <a href=\"/item/{d}?focus={d}#comment-{d}\">focus</a> · <a href=\"https://news.ycombinator.com/item?id={d}\">HN ↗</a></summary><article>", .{ try row.get(?i64, 2) orelse 0, try row.get(?i64, 2) orelse 0, story_id, id, id, id });
        if ((try row.get(i64, 6)) != 0) try writer.writeAll("<p>[deleted]</p>") else if ((try row.get(i64, 5)) != 0) try writer.writeAll("<p>[dead]</p>") else if (try row.get(?[]const u8, 4)) |safe| {
            try writer.writeAll("<div>");
            try writer.writeAll(safe);
            try writer.writeAll("</div>");
        }
        if (session) |auth| {
            try writer.writeAll("<div class=\"actions\"><form method=\"post\" action=\"/watches\"><input type=\"hidden\" name=\"csrf\" value=\"");
            try html.attribute(writer, auth.csrf_token);
            try writer.print("\"><input type=\"hidden\" name=\"scope_kind\" value=\"comment_branch\"><input type=\"hidden\" name=\"scope_item_id\" value=\"{d}\"><button>Follow branch</button></form>", .{id});
            try writer.writeAll("<form method=\"post\" action=\"/watches\"><input type=\"hidden\" name=\"csrf\" value=\"");
            try html.attribute(writer, auth.csrf_token);
            try writer.print("\"><input type=\"hidden\" name=\"scope_kind\" value=\"comment_direct\"><input type=\"hidden\" name=\"scope_item_id\" value=\"{d}\"><button>Follow direct replies</button></form></div>", .{id});
        }
        try writer.writeAll("</article>");
        prior_depth = depth;
    }
    try rows.finish(null);
    if (prior_depth) |last_depth| {
        try writer.writeAll("</details></li>");
        var current = last_depth;
        while (current > 0) : (current -= 1) try writer.writeAll("</ol></details></li>");
    }
    try writer.print("</ol><a class=\"external-action\" href=\"https://news.ycombinator.com/item?id={d}\">Open on Hacker News to reply ↗</a>", .{story_id});
    try finish(writer, .thread, session != null);
    return out.toOwnedSlice();
}

pub fn inbox(allocator: std.mem.Allocator, store: *database_mod.Store, session: Session, show_all: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try start(writer, "Inbox · HN Continuity", .inbox, true, null);
    const unread = try scalarUser(store, "SELECT COUNT(*) FROM notifications WHERE user_id=?1 AND category='inbox' AND suppressed=0 AND dismissed_at IS NULL AND read_at IS NULL", session.user_id);
    try writer.print("<h1>Inbox <span class=\"accent\">({d})</span></h1><nav class=\"segments\"><a", .{unread});
    if (!show_all) try writer.writeAll(" aria-current=\"page\"");
    try writer.writeAll(" href=\"/inbox\">Unread</a><a");
    if (show_all) try writer.writeAll(" aria-current=\"page\"");
    try writer.writeAll(" href=\"/inbox?all=1\">All</a></nav><ol class=\"rows\">");
    const bounds_sql = if (show_all)
        "SELECT COALESCE(MIN(id),0),COALESCE(MAX(id),0) FROM (SELECT id FROM notifications WHERE user_id=?1 AND category='inbox' AND suppressed=0 AND dismissed_at IS NULL ORDER BY id DESC LIMIT 100)"
    else
        "SELECT COALESCE(MIN(id),0),COALESCE(MAX(id),0) FROM (SELECT id FROM notifications WHERE user_id=?1 AND category='inbox' AND suppressed=0 AND dismissed_at IS NULL AND read_at IS NULL ORDER BY id DESC LIMIT 100)";
    var bound_rows = try store.connection.queryParams(bounds_sql, .{session.user_id}, .{});
    defer bound_rows.deinit();
    const bound_row = (try bound_rows.next()).?;
    const min_id = try bound_row.get(i64, 0);
    const max_id = try bound_row.get(i64, 1);
    try bound_rows.finish(null);
    try writer.writeAll("<form class=\"actions\" method=\"post\" action=\"/inbox/read-all\"><input type=\"hidden\" name=\"csrf\" value=\"");
    try html.attribute(writer, session.csrf_token);
    try writer.print("\"><input type=\"hidden\" name=\"from\" value=\"{d}\"><input type=\"hidden\" name=\"through\" value=\"{d}\"><button>Mark shown inbox read</button></form>", .{ min_id, max_id });
    const inbox_sql = if (show_all)
        \\SELECT n.id,n.read_at,e.source_item_id,e.parent_item_id,e.root_story_id,i.author,i.created_at,c.safe_html,sc.title_text,pi.author,pc.safe_html,
        \\COALESCE((SELECT GROUP_CONCAT(reason_kind,', ') FROM notification_reasons WHERE notification_id=n.id),'')
        \\FROM notifications n JOIN events e ON e.id=n.event_id LEFT JOIN items i ON i.id=e.source_item_id
        \\LEFT JOIN item_content c ON c.item_id=i.id LEFT JOIN item_content sc ON sc.item_id=e.root_story_id
        \\LEFT JOIN items pi ON pi.id=e.parent_item_id LEFT JOIN item_content pc ON pc.item_id=e.parent_item_id
        \\WHERE n.user_id=?1 AND n.category='inbox' AND n.suppressed=0 AND n.dismissed_at IS NULL ORDER BY n.id DESC LIMIT 100
    else
        \\SELECT n.id,n.read_at,e.source_item_id,e.parent_item_id,e.root_story_id,i.author,i.created_at,c.safe_html,sc.title_text,pi.author,pc.safe_html,
        \\COALESCE((SELECT GROUP_CONCAT(reason_kind,', ') FROM notification_reasons WHERE notification_id=n.id),'')
        \\FROM notifications n JOIN events e ON e.id=n.event_id LEFT JOIN items i ON i.id=e.source_item_id
        \\LEFT JOIN item_content c ON c.item_id=i.id LEFT JOIN item_content sc ON sc.item_id=e.root_story_id
        \\LEFT JOIN items pi ON pi.id=e.parent_item_id LEFT JOIN item_content pc ON pc.item_id=e.parent_item_id
        \\WHERE n.user_id=?1 AND n.category='inbox' AND n.suppressed=0 AND n.dismissed_at IS NULL AND n.read_at IS NULL ORDER BY n.id DESC LIMIT 100
    ;
    var rows = try store.connection.queryParams(inbox_sql, .{session.user_id}, .{});
    defer rows.deinit();
    while (try rows.next()) |row| {
        const id = try row.get(i64, 0);
        const source_id = try row.get(?i64, 2) orelse 0;
        const root_id = try row.get(?i64, 4) orelse 0;
        try writer.writeAll("<li class=\"row");
        if ((try row.get(?i64, 1)) == null) try writer.writeAll(" row--new");
        try writer.writeAll("\" data-nav-row><article><p class=\"row__title\">");
        if ((try row.get(?i64, 1)) == null) try writer.writeAll("<span class=\"new-label\">NEW</span> ");
        try writer.writeAll("Reply under ");
        if (try row.get(?[]const u8, 8)) |title| try html.text(writer, title) else try writer.print("story {d}", .{root_id});
        try writer.writeAll("</p><div class=\"context\"><p class=\"meta\">You wrote");
        if (try row.get(?[]const u8, 9)) |parent_author| {
            try writer.writeAll(" as ");
            try html.text(writer, parent_author);
        }
        try writer.writeAll("</p>");
        if (try row.get(?[]const u8, 10)) |parent_safe| try writer.writeAll(parent_safe) else try writer.writeAll("<p>[your submission]</p>");
        try writer.writeAll("</div><div class=\"context\"><p class=\"meta\">");
        if (try row.get(?[]const u8, 5)) |author| try html.text(writer, author);
        try writer.writeAll(" replied</p>");
        if (try row.get(?[]const u8, 7)) |safe| try writer.writeAll(safe) else try writer.writeAll("<p>[content unavailable]</p>");
        try writer.print("</div><details><summary>Why this is here</summary><p class=\"meta\">Comment #{d} replies to item #{d} under story #{d}. Matched: ", .{ source_id, try row.get(?i64, 3) orelse 0, root_id });
        const reasons = try row.get([]const u8, 11);
        for (reasons) |byte| try writer.writeByte(if (byte == '_') ' ' else byte);
        try writer.writeAll(".</p></details>");
        try writer.writeAll("<form method=\"post\" action=\"/inbox/");
        try writer.print("{d}/open\"><input type=\"hidden\" name=\"csrf\" value=\"", .{id});
        try html.attribute(writer, session.csrf_token);
        try writer.print("\"><input type=\"hidden\" name=\"return\" value=\"/item/{d}?focus={d}\"><button class=\"button-accent\">View branch</button></form>", .{ root_id, source_id });
        try writer.print("<a class=\"button\" href=\"https://news.ycombinator.com/item?id={d}\">Open on HN ↗</a>", .{source_id});
        if ((try row.get(?i64, 1)) != null) {
            try writer.print("<form method=\"post\" action=\"/inbox/{d}/unread\"><input type=\"hidden\" name=\"csrf\" value=\"", .{id});
            try html.attribute(writer, session.csrf_token);
            try writer.writeAll("\"><button>Mark unread</button></form>");
        }
        try writer.print("<form method=\"post\" action=\"/inbox/{d}/dismiss\"><input type=\"hidden\" name=\"csrf\" value=\"", .{id});
        try html.attribute(writer, session.csrf_token);
        try writer.writeAll("\"><button>Dismiss</button></form>");
        try writer.writeAll("</article></li>");
    }
    try rows.finish(null);
    try writer.writeAll("</ol>");
    try finish(writer, .inbox, true);
    return out.toOwnedSlice();
}

pub fn following(allocator: std.mem.Allocator, store: *database_mod.Store, session: Session, stories_only: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try start(writer, "Following · HN Continuity", .following, true, null);
    try writer.writeAll("<h1>Following</h1><nav class=\"segments\"><a");
    if (!stories_only) try writer.writeAll(" aria-current=\"page\"");
    try writer.writeAll(" href=\"/following\">Branches</a><a");
    if (stories_only) try writer.writeAll(" aria-current=\"page\"");
    try writer.writeAll(" href=\"/following?scope=stories\">Stories</a></nav><ol class=\"rows\">");
    const following_sql = if (stories_only)
        \\SELECT w.id,w.scope_kind,w.scope_item_id,w.root_story_id,w.muted,COALESCE(c.title_text,'Story '||w.root_story_id),
        \\COUNT(DISTINCT CASE WHEN e.id>COALESCE(m.seen_through_event_id,w.created_event_boundary) THEN e.id END),MAX(e.id),
        \\COUNT(DISTINCT CASE WHEN e.id>COALESCE(m.seen_through_event_id,w.created_event_boundary) AND e.parent_item_id=w.scope_item_id THEN e.id END),
        \\COUNT(DISTINCT CASE WHEN e.id>COALESCE(m.seen_through_event_id,w.created_event_boundary) AND e.parent_item_id!=w.scope_item_id THEN e.id END)
        \\FROM watches w LEFT JOIN item_content c ON c.item_id=w.root_story_id
        \\LEFT JOIN notification_reasons r ON r.watch_id=w.id LEFT JOIN notifications n ON n.id=r.notification_id
        \\LEFT JOIN events e ON e.id=n.event_id LEFT JOIN watch_markers m ON m.watch_id=w.id AND m.user_id=w.user_id
        \\WHERE w.user_id=?1 AND w.removed_at IS NULL AND w.scope_kind='story' GROUP BY w.id ORDER BY MAX(e.id) DESC,w.created_at DESC LIMIT 100
    else
        \\SELECT w.id,w.scope_kind,w.scope_item_id,w.root_story_id,w.muted,COALESCE(c.title_text,'Story '||w.root_story_id),
        \\COUNT(DISTINCT CASE WHEN e.id>COALESCE(m.seen_through_event_id,w.created_event_boundary) THEN e.id END),MAX(e.id),
        \\COUNT(DISTINCT CASE WHEN e.id>COALESCE(m.seen_through_event_id,w.created_event_boundary) AND e.parent_item_id=w.scope_item_id THEN e.id END),
        \\COUNT(DISTINCT CASE WHEN e.id>COALESCE(m.seen_through_event_id,w.created_event_boundary) AND e.parent_item_id!=w.scope_item_id THEN e.id END)
        \\FROM watches w LEFT JOIN item_content c ON c.item_id=w.root_story_id
        \\LEFT JOIN notification_reasons r ON r.watch_id=w.id LEFT JOIN notifications n ON n.id=r.notification_id
        \\LEFT JOIN events e ON e.id=n.event_id LEFT JOIN watch_markers m ON m.watch_id=w.id AND m.user_id=w.user_id
        \\WHERE w.user_id=?1 AND w.removed_at IS NULL AND w.scope_kind!='story' GROUP BY w.id ORDER BY MAX(e.id) DESC,w.created_at DESC LIMIT 100
    ;
    var rows = try store.connection.queryParams(following_sql, .{session.user_id}, .{});
    defer rows.deinit();
    while (try rows.next()) |row| {
        const watch_id = try row.get([]const u8, 0);
        const root_id = try row.get(i64, 3);
        const count = try row.get(i64, 6);
        const direct = try row.get(i64, 8);
        const deeper = try row.get(i64, 9);
        try writer.writeAll("<li class=\"row");
        if (count > 0) try writer.writeAll(" row--new");
        try writer.writeAll("\" data-nav-row><p class=\"row__title\"><a href=\"/item/");
        try writer.print("{d}\">", .{root_id});
        try html.text(writer, try row.get([]const u8, 5));
        try writer.writeAll("</a></p><p class=\"row__meta\">");
        try html.text(writer, try row.get([]const u8, 1));
        try writer.print(" · <span class=\"accent\">{d} new comments</span> ({d} direct, {d} deeper)</p><div class=\"actions\"><form method=\"post\" action=\"/watches/", .{ count, direct, deeper });
        try html.attribute(writer, watch_id);
        try writer.writeAll("/seen\"><input type=\"hidden\" name=\"csrf\" value=\"");
        try html.attribute(writer, session.csrf_token);
        try writer.writeAll("\"><button>Mark seen</button></form><form method=\"post\" action=\"/watches/");
        try html.attribute(writer, watch_id);
        try writer.writeAll("/mute\"><input type=\"hidden\" name=\"csrf\" value=\"");
        try html.attribute(writer, session.csrf_token);
        try writer.writeAll("\"><button>");
        try writer.writeAll(if ((try row.get(i64, 4)) != 0) "Unmute" else "Mute");
        try writer.writeAll("</button></form><form method=\"post\" action=\"/watches/");
        try html.attribute(writer, watch_id);
        try writer.writeAll("/remove\"><input type=\"hidden\" name=\"csrf\" value=\"");
        try html.attribute(writer, session.csrf_token);
        try writer.writeAll("\"><button>Unfollow</button></form></div></li>");
    }
    try rows.finish(null);
    try writer.writeAll("</ol>");
    try finish(writer, .following, true);
    return out.toOwnedSlice();
}

pub fn settings(allocator: std.mem.Allocator, store: *database_mod.Store, session: Session, one_time_token: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try start(writer, "Settings · HN Continuity", .settings, true, null);
    try writer.writeAll("<h1>Settings</h1>");
    if (one_time_token) |token| {
        try writer.writeAll("<div class=\"status-banner\"><strong>Copy this private feed token now.</strong><br><code>");
        try html.text(writer, token);
        try writer.writeAll("</code></div>");
    }
    try writer.writeAll("<h2>Tracked HN identities</h2><div class=\"settings\">");
    var identities = try store.connection.queryParams("SELECT h.id,h.username,h.state,j.position,j.limit_value FROM hn_identities h LEFT JOIN background_jobs j ON j.id=h.backfill_job_id WHERE h.user_id=?1 AND h.removed_at IS NULL ORDER BY h.added_at", .{session.user_id}, .{});
    defer identities.deinit();
    while (try identities.next()) |row| {
        try writer.writeAll("<div class=\"row\"><span>");
        try html.text(writer, try row.get([]const u8, 1));
        try writer.writeAll(" <span class=\"meta\">");
        try html.text(writer, try row.get([]const u8, 2));
        if (try row.get(?i64, 3)) |position| try writer.print(" · {d}/{d} inspected", .{ position, try row.get(?i64, 4) orelse 500 });
        try writer.writeAll("</span></span><form method=\"post\" action=\"/settings/identities/");
        try html.attribute(writer, try row.get([]const u8, 0));
        try writer.writeAll("/remove\"><input type=\"hidden\" name=\"csrf\" value=\"");
        try html.attribute(writer, session.csrf_token);
        try writer.writeAll("\"><button>Remove</button></form></div>");
    }
    try identities.finish(null);
    try writer.writeAll("</div><form method=\"post\" action=\"/settings/identities\"><label>HN username <input required maxlength=\"64\" name=\"username\" autocomplete=\"off\"></label><input type=\"hidden\" name=\"csrf\" value=\"");
    try html.attribute(writer, session.csrf_token);
    try writer.writeAll("\"><button class=\"button-accent\">Track this identity</button></form>");
    try writer.writeAll("<h2>Private Atom feeds</h2><form method=\"post\" action=\"/settings/feeds\"><input type=\"hidden\" name=\"csrf\" value=\"");
    try html.attribute(writer, session.csrf_token);
    try writer.writeAll("\"><label>Scope <select name=\"scope\"><option>inbox</option><option>following</option></select></label><button>Create token</button></form>");
    try writer.writeAll("<div class=\"settings\">");
    var tokens = try store.connection.queryParams("SELECT id,scope,label,last_used_at FROM feed_tokens WHERE user_id=?1 AND revoked_at IS NULL ORDER BY created_at", .{session.user_id}, .{});
    defer tokens.deinit();
    while (try tokens.next()) |row| {
        try writer.writeAll("<div class=\"row\"><span>");
        try html.text(writer, try row.get([]const u8, 2));
        try writer.writeAll(" <span class=\"meta\">");
        try html.text(writer, try row.get([]const u8, 1));
        try writer.writeAll("</span></span><form method=\"post\" action=\"/settings/feeds/");
        try html.attribute(writer, try row.get([]const u8, 0));
        try writer.writeAll("/revoke\"><input type=\"hidden\" name=\"csrf\" value=\"");
        try html.attribute(writer, session.csrf_token);
        try writer.writeAll("\"><button>Revoke</button></form></div>");
    }
    try tokens.finish(null);
    try writer.writeAll("</div><h2>Passkeys</h2><button data-passkey-add>Add another passkey</button><div class=\"settings\">");
    var credentials = try store.connection.queryParams("SELECT credential_id,label,created_at,last_used_at FROM auth_credentials WHERE user_id=?1 AND revoked_at IS NULL ORDER BY created_at", .{session.user_id}, .{});
    defer credentials.deinit();
    while (try credentials.next()) |row| {
        try writer.writeAll("<div class=\"row\"><span>");
        try html.text(writer, try row.get([]const u8, 1));
        try writer.print(" <span class=\"meta\">added {d}</span></span><div class=\"actions\"><form method=\"post\" action=\"/settings/passkeys/rename\"><input type=\"hidden\" name=\"csrf\" value=\"", .{try row.get(i64, 2)});
        try html.attribute(writer, session.csrf_token);
        try writer.writeAll("\"><input type=\"hidden\" name=\"credential_id\" value=\"");
        try html.attribute(writer, try row.get([]const u8, 0));
        try writer.writeAll("\"><input aria-label=\"Passkey name\" maxlength=\"64\" name=\"label\" required><button>Rename</button></form><form method=\"post\" action=\"/settings/passkeys/revoke\"><input type=\"hidden\" name=\"csrf\" value=\"");
        try html.attribute(writer, session.csrf_token);
        try writer.writeAll("\"><input type=\"hidden\" name=\"credential_id\" value=\"");
        try html.attribute(writer, try row.get([]const u8, 0));
        try writer.writeAll("\"><button>Revoke</button></form></div></div>");
    }
    try credentials.finish(null);
    try writer.writeAll("</div><h2>Sessions</h2><div class=\"settings\">");
    var sessions = try store.connection.queryParams("SELECT token_hash,COALESCE(label,'Session'),created_at,last_seen_at,expires_at FROM sessions WHERE user_id=?1 AND revoked_at IS NULL ORDER BY last_seen_at DESC", .{session.user_id}, .{});
    defer sessions.deinit();
    while (try sessions.next()) |row| {
        try writer.writeAll("<div class=\"row\"><span>");
        try html.text(writer, try row.get([]const u8, 1));
        try writer.print(" <span class=\"meta\">last used {d}</span></span><form method=\"post\" action=\"/settings/sessions/revoke\"><input type=\"hidden\" name=\"csrf\" value=\"", .{try row.get(i64, 3)});
        try html.attribute(writer, session.csrf_token);
        try writer.writeAll("\"><input type=\"hidden\" name=\"session_hash\" value=\"");
        try html.attribute(writer, try row.get([]const u8, 0));
        try writer.writeAll("\"><button>Revoke</button></form></div>");
    }
    try sessions.finish(null);
    try writer.writeAll("</div>");
    try writer.writeAll("<h2>Data &amp; privacy</h2><div class=\"settings\"><form class=\"row\" method=\"post\" action=\"/settings/export\"><input type=\"hidden\" name=\"csrf\" value=\"");
    try html.attribute(writer, session.csrf_token);
    try writer.writeAll("\"><button>Export my data</button></form><form class=\"row\" method=\"post\" action=\"/auth/logout\"><input type=\"hidden\" name=\"csrf\" value=\"");
    try html.attribute(writer, session.csrf_token);
    try writer.writeAll("\"><button>Sign out</button></form></div>");
    try writer.writeAll("<form method=\"post\" action=\"/settings/delete\"><input type=\"hidden\" name=\"csrf\" value=\"");
    try html.attribute(writer, session.csrf_token);
    try writer.writeAll("\"><label>Type delete to remove private application state <input name=\"confirm\" pattern=\"delete\" required></label><button>Delete account state</button></form>");
    try finish(writer, .settings, true);
    return out.toOwnedSlice();
}

pub fn identityPreview(allocator: std.mem.Allocator, session: Session, username: []const u8, created: ?i64, karma: ?i64) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try start(writer, "Confirm HN identity · HN Continuity", .settings, true, "/settings");
    try writer.writeAll("<h1>Track this public identity?</h1><p class=\"row__title\">");
    try html.text(writer, username);
    try writer.writeAll("</p><p class=\"meta\">");
    if (karma) |value| try writer.print("{d} karma · ", .{value});
    if (created) |value| try writer.print("profile created {d}", .{value});
    try writer.writeAll("</p><p>This does not prove that you own the HN account. It creates a private watch of public activity and inspects at most 500 submitted items.</p><form method=\"post\" action=\"/settings/identities\"><input type=\"hidden\" name=\"csrf\" value=\"");
    try html.attribute(writer, session.csrf_token);
    try writer.writeAll("\"><input type=\"hidden\" name=\"username\" value=\"");
    try html.attribute(writer, username);
    try writer.writeAll("\"><input type=\"hidden\" name=\"confirm\" value=\"yes\"><button class=\"button-accent\">Confirm tracking</button></form>");
    try finish(writer, .settings, true);
    return out.toOwnedSlice();
}

pub fn login(allocator: std.mem.Allocator, message: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try start(writer, "Passkey sign in · HN Continuity", .auth, false, "/news");
    try writer.writeAll("<h1>Continue with a passkey</h1><p>Your HN username is public tracking data, not a login. A separate passkey protects your private continuity state.</p>");
    if (message) |value| {
        try writer.writeAll("<p class=\"status-banner\">");
        try html.text(writer, value);
        try writer.writeAll("</p>");
    }
    try writer.writeAll("<div class=\"actions\"><button class=\"button-accent\" data-passkey-login>Sign in</button><button data-passkey-register>Create account</button></div><p class=\"meta\">Passkey ceremonies require JavaScript; public News, History, and Thread pages do not.</p>");
    try finish(writer, .auth, false);
    return out.toOwnedSlice();
}

fn start(writer: *std.Io.Writer, title: []const u8, page: Page, authenticated: bool, back: ?[]const u8) !void {
    _ = page;
    try html.documentStart(writer, .{
        .title = title,
        .description = "A Hacker News client that remembers where you were and shows exactly what changed.",
        .head = html.TrustedHtml.audited("<link rel=\"stylesheet\" href=\"/assets/app.css\"><script defer src=\"/assets/htmx.js\"></script><script defer src=\"/assets/hx-sse.js\"></script><script defer src=\"/assets/passkeys.js\"></script><script defer src=\"/assets/keyboard.js\"></script>"),
    });
    try writer.writeAll("<a class=\"skip-link\" href=\"#main\">Skip to content</a><header class=\"app-header\">");
    if (back) |href| {
        try writer.writeAll("<a class=\"app-header__back\" href=\"");
        try html.urlAttribute(writer, href);
        try writer.writeAll("\">‹ Back</a>");
    }
    try writer.writeAll("<a class=\"app-brand\" href=\"/news\">HN Continuity</a></header>");
    if (authenticated) try writer.writeAll("<div class=\"live-state\" hx-sse:connect=\"/events\" hx-swap=\"innerHTML\" aria-live=\"polite\"></div>");
    try writer.writeAll("<main id=\"main\">");
}

fn finish(writer: *std.Io.Writer, page: Page, authenticated: bool) !void {
    try writer.writeAll("<p class=\"site-note\">Unofficial Hacker News client; not affiliated with Y Combinator.</p></main><nav class=\"bottom-nav\" aria-label=\"Primary\">");
    try nav(writer, "/news", "News", page == .news or page == .history);
    try nav(writer, if (authenticated) "/inbox" else "/auth/login", "Inbox", page == .inbox);
    try nav(writer, if (authenticated) "/following" else "/auth/login", "Following", page == .following);
    try nav(writer, if (authenticated) "/settings" else "/auth/login", "Settings", page == .settings);
    try writer.writeAll("</nav>");
    try html.documentEnd(writer);
}

fn nav(writer: *std.Io.Writer, href: []const u8, label: []const u8, current: bool) !void {
    try writer.writeAll("<a href=\"");
    try html.urlAttribute(writer, href);
    try writer.writeByte('"');
    if (current) try writer.writeAll(" aria-current=\"page\"");
    try writer.writeByte('>');
    try html.text(writer, label);
    try writer.writeAll("</a>");
}

fn scalarUser(store: *database_mod.Store, sql: []const u8, user_id: []const u8) !i64 {
    var rows = try store.connection.queryParams(sql, .{user_id}, .{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.MissingCount;
    const value = try row.get(i64, 0);
    try rows.finish(null);
    return value;
}

test "login is a complete server-rendered passkey page" {
    const allocator = std.testing.allocator;
    const page = try login(allocator, null);
    defer allocator.free(page);
    try std.testing.expect(std.mem.startsWith(u8, page, "<!doctype html>"));
    try std.testing.expect(std.mem.indexOf(u8, page, "Create account") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "HN username is public tracking data") != null);
}
