const std = @import("std");

pub const max_item_bytes: usize = 2 * 1024 * 1024;
pub const max_feed_bytes: usize = 2 * 1024 * 1024;
pub const max_profile_bytes: usize = 512 * 1024;

pub const Response = struct {
    allocator: std.mem.Allocator,
    body: []u8,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, base_url: []const u8) !Client {
        if (!validBaseUrl(base_url)) return error.InvalidBaseUrl;
        return .{ .allocator = allocator, .io = io, .base_url = base_url };
    }

    pub fn getMaxItem(self: Client) !i64 {
        var response = try self.get("/maxitem.json", 64);
        defer response.deinit();
        const trimmed = std.mem.trim(u8, response.body, " \t\r\n");
        const value = std.fmt.parseInt(i64, trimmed, 10) catch return error.InvalidMaxItem;
        if (value < 0) return error.InvalidMaxItem;
        return value;
    }

    pub fn getItem(self: Client, item_id: i64) !?Response {
        if (item_id < 0) return error.InvalidItemId;
        var path: [64]u8 = undefined;
        const rendered = try std.fmt.bufPrint(&path, "/item/{d}.json", .{item_id});
        var response = try self.get(rendered, max_item_bytes);
        if (std.mem.eql(u8, std.mem.trim(u8, response.body, " \t\r\n"), "null")) {
            response.deinit();
            return null;
        }
        return response;
    }

    pub fn getUser(self: Client, allocator: std.mem.Allocator, username: []const u8) !?Response {
        if (!validUsername(username)) return error.InvalidUsername;
        const path = try std.fmt.allocPrint(allocator, "/user/{s}.json", .{username});
        defer allocator.free(path);
        var response = try self.get(path, max_profile_bytes);
        if (std.mem.eql(u8, std.mem.trim(u8, response.body, " \t\r\n"), "null")) {
            response.deinit();
            return null;
        }
        return response;
    }

    pub fn getFeed(self: Client, allocator: std.mem.Allocator, feed: []const u8, maximum: usize) ![]i64 {
        if (maximum == 0 or maximum > 500) return error.InvalidFeedLimit;
        const endpoint = if (std.mem.eql(u8, feed, "top"))
            "/topstories.json"
        else if (std.mem.eql(u8, feed, "ask"))
            "/askstories.json"
        else if (std.mem.eql(u8, feed, "show"))
            "/showstories.json"
        else if (std.mem.eql(u8, feed, "job"))
            "/jobstories.json"
        else
            return error.InvalidFeed;
        var response = try self.get(endpoint, max_feed_bytes);
        defer response.deinit();
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
        defer parsed.deinit();
        if (parsed.value != .array) return error.InvalidFeedResponse;
        const length = @min(maximum, parsed.value.array.items.len);
        const result = try allocator.alloc(i64, length);
        errdefer allocator.free(result);
        for (parsed.value.array.items[0..length], result) |value, *target| {
            if (value != .integer or value.integer < 0) return error.InvalidFeedResponse;
            target.* = value.integer;
        }
        return result;
    }

    pub fn getUpdates(self: Client) !Response {
        return self.get("/updates.json", max_feed_bytes);
    }

    fn get(self: Client, path: []const u8, maximum: usize) !Response {
        if (path.len == 0 or path[0] != '/' or std.mem.indexOfAny(u8, path, "\r\n") != null) return error.InvalidPath;
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, path });
        defer self.allocator.free(url);
        const storage = try self.allocator.alloc(u8, maximum);
        defer self.allocator.free(storage);
        var response_writer: std.Io.Writer = .fixed(storage);
        var http: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer http.deinit();
        const result = http.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .keep_alive = false,
            .headers = .{ .accept_encoding = .omit },
            .extra_headers = &.{
                .{ .name = "accept", .value = "application/json" },
                .{ .name = "user-agent", .value = "HN-Continuity/0.1" },
            },
            .response_writer = &response_writer,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.ResponseTooLarge,
            else => return err,
        };
        if (result.status == .too_many_requests) return error.RateLimited;
        if (@backingInt(result.status) < 200 or @backingInt(result.status) >= 300) return error.UpstreamRejected;
        return .{ .allocator = self.allocator, .body = try self.allocator.dupe(u8, response_writer.buffered()) };
    }
};

pub fn validBaseUrl(value: []const u8) bool {
    if (std.mem.eql(u8, value, "https://hacker-news.firebaseio.com/v0")) return true;
    const uri = std.Uri.parse(value) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or uri.user != null or uri.password != null or uri.host == null or uri.port == null or uri.query != null or uri.fragment != null) return false;
    const host = switch (uri.host.?) {
        .percent_encoded => |encoded| encoded,
        .raw => |raw| raw,
    };
    const path = switch (uri.path) {
        .percent_encoded => |encoded| encoded,
        .raw => |raw| raw,
    };
    return (std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "[::1]")) and std.mem.eql(u8, path, "/v0");
}

pub fn validUsername(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_')) return false;
    return true;
}

test "adapter accepts only official HTTPS or loopback fixtures" {
    try std.testing.expect(validBaseUrl("https://hacker-news.firebaseio.com/v0"));
    try std.testing.expect(validBaseUrl("http://127.0.0.1:9001/v0"));
    try std.testing.expect(validBaseUrl("http://[::1]:9001/v0"));
    try std.testing.expect(!validBaseUrl("http://127.0.0.1:@evil.example/v0"));
    try std.testing.expect(!validBaseUrl("https://evil.example/v0"));
    try std.testing.expect(validUsername("pg"));
    try std.testing.expect(!validUsername("bad/name"));
}
