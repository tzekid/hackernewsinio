pub const version = @import("version.zig").value;

comptime {
    _ = @import("config.zig");
    _ = @import("store/schema.zig");
    _ = @import("store/database.zig");
    _ = @import("hn/types.zig");
    _ = @import("hn/sanitize.zig");
    _ = @import("hn/client.zig");
    _ = @import("hn/sse.zig");
    _ = @import("ingest/reducer.zig");
    _ = @import("ingest/progress.zig");
    _ = @import("ingest/feeds.zig");
    _ = @import("ingest/sync.zig");
    _ = @import("ingest/backfill.zig");
    _ = @import("ingest/jobs.zig");
    _ = @import("ingest/replay.zig");
    _ = @import("web/render.zig");
    _ = @import("web/server.zig");
    _ = @import("cli.zig");
    _ = @import("auth/passkeys.zig");
    _ = @import("auth/service.zig");
}
