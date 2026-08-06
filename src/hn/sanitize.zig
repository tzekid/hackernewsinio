const std = @import("std");

pub const version: i64 = 1;

/// Converts HN's limited HTML into a conservative canonical form. Known
/// formatting tags survive; every attribute is discarded except a validated
/// http(s) href on anchors. Unknown or malformed markup is rendered as text.
pub fn html(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    if (source.len > 1024 * 1024) return error.ContentTooLarge;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < source.len) {
        if (source[index] != '<') {
            try escapeByte(&output, allocator, source[index]);
            index += 1;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, source, index, '>') orelse {
            try output.appendSlice(allocator, "&lt;");
            index += 1;
            continue;
        };
        const raw = std.mem.trim(u8, source[index + 1 .. end], " \t\r\n");
        if (canonicalTag(raw)) |tag| {
            try output.appendSlice(allocator, tag);
        } else if (canonicalAnchor(allocator, raw) catch null) |anchor| {
            defer allocator.free(anchor);
            try output.appendSlice(allocator, anchor);
        } else {
            try output.appendSlice(allocator, "&lt;");
            for (raw) |byte| try escapeByte(&output, allocator, byte);
            try output.appendSlice(allocator, "&gt;");
        }
        index = end + 1;
    }
    return output.toOwnedSlice(allocator);
}

fn canonicalTag(raw: []const u8) ?[]const u8 {
    const source = [_][]const u8{ "p", "/p", "i", "/i", "b", "/b", "em", "/em", "strong", "/strong", "pre", "/pre", "code", "/code", "blockquote", "/blockquote", "br", "br/", "/a" };
    const output = [_][]const u8{ "<p>", "</p>", "<i>", "</i>", "<b>", "</b>", "<em>", "</em>", "<strong>", "</strong>", "<pre>", "</pre>", "<code>", "</code>", "<blockquote>", "</blockquote>", "<br>", "<br>", "</a>" };
    for (source, output) |candidate, rendered| if (std.ascii.eqlIgnoreCase(raw, candidate)) return rendered;
    return null;
}

fn canonicalAnchor(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    if (raw.len < 7 or !std.ascii.startsWithIgnoreCase(raw, "a ")) return null;
    const href_start = std.mem.indexOf(u8, raw, "href=") orelse return error.InvalidAnchor;
    const remainder = raw[href_start + 5 ..];
    if (remainder.len < 3 or (remainder[0] != '"' and remainder[0] != '\'')) return error.InvalidAnchor;
    const quote = remainder[0];
    const href_end = std.mem.indexOfScalarPos(u8, remainder, 1, quote) orelse return error.InvalidAnchor;
    const href = remainder[1..href_end];
    if (!validExternalUrl(href)) return error.InvalidAnchor;
    return try std.fmt.allocPrint(allocator, "<a href=\"{s}\" rel=\"nofollow noreferrer\">", .{href});
}

pub fn validExternalUrl(value: []const u8) bool {
    if (value.len == 0 or value.len > 8192 or std.mem.indexOfAny(u8, value, "<>\"'\r\n\t") != null) return false;
    const uri = std.Uri.parse(value) catch return false;
    if (!(std.ascii.eqlIgnoreCase(uri.scheme, "https") or std.ascii.eqlIgnoreCase(uri.scheme, "http"))) return false;
    if (uri.host == null or uri.host.?.isEmpty() or uri.user != null or uri.password != null) return false;
    return true;
}

fn escapeByte(output: *std.ArrayList(u8), allocator: std.mem.Allocator, byte: u8) !void {
    try output.appendSlice(allocator, switch (byte) {
        '&' => "&amp;",
        '<' => "&lt;",
        '>' => "&gt;",
        '"' => "&quot;",
        '\'' => "&#39;",
        else => return output.append(allocator, byte),
    });
}

test "sanitizer keeps HN formatting and neutralizes active markup" {
    const allocator = std.testing.allocator;
    const safe = try html(allocator, "hello <i>world</i> <script>alert(1)</script> <a href=\"javascript:x\">bad</a>");
    defer allocator.free(safe);
    try std.testing.expectEqualStrings(
        "hello <i>world</i> &lt;script&gt;alert(1)&lt;/script&gt; &lt;a href=&quot;javascript:x&quot;&gt;bad</a>",
        safe,
    );
}

test "sanitizer rejects credential-bearing and malformed links" {
    const allocator = std.testing.allocator;
    const safe = try html(allocator, "<a href=\"https://user:secret@example.com/x\">credentials</a> <a href=\"https://\">empty</a>");
    defer allocator.free(safe);
    try std.testing.expect(std.mem.indexOf(u8, safe, "<a href=") == null);
}

test "external URL policy parses schemes, hosts, and credentials" {
    try std.testing.expect(validExternalUrl("https://example.com/path?q=1#part"));
    try std.testing.expect(!validExternalUrl("https://user:secret@example.com/path"));
    try std.testing.expect(!validExternalUrl("javascript:https://example.com"));
    try std.testing.expect(!validExternalUrl("https://"));
}
