const std = @import("std");
const turso = @import("turso");
const hn = @import("../hn/types.zig");
const sanitize = @import("../hn/sanitize.zig");
const database_mod = @import("../store/database.zig");

pub const SourceClass = enum {
    live,
    gap_retry,
    backfill,
    thread_load,
    reconcile,

    pub fn text(self: SourceClass) []const u8 {
        return @tagName(self);
    }
};

pub const Result = struct {
    graph_state: GraphState,
    event_id: ?i64,
    notification_count: usize,
};

pub const GraphState = enum {
    resolved,
    unresolved_parent,
    unresolved_root,
    invalid,

    pub fn text(self: GraphState) []const u8 {
        return @tagName(self);
    }
};

const Graph = struct {
    state: GraphState,
    root_story_id: ?i64,
    depth: ?i64,
    parent_author: ?[]u8,
    parent_kind: ?hn.Kind,
    ancestors: []i64,
};

const Match = struct {
    user_id: []u8,
    category: enum { inbox, following },
    reason_kind: []const u8,
    tracked_identity_id: ?[]u8 = null,
    watch_id: ?[]u8 = null,
    relevant_item_id: i64,
    suppressed: bool,
};

pub fn reduceItem(
    store: *database_mod.Store,
    allocator: std.mem.Allocator,
    item: hn.SourceItem,
    source_class: SourceClass,
    detected_at: i64,
) !Result {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostics: turso.Diagnostics = .{};
    var transaction = try store.connection.begin(.immediate, .{ .diagnostics = &diagnostics });
    defer transaction.deinit();

    const previous_revision = try previousRevision(&transaction, arena, item.id);
    const graph = try resolveGraph(&transaction, arena, item);
    try upsertItem(&transaction, arena, item, graph, detected_at);

    var event_id: ?i64 = null;
    var notification_count: usize = 0;
    if (item.kind == .comment and graph.state == .resolved) {
        event_id = try ensureEvent(
            &transaction,
            arena,
            "comment_created",
            try std.fmt.allocPrint(arena, "comment-created:{d}", .{item.id}),
            item,
            graph.root_story_id,
            null,
            source_class.text(),
            detected_at,
        );
        notification_count = try projectComment(&transaction, arena, item, graph, event_id.?, detected_at);
    }
    if (previous_revision) |before| if (!std.mem.eql(u8, before, &item.revision)) {
        _ = try ensureEvent(
            &transaction,
            arena,
            "item_state_changed",
            try std.fmt.allocPrint(arena, "item-state:{d}:{s}", .{ item.id, item.revision }),
            item,
            graph.root_story_id,
            item.id,
            source_class.text(),
            detected_at,
        );
    };

    try transaction.commit(&diagnostics);
    return .{
        .graph_state = graph.state,
        .event_id = event_id,
        .notification_count = notification_count,
    };
}

