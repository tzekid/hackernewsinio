const std = @import("std");
const request_util = @import("web_request");
const response = @import("web_response");
const security_headers = @import("web_security_headers");
const web_server = @import("web_server");
const web_html = @import("web_html");
const database_mod = @import("../store/database.zig");
const hn_client = @import("../hn/client.zig");
const render = @import("render.zig");
const auth_service = @import("../auth/service.zig");
const sync_mod = @import("../ingest/sync.zig");
const jobs = @import("../ingest/jobs.zig");

const app_css = @embedFile("app_css");
const keyboard_js = @embedFile("keyboard_js");
const passkeys_js = @embedFile("passkeys_js");
const htmx_js = @embedFile("htmx_js");
const htmx_sse_js = @embedFile("htmx_sse_js");

var shutdown_requested = std.atomic.Value(bool).init(false);
var listener_fd = std.atomic.Value(i32).init(-1);
var active_stream_fd = std.atomic.Value(i32).init(-1);

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    database_path: []const u8,
    hn_base_url: []const u8 = "https://hacker-news.firebaseio.com/v0",
    canonical_origin: []const u8 = "http://127.0.0.1:8080",
    rp_id: []const u8 = "127.0.0.1",
    secure_transport: bool = false,
};

const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *database_mod.Store,
    hn: hn_client.Client,
    auth_policy: auth_service.Policy,
    secure_transport: bool,
};

const Auth = struct {
    user_id: []u8,
    csrf_token: []u8,
    session_hash: [64]u8,
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    if (!(std.mem.eql(u8, options.host, "127.0.0.1") or std.mem.eql(u8, options.host, "::1"))) return error.MustBindLoopback;
    var store = try database_mod.Store.open(allocator, options.database_path);
    defer store.deinit();
    try store.requireCurrent();
    try store.integrityCheck();
    var context: Context = .{
        .allocator = allocator,
        .io = io,
        .store = &store,
        .hn = try hn_client.Client.init(allocator, io, options.hn_base_url),
        .auth_policy = .{ .origin = options.canonical_origin, .rp_id = options.rp_id },
        .secure_transport = options.secure_transport,
    };
    var worker: SyncWorker = .{
        .allocator = allocator,
        .database_path = options.database_path,
        .hn_base_url = options.hn_base_url,
        .stop = &shutdown_requested,
    };
    shutdown_requested.store(false, .release);
    const sync_thread = try std.Thread.spawn(.{}, SyncWorker.run, .{&worker});
    defer {
        shutdown_requested.store(true, .release);
        sync_thread.join();
    }
    var address = try std.Io.net.IpAddress.parse(options.host, options.port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    listener_fd.store(listener.socket.handle, .release);
    defer listener_fd.store(-1, .release);
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = requestShutdown }, .mask = std.posix.sigemptyset(), .flags = 0 };
    var previous: std.posix.Sigaction = undefined;
    std.posix.sigaction(.TERM, &action, &previous);
    defer std.posix.sigaction(.TERM, &previous, null);
    while (!shutdown_requested.load(.acquire)) {
        const stream = listener.accept(io) catch |err| {
            if (shutdown_requested.load(.acquire) and err == error.SocketNotListening) break;
            return err;
        };
        active_stream_fd.store(stream.socket.handle, .release);
        serveStream(&context, stream) catch |err| std.log.err("request failed: {s}", .{@errorName(err)});
        active_stream_fd.store(-1, .release);
    }
    try store.checkpoint();
}

const SyncWorker = struct {
    allocator: std.mem.Allocator,
    database_path: []const u8,
    hn_base_url: []const u8,
    stop: *std.atomic.Value(bool),

    fn run(self: *SyncWorker) void {
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var store = database_mod.Store.open(self.allocator, self.database_path) catch |err| {
            std.log.err("sync store open failed: {s}", .{@errorName(err)});
            return;
        };
        defer store.deinit();
        store.requireCurrent() catch |err| {
            std.log.err("sync schema check failed: {s}", .{@errorName(err)});
            return;
        };
        const hn = hn_client.Client.init(self.allocator, io, self.hn_base_url) catch |err| {
            std.log.err("sync adapter init failed: {s}", .{@errorName(err)});
            return;
        };
        var iteration: usize = 0;
        while (!self.stop.load(.acquire)) : (iteration += 1) {
            _ = sync_mod.once(&store, self.allocator, io, hn, .{
                .maximum_items = 2048,
                .capture_feeds = iteration % 10 == 0,
            }) catch |err| std.log.warn("HN sync iteration failed: {s}", .{@errorName(err)});
            _ = jobs.runOne(&store, self.allocator, hn, std.Io.Timestamp.now(io, .real).toSeconds()) catch |err| std.log.warn("background job failed: {s}", .{@errorName(err)});
            var seconds: usize = 0;
            while (seconds < 30 and !self.stop.load(.acquire)) : (seconds += 1) {
                sleepSecond();
                if (self.stop.load(.acquire)) break;
                _ = jobs.runOne(&store, self.allocator, hn, std.Io.Timestamp.now(io, .real).toSeconds()) catch |err| std.log.warn("background job failed: {s}", .{@errorName(err)});
            }
        }
    }
};

fn sleepSecond() void {
    const request: std.c.timespec = .{ .sec = 1, .nsec = 0 };
    _ = std.c.nanosleep(&request, null);
}

fn requestShutdown(_: std.posix.SIG) callconv(.c) void {
    shutdown_requested.store(true, .release);
    const listener = listener_fd.load(.acquire);
    if (listener >= 0) _ = std.os.linux.shutdown(listener, std.os.linux.SHUT.RDWR);
    const stream = active_stream_fd.load(.acquire);
    if (stream >= 0) _ = std.os.linux.shutdown(stream, std.os.linux.SHUT.RDWR);
}

fn serveStream(context: *Context, stream: std.Io.net.Stream) !void {
    defer stream.close(context.io);
    var input_buffer: [24 * 1024]u8 = undefined;
    var input = stream.reader(context.io, &input_buffer);
    var output_buffer: [16 * 1024]u8 = undefined;
    var output = stream.writer(context.io, &output_buffer);
    // The accept loop is deliberately single-connection. End the connection
    // after its response so an upstream keep-alive socket cannot monopolize it.
    try web_server.serveConnection(*Context, context, &input.interface, &output.interface, .{ .maximum_requests = 1 }, handle);
}

