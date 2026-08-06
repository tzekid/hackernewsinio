const std = @import("std");

pub const Kind = enum {
    story,
    comment,
    job,
    poll,
    pollopt,

    pub fn text(self: Kind) []const u8 {
        return @tagName(self);
    }
};

pub const SourceItem = struct {
    id: i64,
    kind: Kind,
    author: ?[]const u8 = null,
    time: ?i64 = null,
    parent_id: ?i64 = null,
    title: ?[]const u8 = null,
    url: ?[]const u8 = null,
    text_html: ?[]const u8 = null,
    score: ?i64 = null,
    descendants: ?i64 = null,
    dead: bool = false,
    deleted: bool = false,
    kids: []const i64 = &.{},
    revision: [64]u8,
};

pub fn parseItem(allocator: std.mem.Allocator, bytes: []const u8) !SourceItem {
    if (bytes.len == 0 or bytes.len > 2 * 1024 * 1024) return error.InvalidItemBody;
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{});
    if (value != .object) return error.InvalidItem;
    const object = value.object;
    const id = try requiredNonNegativeInteger(object, "id");
    const kind_text = try requiredString(object, "type", 16);
    const kind = std.meta.stringToEnum(Kind, kind_text) orelse return error.InvalidItemKind;
    const author = try optionalString(object, "by", 64);
    const time = try optionalNonNegativeInteger(object, "time");
    const parent = try optionalNonNegativeInteger(object, "parent");
    if ((kind == .comment or kind == .pollopt) and parent == null and !boolField(object, "deleted")) {
        return error.MissingParent;
    }
    const title = try optionalString(object, "title", 512);
    const url = try optionalString(object, "url", 4096);
    const text_html = try optionalString(object, "text", 1024 * 1024);
    const score = try optionalInteger(object, "score");
    const descendants = try optionalNonNegativeInteger(object, "descendants");
    const kids = try integerArray(allocator, object, "kids", 100_000);

    var result: SourceItem = .{
        .id = id,
        .kind = kind,
        .author = author,
        .time = time,
        .parent_id = parent,
        .title = title,
        .url = url,
        .text_html = text_html,
        .score = score,
        .descendants = descendants,
        .dead = boolField(object, "dead"),
        .deleted = boolField(object, "deleted"),
        .kids = kids,
        .revision = undefined,
    };
    result.revision = sourceRevision(result);
    return result;
}

pub fn sourceRevision(item: SourceItem) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(item.kind.text());
    hashInt(&hash, item.id);
    hashOptionalString(&hash, item.author);
    hashOptionalInt(&hash, item.time);
    hashOptionalInt(&hash, item.parent_id);
    hashOptionalString(&hash, item.title);
    hashOptionalString(&hash, item.url);
    hashOptionalString(&hash, item.text_html);
    hashOptionalInt(&hash, item.score);
    hashOptionalInt(&hash, item.descendants);
    hash.update(if (item.dead) "1" else "0");
    hash.update(if (item.deleted) "1" else "0");
    for (item.kids) |kid| hashInt(&hash, kid);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn requiredNonNegativeInteger(object: std.json.ObjectMap, key: []const u8) !i64 {
    return (try optionalNonNegativeInteger(object, key)) orelse return error.MissingField;
}

fn optionalInteger(object: std.json.ObjectMap, key: []const u8) !?i64 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .integer) return error.InvalidInteger;
    return value.integer;
}

fn optionalNonNegativeInteger(object: std.json.ObjectMap, key: []const u8) !?i64 {
    const value = try optionalInteger(object, key);
    if (value) |number| if (number < 0) return error.InvalidInteger;
    return value;
}

fn requiredString(object: std.json.ObjectMap, key: []const u8, limit: usize) ![]const u8 {
    return (try optionalString(object, key, limit)) orelse return error.MissingField;
}

fn optionalString(object: std.json.ObjectMap, key: []const u8, limit: usize) !?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .string or value.string.len > limit) return error.InvalidString;
    return value.string;
}

fn boolField(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return false;
    return value == .bool and value.bool;
}

fn integerArray(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8, limit: usize) ![]const i64 {
    const value = object.get(key) orelse return &.{};
    if (value == .null) return &.{};
    if (value != .array or value.array.items.len > limit) return error.InvalidArray;
    const result = try allocator.alloc(i64, value.array.items.len);
    for (value.array.items, result) |entry, *target| {
        if (entry != .integer or entry.integer < 0) return error.InvalidArray;
        target.* = entry.integer;
    }
    return result;
}

fn hashInt(hash: *std.crypto.hash.sha2.Sha256, value: i64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(i64, &bytes, value, .little);
    hash.update(&bytes);
}

fn hashOptionalInt(hash: *std.crypto.hash.sha2.Sha256, value: ?i64) void {
    if (value) |number| {
        hash.update("i");
        hashInt(hash, number);
    } else hash.update("n");
}

fn hashOptionalString(hash: *std.crypto.hash.sha2.Sha256, value: ?[]const u8) void {
    if (value) |text| {
        hash.update("s");
        hashInt(hash, @intCast(text.len));
        hash.update(text);
    } else hash.update("n");
}

test "official HN item shape parses deterministically" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const item = try parseItem(arena.allocator(),
        \\{"by":"awce","id":48123456,"kids":[48123457],"parent":48120111,"text":"Hello <i>world</i>","time":1700000000,"type":"comment"}
    );
    try std.testing.expectEqual(@as(i64, 48_123_456), item.id);
    try std.testing.expectEqual(Kind.comment, item.kind);
    try std.testing.expectEqualStrings("awce", item.author.?);
    try std.testing.expectEqual(@as(i64, 48_120_111), item.parent_id.?);
    try std.testing.expectEqual(@as(usize, 64), item.revision.len);
}

test "comment without parent is quarantined" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MissingParent, parseItem(arena.allocator(),
        \\{"by":"awce","id":1,"type":"comment"}
    ));
}
