const std = @import("std");
const database_mod = @import("store/database.zig");
const schema = @import("store/schema.zig");
const client_mod = @import("hn/client.zig");
const sync = @import("ingest/sync.zig");
const progress = @import("ingest/progress.zig");
const server = @import("web/server.zig");
const replay = @import("ingest/replay.zig");

pub fn run(allocator: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, output: *std.Io.Writer, args: []const []const u8) !bool {
    if (args.len == 3 and std.mem.eql(u8, args[1], "init")) {
        try ensureParent(io, args[2]);
        var store = try database_mod.Store.open(allocator, args[2]);
        defer store.deinit();
        try store.migrate(now(io));
        try output.print("initialized schema=v{d} database={s}\n", .{ schema.version, args[2] });
        return true;
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "migrate")) {
        var store = try database_mod.Store.open(allocator, args[2]);
        defer store.deinit();
        try store.migrate(now(io));
        try output.print("migrated schema=v{d}\n", .{try store.migrationVersion()});
        return true;
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "status")) {
        var store = try database_mod.Store.open(allocator, args[2]);
        defer store.deinit();
        try store.requireCurrent();
        try store.integrityCheck();
        const cursor = progress.load(&store) catch null;
        try output.print("schema=v{d} items={d} events={d} notifications={d}", .{ try store.migrationVersion(), try store.count("items"), try store.count("events"), try store.count("notifications") });
        if (cursor) |value| try output.print(" processed_through={d} observed_max={d}", .{ value.processed_through, value.observed_max });
        try output.writeByte('\n');
        return true;
    }
    if ((args.len == 3 or args.len == 4) and std.mem.eql(u8, args[1], "sync")) {
        var store = try database_mod.Store.open(gpa, args[2]);
        defer store.deinit();
        try store.requireCurrent();
        const client = try client_mod.Client.init(gpa, io, if (args.len == 4) args[3] else "https://hacker-news.firebaseio.com/v0");
        const report = try sync.once(&store, gpa, io, client, .{});
        try output.print("observed_max={d} processed={d} gaps={d} captures={d}\n", .{ report.observed_max, report.processed_items, report.gaps_recorded, report.captures });
        return true;
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "serve")) {
        var host: []const u8 = "127.0.0.1";
        var port: u16 = 8080;
        var base: []const u8 = "https://hacker-news.firebaseio.com/v0";
        var origin: ?[]const u8 = null;
        var rp_id: ?[]const u8 = null;
        var secure = false;
        var index: usize = 3;
        while (index < args.len) {
            if (std.mem.eql(u8, args[index], "--listen")) {
                index += 1;
                if (index >= args.len) return error.MissingServeValue;
                const separator = std.mem.lastIndexOfScalar(u8, args[index], ':') orelse return error.InvalidListen;
                host = args[index][0..separator];
                port = try std.fmt.parseInt(u16, args[index][separator + 1 ..], 10);
            } else if (std.mem.eql(u8, args[index], "--hn-base")) {
                index += 1;
                if (index >= args.len) return error.MissingServeValue;
                base = args[index];
            } else if (std.mem.eql(u8, args[index], "--origin")) {
                index += 1;
                if (index >= args.len) return error.MissingServeValue;
                origin = args[index];
            } else if (std.mem.eql(u8, args[index], "--rp-id")) {
                index += 1;
                if (index >= args.len) return error.MissingServeValue;
                rp_id = args[index];
            } else if (std.mem.eql(u8, args[index], "--secure")) {
                secure = true;
            } else return error.InvalidServeOption;
            index += 1;
        }
        var origin_buffer: [512]u8 = undefined;
        const resolved_origin = origin orelse try std.fmt.bufPrint(&origin_buffer, "http://{s}:{d}", .{ host, port });
        try server.run(gpa, io, .{ .host = host, .port = port, .database_path = args[2], .hn_base_url = base, .canonical_origin = resolved_origin, .rp_id = rp_id orelse host, .secure_transport = secure });
        return true;
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "dev-session")) {
        var store = try database_mod.Store.open(allocator, args[2]);
        defer store.deinit();
        try store.requireCurrent();
        var raw_user: [24]u8 = undefined;
        var raw_session: [24]u8 = undefined;
        var raw_csrf: [24]u8 = undefined;
        io.random(&raw_user);
        io.random(&raw_session);
        io.random(&raw_csrf);
        const user = std.fmt.bytesToHex(raw_user, .lower);
        const session_token = std.fmt.bytesToHex(raw_session, .lower);
        const csrf = std.fmt.bytesToHex(raw_csrf, .lower);
        const session_hash = hash(&session_token);
        const csrf_hash = hash(&csrf);
        const current = now(io);
        _ = try store.connection.execParams("INSERT INTO app_users(id,created_at) VALUES(?1,?2)", .{ &user, current }, .{});
        _ = try store.connection.execParams("INSERT INTO sessions(token_hash,user_id,csrf_hash,created_at,last_seen_at,expires_at,label) VALUES(?1,?2,?3,?4,?4,?5,'Development session')", .{ &session_hash, &user, &csrf_hash, current, current + 86400 }, .{});
        try output.print("hnc_session={s}; hnc_csrf={s}\n", .{ session_token, csrf });
        return true;
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "backup")) {
        var store = try database_mod.Store.open(allocator, args[2]);
        defer store.deinit();
        try store.requireCurrent();
        try store.integrityCheck();
        try store.checkpoint();
        try ensureParent(io, args[3]);
        try copyNew(io, args[2], args[3]);
        var backup_store = try database_mod.Store.open(allocator, args[3]);
        defer backup_store.deinit();
        try backup_store.requireCurrent();
        try backup_store.integrityCheck();
        try output.print("backup verified and written to {s}\n", .{args[3]});
        return true;
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "restore")) {
        var backup_store = try database_mod.Store.open(allocator, args[2]);
        defer backup_store.deinit();
        try backup_store.requireCurrent();
        try backup_store.integrityCheck();
        try ensureParent(io, args[3]);
        try copyNew(io, args[2], args[3]);
        var restored_store = try database_mod.Store.open(allocator, args[3]);
        defer restored_store.deinit();
        try restored_store.requireCurrent();
        try restored_store.integrityCheck();
        try output.print("restore verified and written to {s}\n", .{args[3]});
        return true;
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "replay")) {
        var store = try database_mod.Store.open(allocator, args[2]);
        defer store.deinit();
        try store.requireCurrent();
        const count = try replay.file(&store, allocator, io, args[3], now(io));
        try output.print("replayed items={d} events={d} notifications={d}\n", .{ count, try store.count("events"), try store.count("notifications") });
        return true;
    }
    return false;
}