fn handle(context: *Context, request: *std.http.Server.Request) !void {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const target = request_util.Target.parse(request.head.target, 8192) catch return problem(context, request, .bad_request, "invalid request target");
    const path = target.path;
    if (request.head.method == .GET and std.mem.eql(u8, path, "/")) return response.redirect(request, "/news", .see_other, security(context).slice());
    if (request.head.method == .GET and std.mem.eql(u8, path, "/healthz")) return response.respond(request, "ok\n", .{ .content_type = "text/plain; charset=utf-8", .cache_control = "no-store", .extra_headers = security(context).slice() });
    if (request.head.method == .GET and std.mem.eql(u8, path, "/readyz")) {
        context.store.requireCurrent() catch return response.respond(request, "not ready\n", .{ .status = .service_unavailable, .content_type = "text/plain", .cache_control = "no-store", .extra_headers = security(context).slice() });
        return response.respond(request, "ready\n", .{ .content_type = "text/plain; charset=utf-8", .cache_control = "no-store", .extra_headers = security(context).slice() });
    }
    if (request.head.method == .GET and std.mem.eql(u8, path, "/assets/app.css")) return asset(context, request, app_css, "text/css; charset=utf-8");
    if (request.head.method == .GET and std.mem.eql(u8, path, "/assets/keyboard.js")) return asset(context, request, keyboard_js, "text/javascript; charset=utf-8");
    if (request.head.method == .GET and std.mem.eql(u8, path, "/assets/passkeys.js")) return asset(context, request, passkeys_js, "text/javascript; charset=utf-8");
    if (request.head.method == .GET and std.mem.eql(u8, path, "/assets/htmx.js")) return asset(context, request, htmx_js, "text/javascript; charset=utf-8");
    if (request.head.method == .GET and std.mem.eql(u8, path, "/assets/hx-sse.js")) return asset(context, request, htmx_sse_js, "text/javascript; charset=utf-8");

    const auth = try resolveAuth(context, allocator, request);
    const session: ?render.Session = if (auth) |value| .{ .user_id = value.user_id, .csrf_token = value.csrf_token } else null;
    if (request.head.method == .POST and std.mem.eql(u8, path, "/auth/passkeys/options")) {
        const selected = auth orelse return jsonProblem(context, request, .unauthorized, "sign in required");
        return addPasskeyOptions(context, allocator, request, selected);
    }
    if (request.head.method == .POST and std.mem.eql(u8, path, "/auth/passkeys/finish")) {
        const selected = auth orelse return jsonProblem(context, request, .unauthorized, "sign in required");
        return addPasskeyFinish(context, allocator, request, selected);
    }
    if (request.head.method == .GET and std.mem.eql(u8, path, "/news")) {
        const latest = try latestCapture(context.store);
        const previous_capture = if (auth) |selected| try accountNewsMarker(context.store, selected.user_id) else anonymousNewsMarker(request);
        const before_value: []const u8 = queryValue(allocator, target, "before") catch "";
        const before = if (before_value.len == 0) null else std.fmt.parseInt(i64, before_value, 10) catch return problem(context, request, .bad_request, "invalid news cursor");
        const page = try render.news(allocator, context.store, session, false, queryValue(allocator, target, "filter") catch "", previous_capture, before, std.Io.Timestamp.now(context.io, .real).toSeconds());
        if (latest) |capture_id| {
            if (auth) |selected| _ = try context.store.connection.execParams("INSERT INTO news_markers(user_id,feed,seen_through_capture_id,rendered_at) VALUES(?1,'top',?2,?3) ON CONFLICT(user_id,feed) DO UPDATE SET seen_through_capture_id=MAX(news_markers.seen_through_capture_id,excluded.seen_through_capture_id),rendered_at=excluded.rendered_at", .{ selected.user_id, capture_id, std.Io.Timestamp.now(context.io, .real).toSeconds() }, .{});
            return htmlPageWithNewsCookie(context, request, page, if (auth == null) capture_id else null);
        }
        return htmlPage(context, request, page);
    }
    if (request.head.method == .GET and std.mem.eql(u8, path, "/history")) {
        const capture_value: []const u8 = queryValue(allocator, target, "capture") catch "";
        if (capture_value.len != 0) {
            const capture_id = std.fmt.parseInt(i64, capture_value, 10) catch return problem(context, request, .bad_request, "invalid capture");
            const page = try render.capture(allocator, context.store, session, capture_id);
            return htmlPage(context, request, page);
        }
        const page = try render.news(allocator, context.store, session, true, "", null, null, std.Io.Timestamp.now(context.io, .real).toSeconds());
        return htmlPage(context, request, page);
    }
    if (request.head.method == .GET and std.mem.startsWith(u8, path, "/history/")) {
        const story_id = parsePathId(path, "/history/") catch return problem(context, request, .not_found, "story history not found");
        const page = try render.historyStory(allocator, context.store, session, story_id);
        return htmlPage(context, request, page);
    }
    if (request.head.method == .GET and std.mem.startsWith(u8, path, "/item/")) {
        const story_id = parsePathId(path, "/item/") catch return problem(context, request, .not_found, "item not found");
        const current = std.Io.Timestamp.now(context.io, .real).toSeconds();
        try jobs.enqueueThread(context.store, story_id, current);
        const focus_text = queryValue(allocator, target, "focus") catch "";
        const focus = if (focus_text.len == 0) null else std.fmt.parseInt(i64, focus_text, 10) catch null;
        const previous_seen = if (auth) |selected| try threadMarker(context.store, selected.user_id, story_id) else null;
        const page = try render.thread(allocator, context.store, session, story_id, focus, previous_seen);
        if (auth) |selected| {
            const boundary = (try currentBoundaries(context.store)).items;
            _ = try context.store.connection.execParams("INSERT INTO thread_markers(user_id,root_story_id,seen_through_item_id,rendered_at) VALUES(?1,?2,?3,?4) ON CONFLICT(user_id,root_story_id) DO UPDATE SET seen_through_item_id=MAX(thread_markers.seen_through_item_id,excluded.seen_through_item_id),rendered_at=excluded.rendered_at", .{ selected.user_id, story_id, boundary, current }, .{});
        }
        return htmlPage(context, request, page);
    }
    if (request.head.method == .GET and (std.mem.eql(u8, path, "/auth/login") or std.mem.eql(u8, path, "/auth/register"))) {
        const page = try render.login(allocator, null);
        return htmlPage(context, request, page);
    }
    if (request.head.method == .POST and std.mem.eql(u8, path, "/auth/register/options")) return authOptions(context, allocator, request, true);
    if (request.head.method == .POST and std.mem.eql(u8, path, "/auth/login/options")) return authOptions(context, allocator, request, false);
    if (request.head.method == .POST and std.mem.eql(u8, path, "/auth/register/finish")) return authFinish(context, allocator, request, true);
    if (request.head.method == .POST and std.mem.eql(u8, path, "/auth/login/finish")) return authFinish(context, allocator, request, false);
    if (request.head.method == .GET and std.mem.eql(u8, path, "/inbox")) {
        const selected = auth orelse return loginRedirect(context, request, path);
        const all_value: []const u8 = queryValue(allocator, target, "all") catch "";
        const page = try render.inbox(allocator, context.store, .{ .user_id = selected.user_id, .csrf_token = selected.csrf_token }, all_value.len != 0);
        return htmlPage(context, request, page);
    }
    if (request.head.method == .GET and std.mem.startsWith(u8, path, "/inbox/")) {
        const selected = auth orelse return loginRedirect(context, request, path);
        const id = parsePathId(path, "/inbox/") catch return problem(context, request, .not_found, "notification not found");
        return notificationContext(context, allocator, request, selected, id);
    }
    if (request.head.method == .GET and std.mem.eql(u8, path, "/following")) {
        const selected = auth orelse return loginRedirect(context, request, path);
        const scope_value: []const u8 = queryValue(allocator, target, "scope") catch "";
        const page = try render.following(allocator, context.store, .{ .user_id = selected.user_id, .csrf_token = selected.csrf_token }, std.mem.eql(u8, scope_value, "stories"));
        return htmlPage(context, request, page);
    }
    if (request.head.method == .GET and std.mem.eql(u8, path, "/settings")) {
        const selected = auth orelse return loginRedirect(context, request, path);
        const page = try render.settings(allocator, context.store, .{ .user_id = selected.user_id, .csrf_token = selected.csrf_token }, null);
        return htmlPage(context, request, page);
    }
    if (request.head.method == .GET and std.mem.eql(u8, path, "/events")) {
        const selected = auth orelse return loginRedirect(context, request, path);
        return eventState(context, allocator, request, selected);
    }
    if (request.head.method == .GET and std.mem.startsWith(u8, path, "/feeds/")) return atom(context, allocator, request, path);
    if (request.head.method == .POST) {
        const selected = auth orelse return loginRedirect(context, request, path);
        if (!validRequestOrigin(context, request)) return problem(context, request, .forbidden, "invalid request origin");
        const content_type = request_util.header(request, "content-type") orelse return problem(context, request, .unsupported_media_type, "expected form data");
        if (!std.mem.startsWith(u8, content_type, "application/x-www-form-urlencoded")) return problem(context, request, .unsupported_media_type, "expected form data");
        const body = request_util.readBodyAlloc(allocator, request, 64 * 1024) catch return problem(context, request, .payload_too_large, "form too large");
        const allowed = formSchema(path) orelse return problem(context, request, .not_found, "not found");
        validateForm(body, allowed) catch return problem(context, request, .bad_request, "invalid form fields");
        const csrf = formValue(allocator, body, "csrf") catch return problem(context, request, .bad_request, "invalid form");
        if (!std.crypto.timing_safe.eql([64]u8, hash(csrf), hash(selected.csrf_token))) return problem(context, request, .forbidden, "invalid form token");
        if (std.mem.startsWith(u8, path, "/inbox/") and std.mem.endsWith(u8, path, "/open")) return openInbox(context, allocator, request, selected, path, body);
        if (std.mem.eql(u8, path, "/inbox/read-all")) return readAllInbox(context, allocator, request, selected, body);
        if (std.mem.startsWith(u8, path, "/inbox/") and std.mem.endsWith(u8, path, "/unread")) return unreadInbox(context, request, selected, path);
        if (std.mem.startsWith(u8, path, "/inbox/") and std.mem.endsWith(u8, path, "/dismiss")) return dismissInbox(context, request, selected, path);
        if (std.mem.eql(u8, path, "/watches")) return createWatch(context, allocator, request, selected, body);
        if (std.mem.startsWith(u8, path, "/watches/") and std.mem.endsWith(u8, path, "/remove")) return updateWatch(context, request, selected, path, "remove");
        if (std.mem.startsWith(u8, path, "/watches/") and std.mem.endsWith(u8, path, "/seen")) return updateWatch(context, request, selected, path, "seen");
        if (std.mem.startsWith(u8, path, "/watches/") and std.mem.endsWith(u8, path, "/mute")) return updateWatch(context, request, selected, path, "mute");
        if (std.mem.eql(u8, path, "/settings/identities")) return addIdentity(context, allocator, request, selected, body);
        if (std.mem.startsWith(u8, path, "/settings/identities/") and std.mem.endsWith(u8, path, "/remove")) return removeIdentity(context, request, selected, path);
        if (std.mem.eql(u8, path, "/settings/feeds")) return createFeedToken(context, allocator, request, selected, body);
        if (std.mem.startsWith(u8, path, "/settings/feeds/") and std.mem.endsWith(u8, path, "/revoke")) return revokeFeedToken(context, request, selected, path);
        if (std.mem.eql(u8, path, "/settings/passkeys/rename")) return renamePasskey(context, allocator, request, selected, body);
        if (std.mem.eql(u8, path, "/settings/passkeys/revoke")) return revokePasskey(context, allocator, request, selected, body);
        if (std.mem.eql(u8, path, "/settings/sessions/revoke")) return revokeSession(context, allocator, request, selected, body);
        if (std.mem.eql(u8, path, "/settings/export")) return exportData(context, allocator, request, selected);
        if (std.mem.eql(u8, path, "/settings/delete")) return deleteAccount(context, allocator, request, selected, body);
        if (std.mem.eql(u8, path, "/auth/logout")) return logout(context, request, selected);
    }
    return problem(context, request, .not_found, "not found");
}

