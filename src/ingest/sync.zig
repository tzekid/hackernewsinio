const std = @import("std");
const database_mod = @import("../store/database.zig");
const client_mod = @import("../hn/client.zig");
const types = @import("../hn/types.zig");
const reducer = @import("reducer.zig");
const progress = @import("progress.zig");
const feeds = @import("feeds.zig");

pub const Options = struct {
    maximum_items: usize = 2048,
    batch_size: usize = 128,
    feed_depth: usize = 30,
    capture_feeds: bool = true,
};

pub const Report = struct {
    initialized_at: ?i64 = null,
    observed_max: i64,
    processed_items: usize = 0,
    gaps_recorded: usize = 0,
    captures: usize = 0,
};

pub fn once(store: *database_mod.Store, allocator: std.mem.Allocator, io: std.Io, hn: client_mod.Client, options: Options) !Report {
    if (options.batch_size == 0 or options.batch_size > 4096 or options.maximum_items > 100_000 or options.feed_depth == 0 or options.feed_depth > 500) return error.InvalidSyncOptions;
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    const max_item = try hn.getMaxItem();
    var report: Report = .{ .observed_max = max_item };
    var cursor = progress.load(store) catch |err| switch (err) {
        error.CursorNotInitialized => initialize: {
            try progress.initialize(store, max_item, now);
            report.initialized_at = max_item;
            break :initialize try progress.load(store);
        },
        else => return err,
    };
    try progress.observe(store, max_item, now);
    cursor.observed_max = @max(cursor.observed_max, max_item);
    try retryGaps(store, allocator, hn, now, &report);

    while (cursor.processed_through < cursor.observed_max and report.processed_items < options.maximum_items) {
        const remaining: i64 = @intCast(options.maximum_items - report.processed_items);
        const batch: i64 = @intCast(options.batch_size);
        const end = @min(cursor.observed_max, @min(cursor.processed_through + batch, cursor.processed_through + remaining));
        var failures: std.ArrayList(progress.Failure) = .empty;
        defer failures.deinit(allocator);
        var item_id = cursor.processed_through + 1;
        while (item_id <= end) : (item_id += 1) {
            var response = hn.getItem(item_id) catch |err| {
                try failures.append(allocator, .{ .item_id = item_id, .error_class = boundedError(err), .retry_at = now + retryDelay(1) });
                continue;
            } orelse {
                try failures.append(allocator, .{ .item_id = item_id, .error_class = "null", .retry_at = now + retryDelay(1) });
                continue;
            };
            defer response.deinit();
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            const source = types.parseItem(arena_state.allocator(), response.body) catch |err| {
                try failures.append(allocator, .{ .item_id = item_id, .error_class = boundedError(err), .retry_at = now + 3600 });
                continue;
            };
            if (source.id != item_id) {
                try failures.append(allocator, .{ .item_id = item_id, .error_class = "id_mismatch", .retry_at = now + 3600 });
                continue;
            }
            _ = try reducer.reduceItem(store, allocator, source, .live, now);
            report.processed_items += 1;
        }
        try progress.commitBatch(store, cursor.processed_through + 1, end, failures.items, now);
        report.gaps_recorded += failures.items.len;
        cursor = try progress.load(store);
    }

    if (options.capture_feeds) {
        inline for (.{ feeds.Feed.top, feeds.Feed.ask, feeds.Feed.show, feeds.Feed.job }) |feed| {
            try captureFeed(store, allocator, hn, feed, options.feed_depth, now, max_item);
            report.captures += 1;
        }
        try reconcileUpdates(store, allocator, hn, now);
    }
    return report;
}

fn retryGaps(store: *database_mod.Store, allocator: std.mem.Allocator, hn: client_mod.Client, now: i64, report: *Report) !void {
    var ids: std.ArrayList(i64) = .empty;
    defer ids.deinit(allocator);
    var rows = try store.connection.queryParams("SELECT item_id FROM ingest_gaps WHERE state='retryable' AND next_attempt_at<=?1 ORDER BY next_attempt_at,item_id LIMIT 64", .{now}, .{});
    defer rows.deinit();
    while (try rows.next()) |row| try ids.append(allocator, try row.get(i64, 0));
    try rows.finish(null);
    for (ids.items) |item_id| {
        var response = (hn.getItem(item_id) catch continue) orelse continue;
        defer response.deinit();
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const item = types.parseItem(arena_state.allocator(), response.body) catch continue;
        if (item.id != item_id) continue;
        _ = reducer.reduceItem(store, allocator, item, .gap_retry, now) catch continue;
        progress.resolveGap(store, item_id, now) catch continue;
        report.processed_items += 1;
    }
}

fn reconcileUpdates(store: *database_mod.Store, allocator: std.mem.Allocator, hn: client_mod.Client, now: i64) !void {
    var response = hn.getUpdates() catch return;
    defer response.deinit();
    const Updates = struct { items: []const i64 = &.{} };
    const parsed = std.json.parseFromSlice(Updates, allocator, response.body, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    for (parsed.value.items[0..@min(parsed.value.items.len, 256)]) |item_id| {
        if (item_id < 0) continue;
        var known_rows = try store.connection.queryParams("SELECT COUNT(*) FROM items WHERE id=?1", .{item_id}, .{});
        const known_row = (try known_rows.next()).?;
        const known = try known_row.get(i64, 0) != 0;
        try known_rows.finish(null);
        known_rows.deinit();
        if (!known) continue;
        var item_response = (hn.getItem(item_id) catch continue) orelse continue;
        defer item_response.deinit();
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const item = types.parseItem(arena_state.allocator(), item_response.body) catch continue;
        _ = reducer.reduceItem(store, allocator, item, .reconcile, now) catch continue;
    }
}

fn captureFeed(store: *database_mod.Store, allocator: std.mem.Allocator, hn: client_mod.Client, feed: feeds.Feed, depth: usize, now: i64, max_item: i64) !void {
    const ids = try hn.getFeed(allocator, feed.text(), depth);
    defer allocator.free(ids);
    var entries: std.ArrayList(feeds.Entry) = .empty;
    defer entries.deinit(allocator);
    for (ids) |item_id| {
        var response = (try hn.getItem(item_id)) orelse continue;
        defer response.deinit();
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const item = types.parseItem(arena_state.allocator(), response.body) catch continue;
        if (item.id != item_id or !(item.kind == .story or item.kind == .job or item.kind == .poll)) continue;
        _ = try reducer.reduceItem(store, allocator, item, .thread_load, now);
        try entries.append(allocator, .{ .story_id = item.id, .score = item.score, .comment_count = item.descendants });
    }
    _ = try feeds.capture(store, allocator, feed, entries.items, depth, now, 0, max_item);
}

fn boundedError(err: anyerror) []const u8 {
    const name = @errorName(err);
    return if (name.len <= 64) name else "upstream_error";
}

fn retryDelay(attempt: usize) i64 {
    return @min(@as(i64, 3600), @as(i64, 15) << @intCast(@min(attempt, 7)));
}