pub fn usage(output: *std.Io.Writer) !void {
    try output.writeAll(
        \\  hn-continuity init <database>
        \\  hn-continuity migrate <database>
        \\  hn-continuity status <database>
        \\  hn-continuity sync <database> [HN-base-URL]
        \\  hn-continuity serve <database> [--listen 127.0.0.1:8080] [--hn-base URL] [--origin URL] [--rp-id host] [--secure]
        \\  hn-continuity backup <database> <new-destination>
        \\  hn-continuity restore <backup> <new-destination>
        \\  hn-continuity replay <database> <items.ndjson>
        \\  hn-continuity dev-session <database>
        \\
    );
}

fn ensureParent(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;
    try std.Io.Dir.cwd().createDirPath(io, parent);
}

fn copyNew(io: std.Io, source: []const u8, destination: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const source_file = try cwd.openFile(io, source, .{});
    defer source_file.close(io);
    const destination_file = try cwd.createFile(io, destination, .{ .exclusive = true, .permissions = @fromBackingInt(@intCast(0o600)) });
    defer destination_file.close(io);
    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = source_file.reader(io, &read_buffer);
    var write_buffer: [64 * 1024]u8 = undefined;
    var writer = destination_file.writer(io, &write_buffer);
    _ = try reader.interface.streamRemaining(&writer.interface);
    try writer.interface.flush();
}

fn hash(value: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn now(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}