fn resolveAuth(context: *Context, allocator: std.mem.Allocator, request: *std.http.Server.Request) !?Auth {
    const cookie = request_util.header(request, "cookie") orelse return null;
    const raw_session = request_util.findCookie(cookie, if (context.secure_transport) "__Host-hnc_session" else "hnc_session") orelse return null;
    const raw_csrf = request_util.findCookie(cookie, if (context.secure_transport) "__Host-hnc_csrf" else "hnc_csrf") orelse return null;
    if (raw_session.len < 32 or raw_session.len > 128 or raw_csrf.len < 32 or raw_csrf.len > 128) return null;
    const session_hash = hash(raw_session);
    const csrf_hash = hash(raw_csrf);
    const now = std.Io.Timestamp.now(context.io, .real).toSeconds();
    var rows = try context.store.connection.queryParams("SELECT user_id,csrf_hash FROM sessions WHERE token_hash=?1 AND revoked_at IS NULL AND expires_at>?2", .{ &session_hash, now }, .{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return null;
    if (!std.mem.eql(u8, try row.get([]const u8, 1), &csrf_hash)) return null;
    const user_id = try allocator.dupe(u8, try row.get([]const u8, 0));
    try rows.finish(null);
    _ = try context.store.connection.execParams("UPDATE sessions SET last_seen_at=?2 WHERE token_hash=?1", .{ &session_hash, now }, .{});
    return .{ .user_id = user_id, .csrf_token = try allocator.dupe(u8, raw_csrf), .session_hash = session_hash };
}

fn authOptions(context: *Context, allocator: std.mem.Allocator, request: *std.http.Server.Request, registration: bool) !void {
    if (!validRequestOrigin(context, request)) return jsonProblem(context, request, .forbidden, "invalid request origin");
    if (request_util.header(request, "content-type")) |value| if (!std.mem.startsWith(u8, value, "application/json")) return jsonProblem(context, request, .unsupported_media_type, "expected application/json");
    request_util.consumeBody(request, 4096) catch return jsonProblem(context, request, .payload_too_large, "request too large");
    var out: std.Io.Writer.Allocating = .init(allocator);
    if (registration)
        auth_service.registrationOptions(context.store, allocator, context.io, context.auth_policy, &out.writer) catch return jsonProblem(context, request, .bad_request, "could not begin passkey registration")
    else
        auth_service.authenticationOptions(context.store, allocator, context.io, context.auth_policy, &out.writer) catch return jsonProblem(context, request, .bad_request, "could not begin passkey authentication");
    const body = try out.toOwnedSlice();
    return response.json(request, body, .ok, security(context).slice());
}

fn authFinish(context: *Context, allocator: std.mem.Allocator, request: *std.http.Server.Request, registration: bool) !void {
    if (!validRequestOrigin(context, request)) return jsonProblem(context, request, .forbidden, "invalid request origin");
    const content_type = request_util.header(request, "content-type") orelse return jsonProblem(context, request, .unsupported_media_type, "expected application/json");
    if (!std.mem.startsWith(u8, content_type, "application/json")) return jsonProblem(context, request, .unsupported_media_type, "expected application/json");
    const body = request_util.readBodyAlloc(allocator, request, 256 * 1024) catch return jsonProblem(context, request, .payload_too_large, "request too large");
    const session = if (registration) registration_result: {
        const input = std.json.parseFromSliceLeaky(auth_service.RegistrationInput, allocator, body, .{ .ignore_unknown_fields = false }) catch return jsonProblem(context, request, .bad_request, "invalid passkey response");
        break :registration_result auth_service.finishRegistration(context.store, allocator, context.io, context.auth_policy, input) catch return jsonProblem(context, request, .bad_request, "passkey registration failed");
    } else authentication_result: {
        const input = std.json.parseFromSliceLeaky(auth_service.AuthenticationInput, allocator, body, .{ .ignore_unknown_fields = false }) catch return jsonProblem(context, request, .bad_request, "invalid passkey response");
        break :authentication_result auth_service.finishAuthentication(context.store, allocator, context.io, context.auth_policy, input) catch return jsonProblem(context, request, .unauthorized, "passkey authentication failed");
    };
    const secure = if (context.secure_transport) "; Secure" else "";
    const session_name = if (context.secure_transport) "__Host-hnc_session" else "hnc_session";
    const csrf_name = if (context.secure_transport) "__Host-hnc_csrf" else "hnc_csrf";
    const session_cookie = try std.fmt.allocPrint(allocator, "{s}={s}; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000{s}", .{ session_name, session.token, secure });
    const csrf_cookie = try std.fmt.allocPrint(allocator, "{s}={s}; Path=/; SameSite=Lax; Max-Age=2592000{s}", .{ csrf_name, session.csrf, secure });
    var headers = security(context);
    var combined: [12]std.http.Header = undefined;
    var count: usize = 0;
    for (headers.slice()) |header| {
        combined[count] = header;
        count += 1;
    }
    combined[count] = .{ .name = "set-cookie", .value = session_cookie };
    count += 1;
    combined[count] = .{ .name = "set-cookie", .value = csrf_cookie };
    count += 1;
    return response.json(request, "{\"ok\":true}\n", .ok, combined[0..count]);
}

fn addPasskeyOptions(context: *Context, allocator: std.mem.Allocator, request: *std.http.Server.Request, auth: Auth) !void {
    if (!validRequestOrigin(context, request)) return jsonProblem(context, request, .forbidden, "invalid request origin");
    const content_type = request_util.header(request, "content-type") orelse return jsonProblem(context, request, .unsupported_media_type, "expected application/json");
    if (!std.mem.startsWith(u8, content_type, "application/json")) return jsonProblem(context, request, .unsupported_media_type, "expected application/json");
    request_util.consumeBody(request, 4096) catch return jsonProblem(context, request, .payload_too_large, "request too large");
    if (try userCount(context.store, "SELECT COUNT(*) FROM auth_credentials WHERE user_id=?1 AND revoked_at IS NULL", auth.user_id) >= 5) return jsonProblem(context, request, .conflict, "passkey limit reached");
    var out: std.Io.Writer.Allocating = .init(allocator);
    auth_service.addCredentialOptions(context.store, allocator, context.io, context.auth_policy, auth.user_id, &out.writer) catch return jsonProblem(context, request, .bad_request, "could not begin passkey registration");
    return response.json(request, try out.toOwnedSlice(), .ok, security(context).slice());
}

fn addPasskeyFinish(context: *Context, allocator: std.mem.Allocator, request: *std.http.Server.Request, auth: Auth) !void {
    if (!validRequestOrigin(context, request)) return jsonProblem(context, request, .forbidden, "invalid request origin");
    const content_type = request_util.header(request, "content-type") orelse return jsonProblem(context, request, .unsupported_media_type, "expected application/json");
    if (!std.mem.startsWith(u8, content_type, "application/json")) return jsonProblem(context, request, .unsupported_media_type, "expected application/json");
    const body = request_util.readBodyAlloc(allocator, request, 256 * 1024) catch return jsonProblem(context, request, .payload_too_large, "request too large");
    const input = std.json.parseFromSliceLeaky(auth_service.RegistrationInput, allocator, body, .{ .ignore_unknown_fields = false }) catch return jsonProblem(context, request, .bad_request, "invalid passkey response");
    auth_service.finishAddCredential(context.store, allocator, context.io, context.auth_policy, auth.user_id, input) catch return jsonProblem(context, request, .bad_request, "passkey registration failed");
    return response.json(request, "{\"ok\":true}\n", .ok, security(context).slice());
}

fn eventState(context: *Context, allocator: std.mem.Allocator, request: *std.http.Server.Request, auth: Auth) !void {
    var rows = try context.store.connection.queryParams(
        "SELECT COUNT(*),COALESCE(MAX(event_id),0) FROM notifications WHERE user_id=?1 AND suppressed=0 AND dismissed_at IS NULL AND read_at IS NULL",
        .{auth.user_id},
        .{},
    );
    defer rows.deinit();
    const row = (try rows.next()).?;
    const unread = try row.get(i64, 0);
    const boundary = try row.get(i64, 1);
    try rows.finish(null);
    const body = if (unread == 0)
        try std.fmt.allocPrint(allocator, "id: {d}\nretry: 5000\ndata: <span></span>\n\n", .{boundary})
    else
        try std.fmt.allocPrint(allocator, "id: {d}\nretry: 5000\ndata: <a href=\"/inbox\" class=\"live-state__notice\">{d} unread continuity update{s}</a>\n\n", .{ boundary, unread, if (unread == 1) "" else "s" });
    return response.respond(request, body, .{ .content_type = "text/event-stream; charset=utf-8", .cache_control = "no-store", .extra_headers = security(context).slice() });
}

fn notificationContext(context: *Context, allocator: std.mem.Allocator, request: *std.http.Server.Request, auth: Auth, id: i64) !void {
    var rows = try context.store.connection.queryParams(
        "SELECT e.root_story_id,e.source_item_id FROM notifications n JOIN events e ON e.id=n.event_id WHERE n.id=?1 AND n.user_id=?2 AND n.suppressed=0",
        .{ id, auth.user_id },
        .{},
    );
    defer rows.deinit();
    const row = (try rows.next()) orelse return problem(context, request, .not_found, "notification not found");
    const root_id = try row.get(?i64, 0) orelse return problem(context, request, .not_found, "notification context unavailable");
    const source_id = try row.get(?i64, 1) orelse root_id;
    try rows.finish(null);
    const location = try std.fmt.allocPrint(allocator, "/item/{d}?focus={d}#comment-{d}", .{ root_id, source_id, source_id });
    return response.redirect(request, location, .see_other, security(context).slice());
}

fn openInbox(context: *Context, allocator: std.mem.Allocator, request: *std.http.Server.Request, auth: Auth, path: []const u8, body: []const u8) !void {
    const middle = path["/inbox/".len .. path.len - "/open".len];
    const id = std.fmt.parseInt(i64, middle, 10) catch return problem(context, request, .not_found, "notification not found");
    _ = try context.store.connection.execParams("UPDATE notifications SET read_at=?3 WHERE id=?1 AND user_id=?2", .{ id, auth.user_id, std.Io.Timestamp.now(context.io, .real).toSeconds() }, .{});
    const location = formValue(allocator, body, "return") catch "/inbox";
    if (!std.mem.startsWith(u8, location, "/item/")) return problem(context, request, .bad_request, "invalid return route");
    return response.redirect(request, location, .see_other, security(context).slice());
}

fn readAllInbox(context: *Context, allocator: std.mem.Allocator, request: *std.http.Server.Request, auth: Auth, body: []const u8) !void {
    const raw_from = formValue(allocator, body, "from") catch return problem(context, request, .bad_request, "missing inbox boundary");
    const raw = formValue(allocator, body, "through") catch return problem(context, request, .bad_request, "missing inbox boundary");
    const from = std.fmt.parseInt(i64, raw_from, 10) catch return problem(context, request, .bad_request, "invalid inbox boundary");
    const through = std.fmt.parseInt(i64, raw, 10) catch return problem(context, request, .bad_request, "invalid inbox boundary");
    if (from < 0 or through < from) return problem(context, request, .bad_request, "invalid inbox boundary");
    _ = try context.store.connection.execParams("UPDATE notifications SET read_at=?4 WHERE user_id=?1 AND category='inbox' AND suppressed=0 AND dismissed_at IS NULL AND read_at IS NULL AND id>=?2 AND id<=?3", .{ auth.user_id, from, through, std.Io.Timestamp.now(context.io, .real).toSeconds() }, .{});
    return response.redirect(request, "/inbox", .see_other, security(context).slice());
}

fn unreadInbox(context: *Context, request: *std.http.Server.Request, auth: Auth, path: []const u8) !void {
    const middle = path["/inbox/".len .. path.len - "/unread".len];
    const id = std.fmt.parseInt(i64, middle, 10) catch return problem(context, request, .not_found, "notification not found");
    _ = try context.store.connection.execParams("UPDATE notifications SET read_at=NULL WHERE id=?1 AND user_id=?2 AND category='inbox' AND dismissed_at IS NULL", .{ id, auth.user_id }, .{});
    return response.redirect(request, "/inbox", .see_other, security(context).slice());
}

fn dismissInbox(context: *Context, request: *std.http.Server.Request, auth: Auth, path: []const u8) !void {
    const middle = path["/inbox/".len .. path.len - "/dismiss".len];
    const id = std.fmt.parseInt(i64, middle, 10) catch return problem(context, request, .not_found, "notification not found");
    const now = std.Io.Timestamp.now(context.io, .real).toSeconds();
    _ = try context.store.connection.execParams("UPDATE notifications SET read_at=COALESCE(read_at,?3),dismissed_at=?3 WHERE id=?1 AND user_id=?2 AND category='inbox' AND dismissed_at IS NULL", .{ id, auth.user_id, now }, .{});
    return response.redirect(request, "/inbox", .see_other, security(context).slice());
}

fn createWatch(context: *Context, allocator: std.mem.Allocator, request: *std.http.Server.Request, auth: Auth, body: []const u8) !void {
    const kind = formValue(allocator, body, "scope_kind") catch return problem(context, request, .bad_request, "missing watch type");
    if (!(std.mem.eql(u8, kind, "story") or std.mem.eql(u8, kind, "comment_direct") or std.mem.eql(u8, kind, "comment_branch"))) return problem(context, request, .bad_request, "invalid watch type");
    const raw_id = formValue(allocator, body, "scope_item_id") catch return problem(context, request, .bad_request, "missing item");
    const item_id = std.fmt.parseInt(i64, raw_id, 10) catch return problem(context, request, .bad_request, "invalid item");
    if (try userCount(context.store, "SELECT COUNT(*) FROM watches WHERE user_id=?1 AND removed_at IS NULL", auth.user_id) >= 200) return problem(context, request, .conflict, "active watch limit reached");
    var rows = try context.store.connection.queryParams("SELECT kind,root_story_id FROM items WHERE id=?1", .{item_id}, .{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return problem(context, request, .not_found, "item not stored");
    const item_kind = try allocator.dupe(u8, try row.get([]const u8, 0));
    const root = try row.get(?i64, 1) orelse item_id;
    try rows.finish(null);
    if (std.mem.eql(u8, kind, "story") != (std.mem.eql(u8, item_kind, "story") or std.mem.eql(u8, item_kind, "job") or std.mem.eql(u8, item_kind, "poll"))) return problem(context, request, .bad_request, "watch type does not match item");
    const boundaries = try currentBoundaries(context.store);
    var id_buffer: [48]u8 = undefined;
    const id = randomToken(context.io, &id_buffer);
    _ = try context.store.connection.execParams(
        \\INSERT INTO watches(id,user_id,scope_kind,scope_item_id,root_story_id,created_item_boundary,created_event_boundary,created_at)
        \\VALUES(?1,?2,?3,?4,?5,?6,?7,?8) ON CONFLICT DO NOTHING
    , .{ id, auth.user_id, kind, item_id, root, boundaries.items, boundaries.events, std.Io.Timestamp.now(context.io, .real).toSeconds() }, .{});
    return response.redirect(request, try std.fmt.allocPrint(allocator, "/item/{d}", .{root}), .see_other, security(context).slice());
}

fn updateWatch(context: *Context, request: *std.http.Server.Request, auth: Auth, path: []const u8, operation: []const u8) !void {
    const suffix_len = operation.len + 1;
    const id = path["/watches/".len .. path.len - suffix_len];
    const now = std.Io.Timestamp.now(context.io, .real).toSeconds();
    if (std.mem.eql(u8, operation, "remove")) {
        _ = try context.store.connection.execParams("UPDATE watches SET removed_at=?3 WHERE id=?1 AND user_id=?2 AND removed_at IS NULL", .{ id, auth.user_id, now }, .{});
    } else if (std.mem.eql(u8, operation, "seen")) {
        const max_event = (try currentBoundaries(context.store)).events;
        _ = try context.store.connection.execParams("INSERT INTO watch_markers(user_id,watch_id,seen_through_event_id,rendered_at) VALUES(?1,?2,?3,?4) ON CONFLICT(user_id,watch_id) DO UPDATE SET seen_through_event_id=MAX(watch_markers.seen_through_event_id,excluded.seen_through_event_id),rendered_at=excluded.rendered_at", .{ auth.user_id, id, max_event, now }, .{});
    } else {
        _ = try context.store.connection.execParams("UPDATE watches SET muted=1-muted WHERE id=?1 AND user_id=?2", .{ id, auth.user_id }, .{});
    }
    return response.redirect(request, "/following", .see_other, security(context).slice());
}

fn addIdentity(context: *Context, allocator: std.mem.Allocator, request: *std.http.Server.Request, auth: Auth, body: []const u8) !void {
    const username = formValue(allocator, body, "username") catch return problem(context, request, .bad_request, "missing username");
    if (!hn_client.validUsername(username)) return problem(context, request, .bad_request, "invalid HN username");
    var profile = (try context.hn.getUser(allocator, username)) orelse return problem(context, request, .not_found, "HN identity not found");
    defer profile.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, profile.body, .{}) catch return problem(context, request, .bad_gateway, "invalid HN profile");
    if (parsed != .object) return problem(context, request, .bad_gateway, "invalid HN profile");
    const id_value = parsed.object.get("id") orelse return problem(context, request, .bad_gateway, "invalid HN profile");
    if (id_value != .string or !std.mem.eql(u8, id_value.string, username)) return problem(context, request, .bad_request, "HN usernames are case-sensitive");
    var id_storage: [48]u8 = undefined;
    const id = randomToken(context.io, &id_storage);
    const created = jsonInteger(parsed.object, "created");
    const karma = jsonInteger(parsed.object, "karma");
    const confirmation: []const u8 = formValue(allocator, body, "confirm") catch "";
    if (!std.mem.eql(u8, confirmation, "yes")) {
        const page = try render.identityPreview(allocator, .{ .user_id = auth.user_id, .csrf_token = auth.csrf_token }, username, created, karma);
        return htmlPage(context, request, page);
    }
    if (try userCount(context.store, "SELECT COUNT(*) FROM hn_identities WHERE user_id=?1 AND removed_at IS NULL", auth.user_id) >= 5) return problem(context, request, .conflict, "tracked identity limit reached");
    const current = std.Io.Timestamp.now(context.io, .real).toSeconds();
    const inserted = try context.store.connection.execParams("INSERT INTO hn_identities(id,user_id,username,state,profile_created_at,profile_karma,added_at) VALUES(?1,?2,?3,'pending_preview',?4,?5,?6) ON CONFLICT DO NOTHING", .{ id, auth.user_id, username, created, karma, current }, .{});
    if (inserted == 0) return response.redirect(request, "/settings", .see_other, security(context).slice());
    try jobs.enqueueIdentity(context.store, id, auth.user_id, username, current);
    return response.redirect(request, "/settings", .see_other, security(context).slice());
}

fn removeIdentity(context: *Context, request: *std.http.Server.Request, auth: Auth, path: []const u8) !void {
    const id = path["/settings/identities/".len .. path.len - "/remove".len];
    _ = try context.store.connection.execParams("UPDATE background_jobs SET state='cancelled',updated_at=?3,finished_at=?3 WHERE id=(SELECT backfill_job_id FROM hn_identities WHERE id=?1 AND user_id=?2) AND state IN ('pending','running')", .{ id, auth.user_id, std.Io.Timestamp.now(context.io, .real).toSeconds() }, .{});
    _ = try context.store.connection.execParams("UPDATE hn_identities SET state='removed',removed_at=?3 WHERE id=?1 AND user_id=?2 AND removed_at IS NULL", .{ id, auth.user_id, std.Io.Timestamp.now(context.io, .real).toSeconds() }, .{});
    return response.redirect(request, "/settings", .see_other, security(context).slice());
}

fn createFeedToken(context: *Context, allocator: std.mem.Allocator, request: *std.http.Server.Request, auth: Auth, body: []const u8) !void {
    const scope = formValue(allocator, body, "scope") catch return problem(context, request, .bad_request, "missing scope");
    if (!(std.mem.eql(u8, scope, "inbox") or std.mem.eql(u8, scope, "following"))) return problem(context, request, .bad_request, "invalid scope");
    if (try userCount(context.store, "SELECT COUNT(*) FROM feed_tokens WHERE user_id=?1 AND revoked_at IS NULL", auth.user_id) >= 5) return problem(context, request, .conflict, "private feed limit reached");
    var raw_storage: [48]u8 = undefined;
    const raw = randomToken(context.io, &raw_storage);
    var id_storage: [48]u8 = undefined;
    const id = randomToken(context.io, &id_storage);
    const token_hash = hash(raw);
    _ = try context.store.connection.execParams("INSERT INTO feed_tokens(id,token_hash,user_id,scope,label,created_at) VALUES(?1,?2,?3,?4,'Private feed',?5)", .{ id, &token_hash, auth.user_id, scope, std.Io.Timestamp.now(context.io, .real).toSeconds() }, .{});
    const page = try render.settings(allocator, context.store, .{ .user_id = auth.user_id, .csrf_token = auth.csrf_token }, raw);
    return htmlPage(context, request, page);
}

fn revokeFeedToken(context: *Context, request: *std.http.Server.Request, auth: Auth, path: []const u8) !void {
    const id = path["/settings/feeds/".len .. path.len - "/revoke".len];
    _ = try context.store.connection.execParams("UPDATE feed_tokens SET revoked_at=?3 WHERE id=?1 AND user_id=?2 AND revoked_at IS NULL", .{ id, auth.user_id, std.Io.Timestamp.now(context.io, .real).toSeconds() }, .{});
    return response.redirect(request, "/settings", .see_other, security(context).slice());
}

fn renamePasskey(context: *Context, allocator: std.mem.Allocator, request: *std.http.Server.Request, auth: Auth, body: []const u8) !void {
    const credential_id = formValue(allocator, body, "credential_id") catch return problem(context, request, .bad_request, "missing passkey");
    const label = formValue(allocator, body, "label") catch return problem(context, request, .bad_request, "missing passkey name");
    if (label.len == 0 or label.len > 64 or !std.unicode.utf8ValidateSlice(label)) return problem(context, request, .bad_request, "invalid passkey name");
    _ = try context.store.connection.execParams("UPDATE auth_credentials SET label=?3 WHERE credential_id=?1 AND user_id=?2 AND revoked_at IS NULL", .{ credential_id, auth.user_id, label }, .{});
    return response.redirect(request, "/settings", .see_other, security(context).slice());
}

fn revokePasskey(context: *Context, allocator: std.mem.Allocator, request: *std.http.Server.Request, auth: Auth, body: []const u8) !void {
    const credential_id = formValue(allocator, body, "credential_id") catch return problem(context, request, .bad_request, "missing passkey");
    if (try userCount(context.store, "SELECT COUNT(*) FROM auth_credentials WHERE user_id=?1 AND revoked_at IS NULL", auth.user_id) <= 1) return problem(context, request, .conflict, "the last active passkey cannot be revoked");
    _ = try context.store.connection.execParams("UPDATE auth_credentials SET revoked_at=?3 WHERE credential_id=?1 AND user_id=?2 AND revoked_at IS NULL", .{ credential_id, auth.user_id, std.Io.Timestamp.now(context.io, .real).toSeconds() }, .{});
    return response.redirect(request, "/settings", .see_other, security(context).slice());
}

fn revokeSession(context: *Context, allocator: std.mem.Allocator, request: *std.http.Server.Request, auth: Auth, body: []const u8) !void {
    const session_hash = formValue(allocator, body, "session_hash") catch return problem(context, request, .bad_request, "missing session");
    if (session_hash.len != 64) return problem(context, request, .bad_request, "invalid session");
    _ = try context.store.connection.execParams("UPDATE sessions SET revoked_at=?3 WHERE token_hash=?1 AND user_id=?2 AND revoked_at IS NULL", .{ session_hash, auth.user_id, std.Io.Timestamp.now(context.io, .real).toSeconds() }, .{});
    return response.redirect(request, "/settings", .see_other, security(context).slice());
}

fn deleteAccount(context: *Context, allocator: std.mem.Allocator, request: *std.http.Server.Request, auth: Auth, body: []const u8) !void {
    const confirmation = formValue(allocator, body, "confirm") catch return problem(context, request, .bad_request, "type delete to confirm");
    if (!std.mem.eql(u8, confirmation, "delete")) return problem(context, request, .bad_request, "type delete to confirm");
    _ = try context.store.connection.execParams("DELETE FROM app_users WHERE id=?1", .{auth.user_id}, .{});
    return redirectClearingSession(context, request);
}

fn atom(context: *Context, allocator: std.mem.Allocator, request: *std.http.Server.Request, path: []const u8) !void {
    const rest = path["/feeds/".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return problem(context, request, .not_found, "feed not found");
    const raw = rest[0..slash];
    const scope = if (std.mem.eql(u8, rest[slash + 1 ..], "inbox.atom")) "inbox" else if (std.mem.eql(u8, rest[slash + 1 ..], "following.atom")) "following" else return problem(context, request, .not_found, "feed not found");
    const token_hash = hash(raw);
    var token_rows = try context.store.connection.queryParams("SELECT user_id FROM feed_tokens WHERE token_hash=?1 AND scope=?2 AND revoked_at IS NULL", .{ &token_hash, scope }, .{});
    defer token_rows.deinit();
    const token_row = (try token_rows.next()) orelse return problem(context, request, .not_found, "feed not found");
    const user_id = try allocator.dupe(u8, try token_row.get([]const u8, 0));
    try token_rows.finish(null);
    _ = try context.store.connection.execParams("UPDATE feed_tokens SET last_used_at=?2 WHERE token_hash=?1", .{ &token_hash, std.Io.Timestamp.now(context.io, .real).toSeconds() }, .{});
    var boundary_rows = try context.store.connection.queryParams("SELECT COALESCE(MAX(n.id),0) FROM notifications n WHERE n.user_id=?1 AND n.category=?2 AND n.suppressed=0 AND n.dismissed_at IS NULL", .{ user_id, scope }, .{});
    defer boundary_rows.deinit();
    const boundary_row = (try boundary_rows.next()).?;
    const boundary = try boundary_row.get(i64, 0);
    try boundary_rows.finish(null);
    const etag = try std.fmt.allocPrint(allocator, "\"atom-{s}-{d}\"", .{ scope, boundary });
    var base_headers = security(context);
    var atom_headers: [12]std.http.Header = undefined;
    var atom_header_count: usize = 0;
    for (base_headers.slice()) |header| {
        atom_headers[atom_header_count] = header;
        atom_header_count += 1;
    }
    atom_headers[atom_header_count] = .{ .name = "etag", .value = etag };
    atom_header_count += 1;
    if (request_util.header(request, "if-none-match")) |candidate| if (std.mem.eql(u8, candidate, etag)) return response.respond(request, "", .{ .status = .not_modified, .cache_control = "private, no-cache", .extra_headers = atom_headers[0..atom_header_count] });
    var out: std.Io.Writer.Allocating = .init(allocator);
    const writer = &out.writer;
    try writer.writeAll("<?xml version=\"1.0\" encoding=\"utf-8\"?><feed xmlns=\"http://www.w3.org/2005/Atom\"><title>HN Continuity ");
    try writer.writeAll(scope);
    try writer.writeAll("</title><id>urn:hn-continuity:");
    try writer.writeAll(scope);
    try writer.writeAll("</id><updated>");
    try atomTimestamp(writer, std.Io.Timestamp.now(context.io, .real).toSeconds());
    try writer.writeAll("</updated>");
    var rows = try context.store.connection.queryParams("SELECT n.id,e.source_item_id,e.root_story_id,e.occurred_at,COALESCE(c.title_text,'HN activity') FROM notifications n JOIN events e ON e.id=n.event_id LEFT JOIN item_content c ON c.item_id=e.root_story_id WHERE n.user_id=?1 AND n.category=?2 AND n.suppressed=0 AND n.dismissed_at IS NULL ORDER BY n.id DESC LIMIT 50", .{ user_id, scope }, .{});
    defer rows.deinit();
    while (try rows.next()) |row| {
        try writer.print("<entry><id>urn:hn-continuity:notification:{d}</id><title>", .{try row.get(i64, 0)});
        try web_html.text(writer, try row.get([]const u8, 4));
        try writer.print("</title><link href=\"{s}/item/{d}?focus={d}\"/><updated>", .{ context.auth_policy.origin, try row.get(?i64, 2) orelse 0, try row.get(?i64, 1) orelse 0 });
        try atomTimestamp(writer, try row.get(i64, 3));
        try writer.writeAll("</updated></entry>");
    }
    try rows.finish(null);
    try writer.writeAll("</feed>");
    const body = try out.toOwnedSlice();
    return response.respond(request, body, .{ .content_type = "application/atom+xml; charset=utf-8", .cache_control = "private, no-cache", .extra_headers = atom_headers[0..atom_header_count] });
}

fn exportData(context: *Context, allocator: std.mem.Allocator, request: *std.http.Server.Request, auth: Auth) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    try out.writer.writeAll("{\"schema\":1,\"user_id\":");
    try std.json.Stringify.encodeJsonString(auth.user_id, .{}, &out.writer);
    try out.writer.writeAll(",\"identities\":[");
    var rows = try context.store.connection.queryParams("SELECT id,username,state,added_at FROM hn_identities WHERE user_id=?1 AND removed_at IS NULL ORDER BY username", .{auth.user_id}, .{});
    var first = true;
    while (try rows.next()) |row| {
        if (!first) try out.writer.writeByte(',');
        first = false;
        try out.writer.writeAll("{\"id\":");
        try std.json.Stringify.encodeJsonString(try row.get([]const u8, 0), .{}, &out.writer);
        try out.writer.writeAll(",\"username\":");
        try std.json.Stringify.encodeJsonString(try row.get([]const u8, 1), .{}, &out.writer);
        try out.writer.writeAll(",\"state\":");
        try std.json.Stringify.encodeJsonString(try row.get([]const u8, 2), .{}, &out.writer);
        try out.writer.print(",\"added_at\":{d}}}", .{try row.get(i64, 3)});
    }
    try rows.finish(null);
    rows.deinit();
    try out.writer.writeAll("],\"watches\":[");
    rows = try context.store.connection.queryParams("SELECT id,scope_kind,scope_item_id,root_story_id,muted,created_at FROM watches WHERE user_id=?1 AND removed_at IS NULL ORDER BY created_at,id", .{auth.user_id}, .{});
    first = true;
    while (try rows.next()) |row| {
        if (!first) try out.writer.writeByte(',');
        first = false;
        try out.writer.writeAll("{\"id\":");
        try std.json.Stringify.encodeJsonString(try row.get([]const u8, 0), .{}, &out.writer);
        try out.writer.writeAll(",\"scope\":");
        try std.json.Stringify.encodeJsonString(try row.get([]const u8, 1), .{}, &out.writer);
        try out.writer.print(",\"item_id\":{d},\"root_story_id\":{d},\"muted\":{s},\"created_at\":{d}}}", .{ try row.get(i64, 2), try row.get(i64, 3), if ((try row.get(i64, 4)) != 0) "true" else "false", try row.get(i64, 5) });
    }
    try rows.finish(null);
    rows.deinit();
    try out.writer.writeAll("],\"notifications\":[");
    rows = try context.store.connection.queryParams("SELECT id,event_id,category,created_at,read_at,dismissed_at FROM notifications WHERE user_id=?1 ORDER BY id", .{auth.user_id}, .{});
    first = true;
    while (try rows.next()) |row| {
        if (!first) try out.writer.writeByte(',');
        first = false;
        try out.writer.print("{{\"id\":{d},\"event_id\":{d},\"category\":", .{ try row.get(i64, 0), try row.get(i64, 1) });
        try std.json.Stringify.encodeJsonString(try row.get([]const u8, 2), .{}, &out.writer);
        try out.writer.print(",\"created_at\":{d},\"read_at\":", .{try row.get(i64, 3)});
        try jsonOptionalInt(&out.writer, try row.get(?i64, 4));
        try out.writer.writeAll(",\"dismissed_at\":");
        try jsonOptionalInt(&out.writer, try row.get(?i64, 5));
        try out.writer.writeByte('}');
    }
    try rows.finish(null);
    rows.deinit();
    try out.writer.writeAll("],\"thread_markers\":[");
    rows = try context.store.connection.queryParams("SELECT root_story_id,seen_through_item_id,rendered_at FROM thread_markers WHERE user_id=?1 ORDER BY root_story_id", .{auth.user_id}, .{});
    first = true;
    while (try rows.next()) |row| {
        if (!first) try out.writer.writeByte(',');
        first = false;
        try out.writer.print("{{\"root_story_id\":{d},\"seen_through_item_id\":{d},\"rendered_at\":{d}}}", .{ try row.get(i64, 0), try row.get(i64, 1), try row.get(i64, 2) });
    }
    try rows.finish(null);
    rows.deinit();
    try out.writer.writeAll("],\"news_markers\":[");
    rows = try context.store.connection.queryParams("SELECT feed,seen_through_capture_id,rendered_at FROM news_markers WHERE user_id=?1 ORDER BY feed", .{auth.user_id}, .{});
    first = true;
    while (try rows.next()) |row| {
        if (!first) try out.writer.writeByte(',');
        first = false;
        try out.writer.writeAll("{\"feed\":");
        try std.json.Stringify.encodeJsonString(try row.get([]const u8, 0), .{}, &out.writer);
        try out.writer.print(",\"seen_through_capture_id\":{d},\"rendered_at\":{d}}}", .{ try row.get(i64, 1), try row.get(i64, 2) });
    }
    try rows.finish(null);
    rows.deinit();
    try out.writer.writeAll("]}");
    const body = try out.toOwnedSlice();
    return response.respond(request, body, .{ .content_type = "application/json; charset=utf-8", .cache_control = "no-store", .extra_headers = security(context).slice() });
}

fn jsonOptionalInt(writer: *std.Io.Writer, value: ?i64) !void {
    if (value) |number| try writer.print("{d}", .{number}) else try writer.writeAll("null");
}

fn logout(context: *Context, request: *std.http.Server.Request, auth: Auth) !void {
    _ = try context.store.connection.execParams("UPDATE sessions SET revoked_at=?2 WHERE token_hash=?1", .{ &auth.session_hash, std.Io.Timestamp.now(context.io, .real).toSeconds() }, .{});
    return redirectClearingSession(context, request);
}

fn redirectClearingSession(context: *Context, request: *std.http.Server.Request) !void {
    var base = security(context);
    var headers: [12]std.http.Header = undefined;
    var count: usize = 0;
    for (base.slice()) |header| {
        headers[count] = header;
        count += 1;
    }
    headers[count] = .{ .name = "set-cookie", .value = if (context.secure_transport) "__Host-hnc_session=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0" else "hnc_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0" };
    count += 1;
    headers[count] = .{ .name = "set-cookie", .value = if (context.secure_transport) "__Host-hnc_csrf=; Path=/; Secure; SameSite=Lax; Max-Age=0" else "hnc_csrf=; Path=/; SameSite=Lax; Max-Age=0" };
    count += 1;
    return response.redirect(request, "/news", .see_other, headers[0..count]);
}

fn atomTimestamp(writer: *std.Io.Writer, timestamp: i64) !void {
    if (timestamp < 0) return error.InvalidTimestamp;
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = epoch.getDaySeconds();
    try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    });
}

const Boundaries = struct { items: i64, events: i64 };

fn currentBoundaries(store: *database_mod.Store) !Boundaries {
    var rows = try store.connection.query("SELECT COALESCE((SELECT processed_through FROM ingest_cursors WHERE stream='hn_items'),0),COALESCE((SELECT MAX(id) FROM events),0)", &.{}, .{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    const result: Boundaries = .{ .items = try row.get(i64, 0), .events = try row.get(i64, 1) };
    try rows.finish(null);
    return result;
}

fn userCount(store: *database_mod.Store, sql: []const u8, user_id: []const u8) !i64 {
    var rows = try store.connection.queryParams(sql, .{user_id}, .{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.MissingCount;
    const value = try row.get(i64, 0);
    try rows.finish(null);
    return value;
}

fn latestCapture(store: *database_mod.Store) !?i64 {
    var rows = try store.connection.query("SELECT MAX(id) FROM feed_captures WHERE feed='top'", &.{}, .{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    const value = try row.get(?i64, 0);
    try rows.finish(null);
    return value;
}

fn accountNewsMarker(store: *database_mod.Store, user_id: []const u8) !?i64 {
    var rows = try store.connection.queryParams("SELECT seen_through_capture_id FROM news_markers WHERE user_id=?1 AND feed='top'", .{user_id}, .{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return null;
    const value = try row.get(i64, 0);
    try rows.finish(null);
    return value;
}

fn anonymousNewsMarker(request: *std.http.Server.Request) ?i64 {
    const cookies = request_util.header(request, "cookie") orelse return null;
    const raw = request_util.findCookie(cookies, "hnc_news") orelse return null;
    const value = std.fmt.parseInt(i64, raw, 10) catch return null;
    return if (value >= 0) value else null;
}

fn threadMarker(store: *database_mod.Store, user_id: []const u8, story_id: i64) !?i64 {
    var rows = try store.connection.queryParams("SELECT seen_through_item_id FROM thread_markers WHERE user_id=?1 AND root_story_id=?2", .{ user_id, story_id }, .{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return null;
    const value = try row.get(i64, 0);
    try rows.finish(null);
    return value;
}

fn formValue(allocator: std.mem.Allocator, body: []const u8, wanted: []const u8) ![]u8 {
    var iterator = request_util.formIterator(body, 32);
    var result: ?[]u8 = null;
    while (try iterator.next()) |parameter| if (std.mem.eql(u8, parameter.name, wanted)) {
        if (result != null) return error.DuplicateFormValue;
        const buffer = try allocator.alloc(u8, parameter.value.len);
        result = try request_util.decodeComponent(buffer, parameter.value, true);
    };
    return result orelse error.MissingFormValue;
}

const csrf_only = [_][]const u8{"csrf"};
const csrf_return = [_][]const u8{ "csrf", "return" };
const csrf_bounds = [_][]const u8{ "csrf", "from", "through" };
const csrf_watch = [_][]const u8{ "csrf", "scope_kind", "scope_item_id" };
const csrf_identity = [_][]const u8{ "csrf", "username", "confirm" };
const csrf_feed = [_][]const u8{ "csrf", "scope" };
const csrf_delete = [_][]const u8{ "csrf", "confirm" };
const csrf_passkey = [_][]const u8{ "csrf", "credential_id" };
const csrf_passkey_rename = [_][]const u8{ "csrf", "credential_id", "label" };
const csrf_session = [_][]const u8{ "csrf", "session_hash" };

fn formSchema(path: []const u8) ?[]const []const u8 {
    if (std.mem.startsWith(u8, path, "/inbox/") and std.mem.endsWith(u8, path, "/open")) return &csrf_return;
    if (std.mem.eql(u8, path, "/inbox/read-all")) return &csrf_bounds;
    if (std.mem.startsWith(u8, path, "/inbox/") and std.mem.endsWith(u8, path, "/unread")) return &csrf_only;
    if (std.mem.startsWith(u8, path, "/inbox/") and std.mem.endsWith(u8, path, "/dismiss")) return &csrf_only;
    if (std.mem.eql(u8, path, "/watches")) return &csrf_watch;
    if (std.mem.startsWith(u8, path, "/watches/")) return &csrf_only;
    if (std.mem.eql(u8, path, "/settings/identities")) return &csrf_identity;
    if (std.mem.startsWith(u8, path, "/settings/identities/")) return &csrf_only;
    if (std.mem.eql(u8, path, "/settings/feeds")) return &csrf_feed;
    if (std.mem.startsWith(u8, path, "/settings/feeds/")) return &csrf_only;
    if (std.mem.eql(u8, path, "/settings/passkeys/revoke")) return &csrf_passkey;
    if (std.mem.eql(u8, path, "/settings/passkeys/rename")) return &csrf_passkey_rename;
    if (std.mem.eql(u8, path, "/settings/sessions/revoke")) return &csrf_session;
    if (std.mem.eql(u8, path, "/settings/export") or std.mem.eql(u8, path, "/auth/logout")) return &csrf_only;
    if (std.mem.eql(u8, path, "/settings/delete")) return &csrf_delete;
    return null;
}

fn validateForm(body: []const u8, allowed: []const []const u8) !void {
    if (allowed.len > 8) return error.InvalidSchema;
    var seen: [8]bool = @splat(false);
    var iterator = request_util.formIterator(body, 32);
    while (try iterator.next()) |parameter| {
        var matched = false;
        for (allowed, 0..) |name, index| if (std.mem.eql(u8, parameter.name, name)) {
            if (seen[index]) return error.DuplicateFormField;
            seen[index] = true;
            matched = true;
            break;
        };
        if (!matched) return error.UnknownFormField;
    }
}

fn queryValue(allocator: std.mem.Allocator, target: request_util.Target, wanted: []const u8) ![]u8 {
    var iterator = request_util.queryIterator(target, 16);
    while (try iterator.next()) |parameter| if (std.mem.eql(u8, parameter.name, wanted)) {
        const buffer = try allocator.alloc(u8, parameter.value.len);
        return request_util.decodeComponent(buffer, parameter.value, false);
    };
    return error.MissingQueryValue;
}

fn parsePathId(path: []const u8, prefix: []const u8) !i64 {
    const raw = path[prefix.len..];
    if (raw.len == 0 or std.mem.indexOfScalar(u8, raw, '/') != null) return error.InvalidId;
    const id = try std.fmt.parseInt(i64, raw, 10);
    if (id < 0) return error.InvalidId;
    return id;
}

fn hash(value: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn randomToken(io: std.Io, storage: *[48]u8) []const u8 {
    var random: [24]u8 = undefined;
    io.random(&random);
    const encoded = std.fmt.bytesToHex(random, .lower);
    @memcpy(storage, &encoded);
    return storage;
}

fn jsonInteger(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return if (value == .integer) value.integer else null;
}

fn security(context: *Context) security_headers.HeaderSet {
    return security_headers.build(.{
        .content_security_policy = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
        .permissions_policy = "publickey-credentials-create=(self), publickey-credentials-get=(self), camera=(), microphone=(), geolocation=()",
        .referrer_policy = "same-origin",
        .secure_transport = context.secure_transport,
        .same_origin_isolation = true,
    });
}

fn validRequestOrigin(context: *Context, request: *std.http.Server.Request) bool {
    const origin = request_util.header(request, "origin") orelse return false;
    return std.mem.eql(u8, origin, context.auth_policy.origin);
}

fn jsonProblem(context: *Context, request: *std.http.Server.Request, status: std.http.Status, message: []const u8) !void {
    var storage: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try writer.writeAll("{\"error\":");
    try std.json.Stringify.encodeJsonString(message, .{}, &writer);
    try writer.writeAll("}\n");
    return response.json(request, writer.buffered(), status, security(context).slice());
}

fn htmlPage(context: *Context, request: *std.http.Server.Request, body: []const u8) !void {
    return response.html(request, body, .ok, security(context).slice());
}

fn htmlPageWithNewsCookie(context: *Context, request: *std.http.Server.Request, body: []const u8, capture_id: ?i64) !void {
    const id = capture_id orelse return htmlPage(context, request, body);
    var cookie_storage: [160]u8 = undefined;
    const cookie = try std.fmt.bufPrint(&cookie_storage, "hnc_news={d}; Path=/; SameSite=Lax; Max-Age=31536000{s}", .{ id, if (context.secure_transport) "; Secure" else "" });
    var base = security(context);
    var headers: [12]std.http.Header = undefined;
    var count: usize = 0;
    for (base.slice()) |header| {
        headers[count] = header;
        count += 1;
    }
    headers[count] = .{ .name = "set-cookie", .value = cookie };
    count += 1;
    return response.html(request, body, .ok, headers[0..count]);
}

fn asset(context: *Context, request: *std.http.Server.Request, body: []const u8, content_type: []const u8) !void {
    return response.respond(request, body, .{ .content_type = content_type, .cache_control = "public, max-age=3600", .extra_headers = security(context).slice() });
}

fn problem(context: *Context, request: *std.http.Server.Request, status: std.http.Status, message: []const u8) !void {
    return response.respond(request, message, .{ .status = status, .content_type = "text/plain; charset=utf-8", .cache_control = "no-store", .extra_headers = security(context).slice() });
}

fn loginRedirect(context: *Context, request: *std.http.Server.Request, return_to: []const u8) !void {
    _ = return_to;
    return response.redirect(request, "/auth/login", .see_other, security(context).slice());
}
