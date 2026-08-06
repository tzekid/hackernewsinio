const std = @import("std");
const turso = @import("turso");
const schema = @import("schema.zig");
const app_version = @import("../version.zig").value;

pub const Store = struct {
    database: turso.Database,
    connection: turso.Connection,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Store {
        var database = try turso.Database.open(allocator, .{ .path = path });
        errdefer database.deinit();
        const connection = try database.connect(.{ .busy_timeout_ms = 5_000 });
        return .{ .database = database, .connection = connection };
    }

    pub fn deinit(self: *Store) void {
        self.connection.deinit();
        self.database.deinit();
    }

    pub fn migrate(self: *Store, now: i64) !void {
        var diagnostics: turso.Diagnostics = .{};
        _ = self.connection.execBatch(schema.bootstrap, .{ .diagnostics = &diagnostics }) catch |err| {
            std.log.err("schema bootstrap failed: {s}", .{diagnostics.text()});
            return err;
        };
        const current = try self.migrationVersion();
        if (current > schema.version) return error.NewerSchema;
        if (current < 1) {
            var transaction = try self.connection.begin(.immediate, .{ .diagnostics = &diagnostics });
            defer transaction.deinit();
            _ = transaction.execBatch(schema.migration_1, .{ .diagnostics = &diagnostics }) catch |err| {
                std.log.err("schema migration 1 failed: {s}", .{diagnostics.text()});
                return err;
            };
            _ = transaction.execParams(
                "INSERT INTO schema_migrations(version,name,applied_at,app_version) VALUES(1,'initial-continuity-ledgers',?1,?2)",
                .{ now, app_version },
                .{ .diagnostics = &diagnostics },
            ) catch |err| {
                std.log.err("schema migration record failed: {s}", .{diagnostics.text()});
                return err;
            };
            try transaction.commit(&diagnostics);
        }
        try self.requireCurrent();
    }

    pub fn requireCurrent(self: *Store) !void {
        const current = try self.migrationVersion();
        if (current > schema.version) return error.NewerSchema;
        if (current < schema.version) return error.MigrationRequired;
    }

    pub fn migrationVersion(self: *Store) !i64 {
        var rows = try self.connection.query(
            "SELECT COALESCE(MAX(version),0) FROM schema_migrations",
            &.{},
            .{},
        );
        defer rows.deinit();
        const row = (try rows.next()) orelse return error.MissingMigrationVersion;
        const value = try row.get(i64, 0);
        try rows.finish(null);
        return value;
    }

    pub fn integrityCheck(self: *Store) !void {
        var rows = try self.connection.query("PRAGMA integrity_check", &.{}, .{});
        defer rows.deinit();
        const row = (try rows.next()) orelse return error.MissingIntegrityRow;
        if (!std.mem.eql(u8, try row.get([]const u8, 0), "ok")) return error.IntegrityFailed;
        if ((try rows.next()) != null) return error.UnexpectedIntegrityRow;
        try rows.finish(null);
    }

    pub fn checkpoint(self: *Store) !void {
        var rows = try self.connection.query("PRAGMA wal_checkpoint(TRUNCATE)", &.{}, .{});
        defer rows.deinit();
        const row = (try rows.next()) orelse return error.MissingCheckpointRow;
        if (try row.get(i64, 0) != 0) return error.CheckpointBusy;
        try rows.finish(null);
    }

    pub fn count(self: *Store, table: []const u8) !i64 {
        const sql = if (std.mem.eql(u8, table, "items"))
            "SELECT COUNT(*) FROM items"
        else if (std.mem.eql(u8, table, "events"))
            "SELECT COUNT(*) FROM events"
        else if (std.mem.eql(u8, table, "notifications"))
            "SELECT COUNT(*) FROM notifications"
        else
            return error.InvalidTable;
        var rows = try self.connection.query(sql, &.{}, .{});
        defer rows.deinit();
        const row = (try rows.next()) orelse return error.MissingCount;
        const value = try row.get(i64, 0);
        try rows.finish(null);
        return value;
    }
};

test "migration is durable and idempotent" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "continuity.db" });
    defer allocator.free(path);

    var store = try Store.open(allocator, path);
    defer store.deinit();
    try store.migrate(1_700_000_000);
    try store.migrate(1_700_000_001);
    try std.testing.expectEqual(schema.version, try store.migrationVersion());
    try store.integrityCheck();
    try std.testing.expectEqual(@as(i64, 0), try store.count("items"));
}