fn resolveGraph(transaction: *turso.Transaction, allocator: std.mem.Allocator, item: hn.SourceItem) !Graph {
    if (item.kind == .story or item.kind == .job or item.kind == .poll) return .{
        .state = .resolved,
        .root_story_id = item.id,
        .depth = 0,
        .parent_author = null,
        .parent_kind = null,
        .ancestors = &.{},
    };
    const parent_id = item.parent_id orelse return .{
        .state = .invalid,
        .root_story_id = null,
        .depth = null,
        .parent_author = null,
        .parent_kind = null,
        .ancestors = &.{},
    };
    var ancestors: std.ArrayList(i64) = .empty;
    var cursor = parent_id;
    var parent_author: ?[]u8 = null;
    var parent_kind: ?hn.Kind = null;
    var resolved_root: ?i64 = null;
    var resolved_depth: ?i64 = null;
    var hops: i64 = 1;
    while (hops <= 4096) : (hops += 1) {
        try ancestors.append(allocator, cursor);
        var rows = try transaction.queryParams(
            "SELECT kind,author,parent_id,root_story_id,depth FROM items WHERE id=?1",
            .{cursor},
            .{},
        );
        defer rows.deinit();
        const row = (try rows.next()) orelse return .{
            .state = if (cursor == parent_id) .unresolved_parent else .unresolved_root,
            .root_story_id = null,
            .depth = null,
            .parent_author = parent_author,
            .parent_kind = parent_kind,
            .ancestors = try ancestors.toOwnedSlice(allocator),
        };
        const kind_text = try row.get([]const u8, 0);
        const kind = std.meta.stringToEnum(hn.Kind, kind_text) orelse return error.InvalidStoredKind;
        if (cursor == parent_id) {
            if (!(try row.get(?[]const u8, 1) == null)) parent_author = try allocator.dupe(u8, (try row.get(?[]const u8, 1)).?);
            parent_kind = kind;
        }
        const parent = try row.get(?i64, 2);
        const root = try row.get(?i64, 3);
        const depth = try row.get(?i64, 4);
        if (kind == .story or kind == .job or kind == .poll) {
            resolved_root = cursor;
            resolved_depth = hops;
            try rows.finish(null);
            break;
        }
        if (root != null and depth != null) {
            resolved_root = root;
            resolved_depth = depth.? + hops;
            try rows.finish(null);
            break;
        }
        const next = parent orelse return .{
            .state = .unresolved_root,
            .root_story_id = null,
            .depth = null,
            .parent_author = parent_author,
            .parent_kind = parent_kind,
            .ancestors = try ancestors.toOwnedSlice(allocator),
        };
        try rows.finish(null);
        cursor = next;
    }
    if (resolved_root == null) return .{
        .state = .invalid,
        .root_story_id = null,
        .depth = null,
        .parent_author = parent_author,
        .parent_kind = parent_kind,
        .ancestors = try ancestors.toOwnedSlice(allocator),
    };
    return .{
        .state = .resolved,
        .root_story_id = resolved_root,
        .depth = resolved_depth,
        .parent_author = parent_author,
        .parent_kind = parent_kind,
        .ancestors = try ancestors.toOwnedSlice(allocator),
    };
}

fn upsertItem(transaction: *turso.Transaction, allocator: std.mem.Allocator, item: hn.SourceItem, graph: Graph, fetched_at: i64) !void {
    _ = try transaction.execParams(
        \\INSERT INTO items(id,kind,author,created_at,parent_id,root_story_id,depth,score,comment_count,dead,deleted,graph_state,source_revision,first_fetched_at,last_fetched_at,materialization_reason)
        \\VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?14,?15)
        \\ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,author=excluded.author,created_at=excluded.created_at,parent_id=excluded.parent_id,root_story_id=excluded.root_story_id,depth=excluded.depth,score=excluded.score,comment_count=excluded.comment_count,dead=excluded.dead,deleted=excluded.deleted,graph_state=excluded.graph_state,source_revision=excluded.source_revision,last_fetched_at=excluded.last_fetched_at,materialization_reason=COALESCE(excluded.materialization_reason,items.materialization_reason)
    , .{ item.id, item.kind.text(), item.author, item.time, item.parent_id, graph.root_story_id, graph.depth, item.score, item.descendants, item.dead, item.deleted, graph.state.text(), &item.revision, fetched_at, if (item.title != null or item.text_html != null) "source" else null }, .{});

    if (item.title != null or item.url != null or item.text_html != null) {
        const safe = if (item.text_html) |source| try sanitize.html(allocator, source) else try allocator.dupe(u8, "");
        const safe_hash = digest(safe);
        const valid_url: ?[]const u8 = if (item.url) |url| if (sanitize.validExternalUrl(url)) url else null else null;
        _ = try transaction.execParams(
            \\INSERT INTO item_content(item_id,title_text,url,source_html,safe_html,sanitizer_version,source_hash,safe_hash,materialized_at)
            \\VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)
            \\ON CONFLICT(item_id) DO UPDATE SET title_text=excluded.title_text,url=excluded.url,source_html=excluded.source_html,safe_html=excluded.safe_html,sanitizer_version=excluded.sanitizer_version,source_hash=excluded.source_hash,safe_hash=excluded.safe_hash,materialized_at=excluded.materialized_at
        , .{ item.id, item.title, valid_url, item.text_html, safe, sanitize.version, &item.revision, &safe_hash, fetched_at }, .{});
    }
}

