const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2 or args.len > 3) return error.ExpectedPortAndOptionalStoryDelay;
    const port = try std.fmt.parseInt(u16, args[1], 10);
    const story_delay_ms = if (args.len == 3) try std.fmt.parseInt(u64, args[2], 10) else 0;
    var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var listener = try address.listen(init.io, .{ .reuse_address = true });
    defer listener.deinit(init.io);
    while (true) {
        const stream = try listener.accept(init.io);
        var input_buffer: [8192]u8 = undefined;
        var input = stream.reader(init.io, &input_buffer);
        var output_buffer: [8192]u8 = undefined;
        var output = stream.writer(init.io, &output_buffer);
        var server = std.http.Server.init(&input.interface, &output.interface);
        var request = server.receiveHead() catch {
            stream.close(init.io);
            continue;
        };
        if (story_delay_ms > 0 and std.mem.eql(u8, request.head.target, "/v0/item/100.json")) {
            try init.io.sleep(.fromMilliseconds(@intCast(story_delay_ms)), .awake);
        }
        const body = route(request.head.target);
        try request.respond(body.bytes, .{
            .status = body.status,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
        stream.close(init.io);
    }
}

const Body = struct { status: std.http.Status = .ok, bytes: []const u8 };

fn route(target: []const u8) Body {
    if (std.mem.eql(u8, target, "/v0/maxitem.json")) return .{ .bytes = "102\n" };
    if (std.mem.eql(u8, target, "/v0/topstories.json")) return .{ .bytes = "[100]\n" };
    if (std.mem.eql(u8, target, "/v0/askstories.json") or std.mem.eql(u8, target, "/v0/showstories.json") or std.mem.eql(u8, target, "/v0/jobstories.json")) return .{ .bytes = "[]\n" };
    if (std.mem.eql(u8, target, "/v0/item/100.json")) return .{ .bytes = "{\"by\":\"sasha\",\"descendants\":2,\"id\":100,\"kids\":[101],\"score\":120,\"time\":1700000000,\"title\":\"SQLite 3.46: JSON5, underscore literals, and more\",\"type\":\"story\",\"url\":\"https://sqlite.org/\"}\n" };
    if (std.mem.eql(u8, target, "/v0/item/101.json")) return .{ .bytes = "{\"by\":\"awce\",\"id\":101,\"kids\":[102],\"parent\":100,\"text\":\"SQLite getting JSON5 is huge. It removes a lot of friction.\",\"time\":1700000010,\"type\":\"comment\"}\n" };
    if (std.mem.eql(u8, target, "/v0/item/102.json")) return .{ .bytes = "{\"by\":\"other\",\"id\":102,\"parent\":101,\"text\":\"Yes, I agree. The relaxed parser is a practical upgrade.\",\"time\":1700000020,\"type\":\"comment\"}\n" };
    if (std.mem.eql(u8, target, "/v0/user/awce.json")) return .{ .bytes = "{\"created\":1600000000,\"id\":\"awce\",\"karma\":1234,\"submitted\":[101]}\n" };
    if (std.mem.eql(u8, target, "/v0/updates.json")) return .{ .bytes = "{\"items\":[],\"profiles\":[]}\n" };
    return .{ .status = .not_found, .bytes = "null\n" };
}
