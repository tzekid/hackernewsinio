const std = @import("std");
const config_mod = @import("config.zig");
const cli = @import("cli.zig");
const version = @import("version.zig").value;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    defer stdout.interface.flush() catch {};

    if (args.len == 2 and std.mem.eql(u8, args[1], "version")) {
        try stdout.interface.print("hn-continuity {s}\n", .{version});
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "config-check")) {
        try (config_mod.Config{}).validate();
        try stdout.interface.writeAll("configuration valid\n");
        return;
    }
    if (try cli.run(allocator, init.gpa, init.io, &stdout.interface, args)) return;
    try stdout.interface.writeAll(
        \\Usage:
        \\  hn-continuity version
        \\  hn-continuity config-check
    );
    try cli.usage(&stdout.interface);
}
