const std = @import("std");
const database_mod = @import("../store/database.zig");
const client_mod = @import("../hn/client.zig");
const backfill = @import("backfill.zig");

pub fn enqueueIdentity(store: *database_mod.Store, identity_id: []const u8, user_id: []const u8, username: []const u8, now: i64) !void {
    var job_id_storage: [96]u8 = undefined;
    const job_id = try std.fmt.bufPrint(&job_id_storage, "identity-backfill:{s}", .{identity_id});
    _ = try store.connection.execParams(
        \\INSERT INTO background_jobs(id,kind,owner_user_id,subject,state,limit_value,created_at,updated_at)
        \\VALUES(?1,'identity_backfill',?2,?3,'pending',500,?4,?4) ON CONFLICT(id) DO NOTHING
    , .{ job_id, user_id, username, now }, .{});
    _ = try store.connection.execParams(
        "UPDATE hn_identities SET state='backfilling',backfill_job_id=?2 WHERE id=?1 AND removed_at IS NULL",
        .{ identity_id, job_id },
        .{},
    );
}

pub fn enqueueThread(store: *database_mod.Store, story_id: i64, now: i64) !void {
    _ = try store.connection.execParams(
        \\INSERT INTO thread_backfills(story_id,state,limit_value,created_at,updated_at)
        \\VALUES(?1,'pending',500,?2,?2)
        \\ON CONFLICT(story_id) DO UPDATE SET
        \\  state=CASE WHEN thread_backfills.state='failed' THEN 'pending' ELSE thread_backfills.state END,
        \\  attempt_count=CASE WHEN thread_backfills.state='failed' THEN 0 ELSE thread_backfills.attempt_count END,
        \\  last_error_class=CASE WHEN thread_backfills.state='failed' THEN NULL ELSE thread_backfills.last_error_class END,
        \\  started_at=CASE WHEN thread_backfills.state='failed' THEN NULL ELSE thread_backfills.started_at END,
        \\  updated_at=CASE WHEN thread_backfills.state='failed' THEN excluded.updated_at ELSE thread_backfills.updated_at END,
        \\  finished_at=CASE WHEN thread_backfills.state='failed' THEN NULL ELSE thread_backfills.finished_at END
    , .{ story_id, now }, .{});
}

pub fn runOne(store: *database_mod.Store, allocator: std.mem.Allocator, hn: client_mod.Client, now: i64) !bool {
    if (try runOneThread(store, allocator, hn, now)) return true;
    return runOneIdentity(store, allocator, hn, now);
}

fn runOneThread(store: *database_mod.Store, allocator: std.mem.Allocator, hn: client_mod.Client, now: i64) !bool {
    var rows = try store.connection.query(
        "SELECT story_id,attempt_count,limit_value FROM thread_backfills WHERE state IN ('pending','running') ORDER BY updated_at,story_id LIMIT 1",
        &.{},
        .{},
    );
    defer rows.deinit();
    const row = (try rows.next()) orelse return false;
    const story_id = try row.get(i64, 0);
    const attempt = try row.get(i64, 1) + 1;
    const limit: usize = @intCast(try row.get(i64, 2));
    try rows.finish(null);
    _ = try store.connection.execParams(
        "UPDATE thread_backfills SET state='running',attempt_count=?2,started_at=COALESCE(started_at,?3),updated_at=?3 WHERE story_id=?1",
        .{ story_id, attempt, now },
        .{},
    );
    const count = backfill.thread(store, allocator, hn, story_id, limit, now) catch |err| {
        const terminal = attempt >= 5;
        _ = try store.connection.execParams(
            "UPDATE thread_backfills SET state=?2,last_error_class=?3,updated_at=?4,finished_at=CASE WHEN ?5 THEN ?4 ELSE NULL END WHERE story_id=?1",
            .{ story_id, if (terminal) "failed" else "pending", @errorName(err), now, @as(i64, if (terminal) 1 else 0) },
            .{},
        );
        return true;
    };
    _ = try store.connection.execParams(
        "UPDATE thread_backfills SET state='succeeded',position=?2,last_error_class=NULL,updated_at=?3,finished_at=?3 WHERE story_id=?1",
        .{ story_id, count, now },
        .{},
    );
    return true;
}

fn runOneIdentity(store: *database_mod.Store, allocator: std.mem.Allocator, hn: client_mod.Client, now: i64) !bool {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rows = try store.connection.query(
        "SELECT id,subject,attempt_count,limit_value FROM background_jobs WHERE kind='identity_backfill' AND state IN ('pending','running') ORDER BY updated_at,id LIMIT 1",
        &.{},
        .{},
    );
    defer rows.deinit();
    const row = (try rows.next()) orelse return false;
    const job_id = try arena.dupe(u8, try row.get([]const u8, 0));
    const username = try arena.dupe(u8, try row.get([]const u8, 1));
    const attempt = try row.get(i64, 2) + 1;
    const limit: usize = @intCast(try row.get(i64, 3));
    try rows.finish(null);
    _ = try store.connection.execParams(
        "UPDATE background_jobs SET state='running',attempt_count=?2,started_at=COALESCE(started_at,?3),updated_at=?3 WHERE id=?1",
        .{ job_id, attempt, now },
        .{},
    );
    const count = backfill.identity(store, allocator, hn, username, limit, now) catch |err| {
        const terminal = attempt >= 5;
        _ = try store.connection.execParams(
            "UPDATE background_jobs SET state=?2,last_error_class=?3,updated_at=?4,finished_at=CASE WHEN ?5 THEN ?4 ELSE NULL END WHERE id=?1",
            .{ job_id, if (terminal) "failed" else "pending", @errorName(err), now, @as(i64, if (terminal) 1 else 0) },
            .{},
        );
        if (terminal) _ = try store.connection.execParams("UPDATE hn_identities SET state='error' WHERE backfill_job_id=?1 AND removed_at IS NULL", .{job_id}, .{});
        return true;
    };
    _ = try store.connection.execParams(
        "UPDATE background_jobs SET state='succeeded',position=?2,last_error_class=NULL,updated_at=?3,finished_at=?3 WHERE id=?1",
        .{ job_id, count, now },
        .{},
    );
    _ = try store.connection.execParams("UPDATE hn_identities SET state='active' WHERE backfill_job_id=?1 AND removed_at IS NULL", .{job_id}, .{});
    return true;
}
