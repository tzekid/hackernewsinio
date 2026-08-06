const std = @import("std");
const turso = @import("turso");
const database_mod = @import("../store/database.zig");

pub const Feed = enum {
    top,
    ask,
    show,
    job,

    pub fn text(self: Feed) []const u8 {
        return @tagName(self);
    }
};

pub const Entry = struct {
    story_id: i64,
    score: ?i64 = null,
    comment_count: ?i64 = null,
};

pub fn capture(store: *database_mod.Store, allocator: std.mem.Allocator, feed: Feed, entries: []const Entry, depth: usize, captured_at: i64, duration_ms: i64, max_item: ?i64) !i64 {
    if (depth == 0 or depth > 500 or entries.len > depth or duration_ms < 0) return error.InvalidCapture;
    var diagnostics: turso.Diagnostics = .{};
    var transaction = try store.connection.begin(.immediate, .{ .diagnostics = &diagnostics });
    defer transaction.deinit();
    const hash = sourceHash(entries);
    _ = try transaction.execParams(
        "INSERT INTO feed_captures(feed,captured_at,depth,entry_count,source_hash,duration_ms,source_maxitem) VALUES(?1,?2,?3,?4,?5,?6,?7)",
        .{ feed.text(), captured_at, depth, entries.len, &hash, duration_ms, max_item },
        .{},
    );
    const capture_id = try scalar(&transaction, "SELECT id FROM feed_captures WHERE feed=?1 AND captured_at=?2", .{ feed.text(), captured_at });
    var started_storage: [32]u8 = undefined;
    const started = try std.fmt.bufPrint(&started_storage, "{d}", .{captured_at});
    _ = try transaction.execParams("INSERT INTO runtime_state(key,value,updated_at) VALUES('authoritative_history_started_at',?1,?2) ON CONFLICT(key) DO NOTHING", .{ started, captured_at }, .{});
    for (entries, 1..) |entry, rank| {
        if (entry.story_id < 0) return error.InvalidStoryId;
        const previous = try priorBestRank(&transaction, entry.story_id, feed.text());
        _ = try transaction.execParams(
            "INSERT INTO feed_entries(capture_id,story_id,rank,score,comment_count) VALUES(?1,?2,?3,?4,?5)",
            .{ capture_id, entry.story_id, rank, entry.score, entry.comment_count },
            .{},
        );
        _ = try transaction.execParams(
            \\INSERT INTO story_feed_stats(story_id,feed,first_capture_id,last_capture_id,first_rank,best_rank,last_rank,capture_count)
            \\VALUES(?1,?2,?3,?3,?4,?4,?4,1)
            \\ON CONFLICT(story_id,feed) DO UPDATE SET last_capture_id=excluded.last_capture_id,best_rank=MIN(story_feed_stats.best_rank,excluded.best_rank),last_rank=excluded.last_rank,capture_count=story_feed_stats.capture_count+1
        , .{ entry.story_id, feed.text(), capture_id, rank }, .{});
        if (previous == null) try feedEvent(&transaction, allocator, "feed_first_observed", entry.story_id, feed.text(), rank, captured_at, capture_id, "first");
        if (crossed(previous, rank, 20)) try feedEvent(&transaction, allocator, "feed_milestone", entry.story_id, feed.text(), rank, captured_at, capture_id, "top20");
        if (crossed(previous, rank, 10)) try feedEvent(&transaction, allocator, "feed_milestone", entry.story_id, feed.text(), rank, captured_at, capture_id, "top10");
    }
    try transaction.commit(&diagnostics);
    return capture_id;
}

fn feedEvent(transaction: *turso.Transaction, allocator: std.mem.Allocator, kind: []const u8, story_id: i64, feed: []const u8, rank: usize, now: i64, capture_id: i64, milestone: []const u8) !void {
    const key = try std.fmt.allocPrint(allocator, "{s}:{s}:{d}:{s}", .{ kind, feed, story_id, milestone });
    defer allocator.free(key);
    const revision = try std.fmt.allocPrint(allocator, "capture:{d}:rank:{d}", .{ capture_id, rank });
    defer allocator.free(revision);
    _ = try transaction.execParams(
        \\INSERT INTO events(event_key,kind,source_item_id,root_story_id,relevant_item_id,source_revision,occurred_at,detected_at,source_class)
        \\VALUES(?1,?2,?3,?3,?3,?4,?5,?5,'feed_capture') ON CONFLICT(event_key) DO NOTHING
    , .{ key, kind, story_id, revision, now }, .{});
}

fn crossed(previous: ?i64, rank: usize, threshold: i64) bool {
    return @as(i64, @intCast(rank)) <= threshold and (previous == null or previous.? > threshold);
}

fn priorBestRank(transaction: *turso.Transaction, story_id: i64, feed: []const u8) !?i64 {
    var rows = try transaction.queryParams("SELECT best_rank FROM story_feed_stats WHERE story_id=?1 AND feed=?2", .{ story_id, feed }, .{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return null;
    const value = try row.get(i64, 0);
    try rows.finish(null);
    return value;
}

fn scalar(transaction: *turso.Transaction, sql: []const u8, params: anytype) !i64 {
    var rows = try transaction.queryParams(sql, params, .{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.MissingRow;
    const value = try row.get(i64, 0);
    try rows.finish(null);
    return value;
}

fn sourceHash(entries: []const Entry) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (entries) |entry| {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &bytes, entry.story_id, .little);
        hasher.update(&bytes);
    }
    var raw: [32]u8 = undefined;
    hasher.final(&raw);
    return std.fmt.bytesToHex(raw, .lower);
}

test "feed captures preserve exact ranks and one-time milestones" {
    const allocator = std.testing.allocator;
    var store = try database_mod.Store.open(allocator, ":memory:");
    defer store.deinit();
    try store.migrate(1);
    const first = try capture(&store, allocator, .top, &.{ .{ .story_id = 100 }, .{ .story_id = 200 } }, 30, 1000, 12, 999);
    _ = try capture(&store, allocator, .top, &.{ .{ .story_id = 200 }, .{ .story_id = 100 } }, 30, 1300, 10, 1000);
    try std.testing.expectEqual(@as(i64, 1), first);
    var rows = try store.connection.query("SELECT best_rank,capture_count FROM story_feed_stats WHERE story_id=200 AND feed='top'", &.{}, .{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    try std.testing.expectEqual(@as(i64, 1), try row.get(i64, 0));
    try std.testing.expectEqual(@as(i64, 2), try row.get(i64, 1));
    try rows.finish(null);
}
