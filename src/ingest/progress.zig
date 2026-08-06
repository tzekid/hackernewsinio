const std = @import("std");
const turso = @import("turso");
const database_mod = @import("../store/database.zig");

pub const Cursor = struct {
    processed_through: i64,
    observed_max: i64,
    checked_at: i64,
    advanced_at: i64,
};

pub const Failure = struct {
    item_id: i64,
    error_class: []const u8,
    retry_at: i64,
};

pub fn initialize(store: *database_mod.Store, max_item: i64, now: i64) !void {
    if (max_item < 0) return error.InvalidMaxItem;
    _ = try store.connection.execParams(
        \\INSERT INTO ingest_cursors(stream,processed_through,observed_max,checked_at,advanced_at)
        \\VALUES('hn_items',?1,?1,?2,?2) ON CONFLICT(stream) DO NOTHING
    , .{ max_item, now }, .{});
}

pub fn observe(store: *database_mod.Store, max_item: i64, now: i64) !void {
    const current = try load(store);
    if (max_item < current.processed_through) return error.MaxItemRegression;
    _ = try store.connection.execParams(
        "UPDATE ingest_cursors SET observed_max=MAX(observed_max,?1),checked_at=?2 WHERE stream='hn_items'",
        .{ max_item, now },
        .{},
    );
}

pub fn load(store: *database_mod.Store) !Cursor {
    var rows = try store.connection.query(
        "SELECT processed_through,observed_max,checked_at,advanced_at FROM ingest_cursors WHERE stream='hn_items'",
        &.{},
        .{},
    );
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.CursorNotInitialized;
    const result: Cursor = .{
        .processed_through = try row.get(i64, 0),
        .observed_max = try row.get(i64, 1),
        .checked_at = try row.get(i64, 2),
        .advanced_at = try row.get(i64, 3),
    };
    try rows.finish(null);
    return result;
}

/// Commits the final boundary after every successful item in the contiguous
/// batch was reduced. Missing IDs must be represented by a durable gap row.
pub fn commitBatch(store: *database_mod.Store, start: i64, end: i64, failures: []const Failure, now: i64) !void {
    if (start < 0 or end < start or end - start > 4095) return error.InvalidBatch;
    var diagnostics: turso.Diagnostics = .{};
    var transaction = try store.connection.begin(.immediate, .{ .diagnostics = &diagnostics });
    defer transaction.deinit();
    const current = try scalar(&transaction, "SELECT processed_through FROM ingest_cursors WHERE stream='hn_items'", .{});
    if (start != current + 1) return error.NonContiguousBatch;
    for (failures) |failure| {
        if (failure.item_id < start or failure.item_id > end or failure.error_class.len == 0 or failure.error_class.len > 64) return error.InvalidFailure;
        _ = try transaction.execParams(
            \\INSERT INTO ingest_gaps(item_id,state,error_class,first_failed_at,last_attempt_at,next_attempt_at,attempt_count)
            \\VALUES(?1,'retryable',?2,?3,?3,?4,1)
            \\ON CONFLICT(item_id) DO UPDATE SET state='retryable',error_class=excluded.error_class,last_attempt_at=excluded.last_attempt_at,next_attempt_at=excluded.next_attempt_at,attempt_count=ingest_gaps.attempt_count+1,resolved_at=NULL
        , .{ failure.item_id, failure.error_class, now, failure.retry_at }, .{});
    }
    const covered = try scalar(&transaction,
        \\SELECT COUNT(*) FROM (
        \\ SELECT id AS item_id FROM items WHERE id BETWEEN ?1 AND ?2
        \\ UNION SELECT item_id FROM ingest_gaps WHERE item_id BETWEEN ?1 AND ?2 AND state!='resolved'
        \\)
    , .{ start, end });
    if (covered != end - start + 1) return error.IncompleteBatch;
    _ = try transaction.execParams(
        "UPDATE ingest_cursors SET processed_through=?1,advanced_at=?2 WHERE stream='hn_items' AND processed_through=?3 AND observed_max>=?1",
        .{ end, now, current },
        .{},
    );
    try transaction.commit(&diagnostics);
}

pub fn resolveGap(store: *database_mod.Store, item_id: i64, now: i64) !void {
    const changed = try store.connection.execParams(
        "UPDATE ingest_gaps SET state='resolved',last_attempt_at=?2,resolved_at=?2 WHERE item_id=?1 AND state!='resolved' AND EXISTS(SELECT 1 FROM items WHERE id=?1)",
        .{ item_id, now },
        .{},
    );
    if (changed == 0) return error.GapNotResolvable;
}

fn scalar(transaction: *turso.Transaction, sql: []const u8, params: anytype) !i64 {
    var rows = try transaction.queryParams(sql, params, .{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.MissingRow;
    const value = try row.get(i64, 0);
    try rows.finish(null);
    return value;
}

test "cursor advances only over stored items or durable gaps" {
    const allocator = std.testing.allocator;
    var store = try database_mod.Store.open(allocator, ":memory:");
    defer store.deinit();
    try store.migrate(1);
    try initialize(&store, 10, 2);
    try observe(&store, 12, 3);
    _ = try store.connection.execParams("INSERT INTO items(id,kind,graph_state,source_revision,first_fetched_at,last_fetched_at,dead,deleted) VALUES(11,'story','resolved','x',4,4,0,0)", .{}, .{});
    try std.testing.expectError(error.IncompleteBatch, commitBatch(&store, 11, 12, &.{}, 5));
    try commitBatch(&store, 11, 12, &.{.{ .item_id = 12, .error_class = "null", .retry_at = 15 }}, 5);
    const cursor = try load(&store);
    try std.testing.expectEqual(@as(i64, 12), cursor.processed_through);
    try std.testing.expectError(error.NonContiguousBatch, commitBatch(&store, 11, 12, &.{}, 6));
}
