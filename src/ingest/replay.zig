const std = @import("std");
const database_mod = @import("../store/database.zig");
const types = @import("../hn/types.zig");
const reducer = @import("reducer.zig");

pub fn file(store: *database_mod.Store, allocator: std.mem.Allocator, io: std.Io, path: []const u8, detected_at: i64) !usize {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(bytes);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var items: std.ArrayList(types.SourceItem) = .empty;
    defer items.deinit(arena);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try items.append(arena, try types.parseItem(arena, line));
    }
    std.mem.sort(types.SourceItem, items.items, {}, struct {
        fn lessThan(_: void, left: types.SourceItem, right: types.SourceItem) bool {
            return left.id < right.id;
        }
    }.lessThan);
    var previous: ?i64 = null;
    for (items.items) |item| {
        if (previous != null and previous.? == item.id) return error.DuplicateReplayItem;
        _ = try reducer.reduceItem(store, allocator, item, .backfill, detected_at);
        previous = item.id;
    }
    return items.items.len;
}
