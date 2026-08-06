const std = @import("std");
const hn_client = @import("hn/client.zig");

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    database_path: []const u8 = "var/hn-continuity.db",
    hn_base_url: []const u8 = "https://hacker-news.firebaseio.com/v0",
    canonical_origin: []const u8 = "http://127.0.0.1:8080",
    dev_mode: bool = false,

    pub fn validate(self: Config) !void {
        if (!(std.mem.eql(u8, self.host, "127.0.0.1") or
            std.mem.eql(u8, self.host, "::1")))
        {
            return error.MustBindLoopback;
        }
        if (self.port == 0) return error.InvalidPort;
        if (self.database_path.len == 0 or self.database_path.len > 4096) {
            return error.InvalidDatabasePath;
        }
        if (!hn_client.validBaseUrl(self.hn_base_url)) return error.InvalidHnBaseUrl;
        if (!std.mem.startsWith(u8, self.canonical_origin, "https://") and
            !std.mem.startsWith(u8, self.canonical_origin, "http://127.0.0.1:") and
            !std.mem.startsWith(u8, self.canonical_origin, "http://[::1]:"))
        {
            return error.InvalidCanonicalOrigin;
        }
    }
};

test "production configuration binds loopback and validates origins" {
    try (Config{}).validate();
    try std.testing.expectError(error.MustBindLoopback, (Config{ .host = "0.0.0.0" }).validate());
    try std.testing.expectError(error.InvalidHnBaseUrl, (Config{ .hn_base_url = "http://example.com" }).validate());
}
