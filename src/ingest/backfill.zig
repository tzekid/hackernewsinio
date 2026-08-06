const std = @import("std");
const database_mod = @import("../store/database.zig");
const client_mod = @import("../hn/client.zig");
const types = @import("../hn/types.zig");
const reducer = @import("reducer.zig");

pub fn thread(store: *database_mod.Store, allocator: std.mem.Allocator, hn: client_mod.Client, story_id: i64, maximum_comments: usize, now: i64) !usize {
    if (maximum_comments == 0 or maximum_comments > 2000) return error.InvalidThreadLimit;
    var root_arena = std.heap.ArenaAllocator.init(allocator);
    defer root_arena.deinit();
    var response = (try hn.getItem(story_id)) orelse return error.ItemUnavailable;
    defer response.deinit();
    const story = try types.parseItem(root_arena.allocator(), response.body);
    if (story.id != story_id or !(story.kind == .story or story.kind == .poll or story.kind == .job)) return error.InvalidStory;
    _ = try reducer.reduceItem(store, allocator, story, .thread_load, now);
    var queue: std.ArrayList(i64) = .empty;
    defer queue.deinit(allocator);
    try queue.appendSlice(allocator, story.kids);
    var position: usize = 0;
    var stored: usize = 0;
    while (position < queue.items.len and stored < maximum_comments) : (position += 1) {
        const item_id = queue.items[position];
        var child_response = (hn.getItem(item_id) catch continue) orelse continue;
        defer child_response.deinit();
        var child_arena = std.heap.ArenaAllocator.init(allocator);
        defer child_arena.deinit();
        const child = types.parseItem(child_arena.allocator(), child_response.body) catch continue;
        if (child.id != item_id) continue;
        _ = reducer.reduceItem(store, allocator, child, .thread_load, now) catch continue;
        stored += 1;
        const remaining = maximum_comments - stored;
        try queue.appendSlice(allocator, child.kids[0..@min(remaining, child.kids.len)]);
    }
    return stored;
}

pub fn identity(store: *database_mod.Store, allocator: std.mem.Allocator, hn: client_mod.Client, username: []const u8, maximum_submissions: usize, now: i64) !usize {
    if (maximum_submissions == 0 or maximum_submissions > 1000) return error.InvalidBackfillLimit;
    var profile = (try hn.getUser(allocator, username)) orelse return error.UserUnavailable;
    defer profile.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, profile.body, .{});
    if (parsed != .object) return error.InvalidUser;
    const id = parsed.object.get("id") orelse return error.InvalidUser;
    if (id != .string or !std.mem.eql(u8, id.string, username)) return error.InvalidUser;
    const submitted = parsed.object.get("submitted") orelse return 0;
    if (submitted != .array) return error.InvalidUser;
    var stored: usize = 0;
    var index: usize = 0;
    const limit = @min(submitted.array.items.len, maximum_submissions);
    while (index < limit) : (index += 1) {
        const value = submitted.array.items[index];
        if (value != .integer or value.integer < 0) continue;
        const item_id = value.integer;
        try materializeWithParents(store, allocator, hn, item_id, now, 0);
        var rows = try store.connection.queryParams("SELECT id FROM items WHERE id=?1 AND author=?2 COLLATE BINARY", .{ item_id, username }, .{});
        const exists = (try rows.next()) != null;
        try rows.finish(null);
        rows.deinit();
        if (!exists) continue;
        var source_response = (hn.getItem(item_id) catch continue) orelse continue;
        defer source_response.deinit();
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const source = types.parseItem(arena_state.allocator(), source_response.body) catch continue;
        for (source.kids[0..@min(source.kids.len, 256)]) |child_id| {
            materializeWithParents(store, allocator, hn, child_id, now, 0) catch continue;
        }
        stored += 1;
    }
    return stored;
}

fn materializeWithParents(store: *database_mod.Store, allocator: std.mem.Allocator, hn: client_mod.Client, item_id: i64, now: i64, depth: usize) !void {
    if (depth > 128) return error.ParentDepthExceeded;
    var response = (try hn.getItem(item_id)) orelse return error.ItemUnavailable;
    defer response.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const item = try types.parseItem(arena_state.allocator(), response.body);
    if (item.id != item_id) return error.ItemMismatch;
    if (item.parent_id) |parent_id| {
        var rows = try store.connection.queryParams("SELECT COUNT(*) FROM items WHERE id=?1", .{parent_id}, .{});
        const row = (try rows.next()).?;
        const missing = try row.get(i64, 0) == 0;
        try rows.finish(null);
        rows.deinit();
        if (missing) try materializeWithParents(store, allocator, hn, parent_id, now, depth + 1);
    }
    _ = try reducer.reduceItem(store, allocator, item, .backfill, now);
}
