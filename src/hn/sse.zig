const std = @import("std");

/// Parses one complete Firebase SSE event and returns a maxitem value when the
/// event is a valid put/patch envelope. Keep-alives and unrelated paths are
/// ignored by returning null.
pub fn parseMaxEvent(allocator: std.mem.Allocator, bytes: []const u8) !?i64 {
    if (bytes.len > 64 * 1024) return error.EventTooLarge;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(allocator);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == ':') continue;
        if (std.mem.startsWith(u8, line, "data:")) {
            if (data.items.len != 0) try data.append(allocator, '\n');
            try data.appendSlice(allocator, std.mem.trimStart(u8, line[5..], " "));
        }
    }
    if (data.items.len == 0) return null;
    const envelope = try std.json.parseFromSliceLeaky(std.json.Value, allocator, data.items, .{});
    if (envelope != .object) return error.InvalidSseEnvelope;
    const path = envelope.object.get("path") orelse return error.InvalidSseEnvelope;
    const value = envelope.object.get("data") orelse return error.InvalidSseEnvelope;
    if (path != .string or !(std.mem.eql(u8, path.string, "/") or std.mem.eql(u8, path.string, ""))) return null;
    if (value != .integer or value.integer < 0) return error.InvalidSseValue;
    return value.integer;
}

test "Firebase maxitem SSE parser handles put and keepalive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(?i64, 48_123_456), try parseMaxEvent(arena.allocator(), "event: put\ndata: {\"path\":\"/\",\"data\":48123456}\n\n"));
    try std.testing.expectEqual(@as(?i64, null), try parseMaxEvent(arena.allocator(), ": keep-alive\n\n"));
}