fn previousRevision(transaction: *turso.Transaction, allocator: std.mem.Allocator, item_id: i64) !?[]u8 {
    var rows = try transaction.queryParams("SELECT source_revision FROM items WHERE id=?1", .{item_id}, .{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return null;
    const value = try allocator.dupe(u8, try row.get([]const u8, 0));
    try rows.finish(null);
    return value;
}

fn ensureEvent(transaction: *turso.Transaction, allocator: std.mem.Allocator, kind: []const u8, key: []const u8, item: hn.SourceItem, root: ?i64, relevant: ?i64, source_class: []const u8, detected_at: i64) !i64 {
    _ = try transaction.execParams(
        \\INSERT INTO events(event_key,kind,source_item_id,parent_item_id,root_story_id,relevant_item_id,source_revision,occurred_at,detected_at,source_class)
        \\VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10) ON CONFLICT(event_key) DO NOTHING
    , .{ key, kind, item.id, item.parent_id, root, relevant, &item.revision, item.time orelse detected_at, detected_at, source_class }, .{});
    return scalarInt(transaction, allocator, "SELECT id FROM events WHERE event_key=?1", key);
}

fn projectComment(transaction: *turso.Transaction, allocator: std.mem.Allocator, item: hn.SourceItem, graph: Graph, event_id: i64, now: i64) !usize {
    var matches: std.ArrayList(Match) = .empty;
    const self_reply = if (item.author != null and graph.parent_author != null) std.mem.eql(u8, item.author.?, graph.parent_author.?) else false;
    if (graph.parent_author) |parent_author| {
        var rows = try transaction.queryParams(
            "SELECT user_id,id FROM hn_identities WHERE username=?1 COLLATE BINARY AND state IN ('active','backfilling') AND removed_at IS NULL ORDER BY user_id,id",
            .{parent_author},
            .{},
        );
        defer rows.deinit();
        while (try rows.next()) |row| try matches.append(allocator, .{
            .user_id = try allocator.dupe(u8, try row.get([]const u8, 0)),
            .category = .inbox,
            .reason_kind = if (graph.parent_kind == .comment) "identity_direct" else "identity_story",
            .tracked_identity_id = try allocator.dupe(u8, try row.get([]const u8, 1)),
            .relevant_item_id = item.parent_id.?,
            .suppressed = self_reply,
        });
        try rows.finish(null);
    }

    var rows = try transaction.queryParams(
        "SELECT user_id,id,scope_kind,scope_item_id,muted FROM watches WHERE root_story_id=?1 AND removed_at IS NULL ORDER BY user_id,id",
        .{graph.root_story_id.?},
        .{},
    );
    defer rows.deinit();
    while (try rows.next()) |row| {
        const scope = try row.get([]const u8, 2);
        const scope_id = try row.get(i64, 3);
        const reason: ?[]const u8 = if (std.mem.eql(u8, scope, "story"))
            "watch_story"
        else if (std.mem.eql(u8, scope, "comment_direct") and item.parent_id.? == scope_id)
            "watch_direct"
        else if (std.mem.eql(u8, scope, "comment_branch") and contains(graph.ancestors, scope_id))
            "watch_branch"
        else
            null;
        if (reason) |reason_kind| try matches.append(allocator, .{
            .user_id = try allocator.dupe(u8, try row.get([]const u8, 0)),
            .category = .following,
            .reason_kind = reason_kind,
            .watch_id = try allocator.dupe(u8, try row.get([]const u8, 1)),
            .relevant_item_id = scope_id,
            .suppressed = (try row.get(i64, 4)) != 0 or self_reply,
        });
    }
    try rows.finish(null);

    var notifications = std.StringHashMap(void).init(allocator);
    for (matches.items) |match| {
        const category = @tagName(match.category);
        _ = try transaction.execParams(
            \\INSERT INTO notifications(user_id,event_id,category,suppressed,created_at)
            \\VALUES(?1,?2,?3,?4,?5)
            \\ON CONFLICT(user_id,event_id,category) DO UPDATE SET suppressed=MIN(notifications.suppressed,excluded.suppressed)
        , .{ match.user_id, event_id, category, match.suppressed, now }, .{});
        const notification_id = try scalarIntTwo(transaction, allocator, "SELECT id FROM notifications WHERE user_id=?1 AND event_id=?2 AND category=?3", .{ match.user_id, event_id, category });
        const reason_subject = match.tracked_identity_id orelse match.watch_id.?;
        const reason_key = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ match.reason_kind, reason_subject });
        _ = try transaction.execParams(
            \\INSERT INTO notification_reasons(notification_id,reason_kind,tracked_identity_id,watch_id,relevant_item_id,reason_key)
            \\VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(notification_id,reason_key) DO NOTHING
        , .{ notification_id, match.reason_kind, match.tracked_identity_id, match.watch_id, match.relevant_item_id, reason_key }, .{});
        const composite = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ match.user_id, category });
        _ = try notifications.getOrPut(composite);
    }
    return notifications.count();
}

fn scalarInt(transaction: *turso.Transaction, allocator: std.mem.Allocator, sql: []const u8, value: []const u8) !i64 {
    return scalarIntTwo(transaction, allocator, sql, .{value});
}

fn scalarIntTwo(transaction: *turso.Transaction, allocator: std.mem.Allocator, sql: []const u8, params: anytype) !i64 {
    _ = allocator;
    var rows = try transaction.queryParams(sql, params, .{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.MissingRow;
    const result = try row.get(i64, 0);
    try rows.finish(null);
    return result;
}

fn contains(values: []const i64, needle: i64) bool {
    for (values) |value| if (value == needle) return true;
    return false;
}

fn digest(bytes: []const u8) [64]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    return std.fmt.bytesToHex(raw, .lower);
}

fn sourceItem(item: hn.SourceItem) hn.SourceItem {
    var result = item;
    result.revision = hn.sourceRevision(result);
    return result;
}

test "replay-safe reducer explains identity and overlapping watch matches" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "reducer.db" });
    defer allocator.free(path);
    var store = try database_mod.Store.open(allocator, path);
    defer store.deinit();
    try store.migrate(100);
    _ = try store.connection.execParams("INSERT INTO app_users(id,created_at) VALUES(?1,1)", .{"user_0000000000000000000001"}, .{});
    _ = try store.connection.execParams("INSERT INTO hn_identities(id,user_id,username,state,added_at) VALUES(?1,?2,'awce','active',1)", .{ "identity_0000000000000001", "user_0000000000000000000001" }, .{});
    _ = try store.connection.execParams("INSERT INTO watches(id,user_id,scope_kind,scope_item_id,root_story_id,created_item_boundary,created_event_boundary,created_at) VALUES(?1,?2,'comment_branch',11,10,0,0,1)", .{ "watch_00000000000000000001", "user_0000000000000000000001" }, .{});
    _ = try store.connection.execParams("INSERT INTO watches(id,user_id,scope_kind,scope_item_id,root_story_id,created_item_boundary,created_event_boundary,created_at) VALUES(?1,?2,'story',10,10,0,0,1)", .{ "watch_00000000000000000002", "user_0000000000000000000001" }, .{});

    _ = try reduceItem(&store, allocator, sourceItem(.{ .id = 10, .kind = .story, .author = "sasha", .time = 1, .title = "Story", .revision = undefined }), .backfill, 100);
    _ = try reduceItem(&store, allocator, sourceItem(.{ .id = 11, .kind = .comment, .author = "awce", .time = 2, .parent_id = 10, .text_html = "parent", .revision = undefined }), .backfill, 101);
    const first = try reduceItem(&store, allocator, sourceItem(.{ .id = 12, .kind = .comment, .author = "other", .time = 3, .parent_id = 11, .text_html = "reply", .revision = undefined }), .live, 102);
    const replay = try reduceItem(&store, allocator, sourceItem(.{ .id = 12, .kind = .comment, .author = "other", .time = 3, .parent_id = 11, .text_html = "reply", .revision = undefined }), .live, 103);
    try std.testing.expectEqual(@as(usize, 2), first.notification_count);
    try std.testing.expectEqual(@as(usize, 2), replay.notification_count);
    try std.testing.expectEqual(@as(i64, 2), try store.count("events"));
    try std.testing.expectEqual(@as(i64, 3), try store.count("notifications"));

    var rows = try store.connection.query("SELECT COUNT(*) FROM notification_reasons", &.{}, .{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    try std.testing.expectEqual(@as(i64, 4), try row.get(i64, 0));
    try rows.finish(null);
}
