const std = @import("std");
const turso = @import("turso");
const database_mod = @import("../store/database.zig");
const passkeys = @import("passkeys.zig");

pub const Policy = struct { origin: []const u8, rp_id: []const u8 };
pub const Session = struct { token: []u8, csrf: []u8, user_id: []u8, expires_at: i64 };
pub const RegistrationInput = struct {
    challenge_id: []const u8,
    credential_id: []const u8,
    client_data_json: []const u8,
    attestation_object: []const u8,
    transports: []const u8 = "",
    label: []const u8 = "Passkey",
};
pub const AuthenticationInput = struct {
    challenge_id: []const u8,
    credential_id: []const u8,
    client_data_json: []const u8,
    authenticator_data: []const u8,
    signature: []const u8,
};

const Challenge = struct { id: []u8, purpose: []u8, challenge: []u8, user_id: ?[]u8, expires_at: i64, used_at: ?i64 };
const Credential = struct { user_id: []u8, public_key: []u8, sign_count: u32, revoked_at: ?i64 };

pub fn registrationOptions(store: *database_mod.Store, allocator: std.mem.Allocator, io: std.Io, policy: Policy, writer: *std.Io.Writer) !void {
    try validatePolicy(policy);
    const challenge_id = try randomToken(io, allocator, 24);
    defer allocator.free(challenge_id);
    const challenge = try randomToken(io, allocator, 32);
    defer allocator.free(challenge);
    const binding = hash(challenge_id);
    const current = now(io);
    try prune(store, current);
    _ = try store.connection.execParams("INSERT INTO auth_challenges(id,purpose,challenge_hash,user_id,binding_hash,created_at,expires_at) VALUES(?1,'register',?2,NULL,?3,?4,?5)", .{ challenge_id, challenge, &binding, current, current + 300 }, .{});
    try writer.writeAll("{\"challenge_id\":");
    try jsonString(writer, challenge_id);
    try writer.writeAll(",\"publicKey\":{\"challenge\":");
    try jsonString(writer, challenge);
    try writer.writeAll(",\"rp\":{\"name\":\"HN Continuity\",\"id\":");
    try jsonString(writer, policy.rp_id);
    try writer.writeAll("},\"user\":{\"id\":");
    try jsonString(writer, challenge_id);
    try writer.writeAll(",\"name\":\"continuity-reader\",\"displayName\":\"HN Continuity reader\"},\"pubKeyCredParams\":[{\"type\":\"public-key\",\"alg\":-7},{\"type\":\"public-key\",\"alg\":-257}],\"timeout\":300000,\"attestation\":\"none\",\"authenticatorSelection\":{\"residentKey\":\"required\",\"requireResidentKey\":true,\"userVerification\":\"required\"},\"excludeCredentials\":[]}}\n");
}

pub fn authenticationOptions(store: *database_mod.Store, allocator: std.mem.Allocator, io: std.Io, policy: Policy, writer: *std.Io.Writer) !void {
    try validatePolicy(policy);
    const challenge_id = try randomToken(io, allocator, 24);
    defer allocator.free(challenge_id);
    const challenge = try randomToken(io, allocator, 32);
    defer allocator.free(challenge);
    const binding = hash("authentication");
    const current = now(io);
    try prune(store, current);
    _ = try store.connection.execParams("INSERT INTO auth_challenges(id,purpose,challenge_hash,user_id,binding_hash,created_at,expires_at) VALUES(?1,'authenticate',?2,NULL,?3,?4,?5)", .{ challenge_id, challenge, &binding, current, current + 300 }, .{});
    try writer.writeAll("{\"challenge_id\":");
    try jsonString(writer, challenge_id);
    try writer.writeAll(",\"publicKey\":{\"challenge\":");
    try jsonString(writer, challenge);
    try writer.writeAll(",\"rpId\":");
    try jsonString(writer, policy.rp_id);
    try writer.writeAll(",\"timeout\":300000,\"userVerification\":\"required\",\"allowCredentials\":[]}}\n");
}

pub fn addCredentialOptions(store: *database_mod.Store, allocator: std.mem.Allocator, io: std.Io, policy: Policy, user_id: []const u8, writer: *std.Io.Writer) !void {
    try validatePolicy(policy);
    const challenge_id = try randomToken(io, allocator, 24);
    defer allocator.free(challenge_id);
    const challenge = try randomToken(io, allocator, 32);
    defer allocator.free(challenge);
    const binding = hash(user_id);
    const current = now(io);
    try prune(store, current);
    _ = try store.connection.execParams("INSERT INTO auth_challenges(id,purpose,challenge_hash,user_id,binding_hash,created_at,expires_at) VALUES(?1,'add_credential',?2,?3,?4,?5,?6)", .{ challenge_id, challenge, user_id, &binding, current, current + 300 }, .{});
    try writer.writeAll("{\"challenge_id\":");
    try jsonString(writer, challenge_id);
    try writer.writeAll(",\"publicKey\":{\"challenge\":");
    try jsonString(writer, challenge);
    try writer.writeAll(",\"rp\":{\"name\":\"HN Continuity\",\"id\":");
    try jsonString(writer, policy.rp_id);
    try writer.writeAll("},\"user\":{\"id\":");
    try jsonString(writer, user_id);
    try writer.writeAll(",\"name\":\"continuity-reader\",\"displayName\":\"HN Continuity reader\"},\"pubKeyCredParams\":[{\"type\":\"public-key\",\"alg\":-7},{\"type\":\"public-key\",\"alg\":-257}],\"timeout\":300000,\"attestation\":\"none\",\"authenticatorSelection\":{\"residentKey\":\"required\",\"requireResidentKey\":true,\"userVerification\":\"required\"},\"excludeCredentials\":[");
    var rows = try store.connection.queryParams("SELECT credential_id FROM auth_credentials WHERE user_id=?1 AND revoked_at IS NULL ORDER BY created_at", .{user_id}, .{});
    defer rows.deinit();
    var first = true;
    while (try rows.next()) |row| {
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.writeAll("{\"type\":\"public-key\",\"id\":");
        try jsonString(writer, try row.get([]const u8, 0));
        try writer.writeByte('}');
    }
    try rows.finish(null);
    try writer.writeAll("]}}\n");
}

pub fn finishRegistration(store: *database_mod.Store, allocator: std.mem.Allocator, io: std.Io, policy: Policy, input: RegistrationInput) !Session {
    try validateLabel(input.label);
    try validateTransports(input.transports);
    const challenge = (try findChallenge(store, allocator, input.challenge_id)) orelse return error.InvalidChallenge;
    defer challengeDeinit(allocator, challenge);
    const current = now(io);
    if (!std.mem.eql(u8, challenge.purpose, "register") or challenge.used_at != null or challenge.expires_at <= current) return error.InvalidChallenge;
    const verified = passkeys.verifyRegistration(allocator, input.attestation_object, input.client_data_json, challenge.challenge, policy.origin, policy.rp_id) catch return error.InvalidPasskeyResponse;
    defer verified.deinit(allocator);
    if (!std.mem.eql(u8, verified.credential_id, input.credential_id)) return error.InvalidPasskeyResponse;
    var diagnostics: turso.Diagnostics = .{};
    var transaction = try store.connection.begin(.immediate, .{ .diagnostics = &diagnostics });
    defer transaction.deinit();
    if (try transaction.execParams("UPDATE auth_challenges SET used_at=?2 WHERE id=?1 AND used_at IS NULL AND expires_at>?2", .{ challenge.id, current }, .{}) != 1) return error.InvalidChallenge;
    _ = try transaction.execParams("INSERT INTO app_users(id,created_at) VALUES(?1,?2)", .{ challenge.id, current }, .{});
    _ = try transaction.execParams("INSERT INTO auth_credentials(credential_id,user_id,public_key,algorithm,sign_count,transports,aaguid,backup_eligible,backup_state,label,created_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)", .{ verified.credential_id, challenge.id, verified.public_key, verified.algorithm, verified.sign_count, input.transports, verified.aaguid, verified.backup_eligible, verified.backup_state, input.label, current }, .{});
    const session = try issueSessionTransaction(&transaction, allocator, io, challenge.id, current);
    try transaction.commit(&diagnostics);
    return session;
}

pub fn finishAuthentication(store: *database_mod.Store, allocator: std.mem.Allocator, io: std.Io, policy: Policy, input: AuthenticationInput) !Session {
    const challenge = (try findChallenge(store, allocator, input.challenge_id)) orelse return error.InvalidChallenge;
    defer challengeDeinit(allocator, challenge);
    const current = now(io);
    if (!std.mem.eql(u8, challenge.purpose, "authenticate") or challenge.used_at != null or challenge.expires_at <= current) return error.InvalidChallenge;
    const credential = (try findCredential(store, allocator, input.credential_id)) orelse return error.InvalidPasskeyResponse;
    defer credentialDeinit(allocator, credential);
    if (credential.revoked_at != null) return error.InvalidPasskeyResponse;
    const verified = passkeys.verifyAuthentication(allocator, input.authenticator_data, input.client_data_json, input.signature, credential.public_key, challenge.challenge, policy.origin, policy.rp_id, credential.sign_count) catch return error.InvalidPasskeyResponse;
    if (verified.sign_count_regressed) return error.InvalidPasskeyResponse;
    var diagnostics: turso.Diagnostics = .{};
    var transaction = try store.connection.begin(.immediate, .{ .diagnostics = &diagnostics });
    defer transaction.deinit();
    if (try transaction.execParams("UPDATE auth_challenges SET used_at=?2 WHERE id=?1 AND used_at IS NULL AND expires_at>?2", .{ challenge.id, current }, .{}) != 1) return error.InvalidChallenge;
    _ = try transaction.execParams("UPDATE auth_credentials SET sign_count=?2,backup_state=?3,last_used_at=?4 WHERE credential_id=?1 AND revoked_at IS NULL", .{ input.credential_id, verified.recommended_sign_count, verified.backup_state, current }, .{});
    const session = try issueSessionTransaction(&transaction, allocator, io, credential.user_id, current);
    try transaction.commit(&diagnostics);
    return session;
}

pub fn finishAddCredential(store: *database_mod.Store, allocator: std.mem.Allocator, io: std.Io, policy: Policy, user_id: []const u8, input: RegistrationInput) !void {
    try validateLabel(input.label);
    try validateTransports(input.transports);
    const challenge = (try findChallenge(store, allocator, input.challenge_id)) orelse return error.InvalidChallenge;
    defer challengeDeinit(allocator, challenge);
    const current = now(io);
    if (!std.mem.eql(u8, challenge.purpose, "add_credential") or challenge.used_at != null or challenge.expires_at <= current or challenge.user_id == null or !std.mem.eql(u8, challenge.user_id.?, user_id)) return error.InvalidChallenge;
    const verified = passkeys.verifyRegistration(allocator, input.attestation_object, input.client_data_json, challenge.challenge, policy.origin, policy.rp_id) catch return error.InvalidPasskeyResponse;
    defer verified.deinit(allocator);
    if (!std.mem.eql(u8, verified.credential_id, input.credential_id)) return error.InvalidPasskeyResponse;
    var diagnostics: turso.Diagnostics = .{};
    var transaction = try store.connection.begin(.immediate, .{ .diagnostics = &diagnostics });
    defer transaction.deinit();
    const credential_count: i64 = count: {
        var rows = try transaction.queryParams("SELECT COUNT(*) FROM auth_credentials WHERE user_id=?1 AND revoked_at IS NULL", .{user_id}, .{});
        defer rows.deinit();
        const row = (try rows.next()) orelse return error.MissingCredentialCount;
        const value = try row.get(i64, 0);
        try rows.finish(null);
        break :count value;
    };
    if (credential_count >= 5) return error.CredentialLimitReached;
    if (try transaction.execParams("UPDATE auth_challenges SET used_at=?2 WHERE id=?1 AND used_at IS NULL AND expires_at>?2", .{ challenge.id, current }, .{}) != 1) return error.InvalidChallenge;
    _ = try transaction.execParams("INSERT INTO auth_credentials(credential_id,user_id,public_key,algorithm,sign_count,transports,aaguid,backup_eligible,backup_state,label,created_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)", .{ verified.credential_id, user_id, verified.public_key, verified.algorithm, verified.sign_count, input.transports, verified.aaguid, verified.backup_eligible, verified.backup_state, input.label, current }, .{});
    try transaction.commit(&diagnostics);
}

fn issueSessionTransaction(transaction: *turso.Transaction, allocator: std.mem.Allocator, io: std.Io, user_id: []const u8, current: i64) !Session {
    const session_count: i64 = count: {
        var rows = try transaction.queryParams("SELECT COUNT(*) FROM sessions WHERE user_id=?1 AND revoked_at IS NULL AND expires_at>?2", .{ user_id, current }, .{});
        defer rows.deinit();
        const row = (try rows.next()) orelse return error.MissingSessionCount;
        const value = try row.get(i64, 0);
        try rows.finish(null);
        break :count value;
    };
    if (session_count >= 10) return error.SessionLimitReached;
    const token = try randomToken(io, allocator, 32);
    errdefer allocator.free(token);
    const csrf = try randomToken(io, allocator, 32);
    errdefer allocator.free(csrf);
    const token_hash = hash(token);
    const csrf_hash = hash(csrf);
    const expires = current + 30 * 24 * 60 * 60;
    _ = try transaction.execParams("INSERT INTO sessions(token_hash,user_id,csrf_hash,created_at,last_seen_at,expires_at,label) VALUES(?1,?2,?3,?4,?4,?5,'Passkey session')", .{ &token_hash, user_id, &csrf_hash, current, expires }, .{});
    return .{ .token = token, .csrf = csrf, .user_id = try allocator.dupe(u8, user_id), .expires_at = expires };
}

fn findChallenge(store: *database_mod.Store, allocator: std.mem.Allocator, id: []const u8) !?Challenge {
    if (id.len < 22 or id.len > 128) return null;
    var rows = try store.connection.queryParams("SELECT id,purpose,challenge_hash,user_id,expires_at,used_at FROM auth_challenges WHERE id=?1", .{id}, .{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return null;
    const result: Challenge = .{ .id = try allocator.dupe(u8, try row.get([]const u8, 0)), .purpose = try allocator.dupe(u8, try row.get([]const u8, 1)), .challenge = try allocator.dupe(u8, try row.get([]const u8, 2)), .user_id = if (try row.get(?[]const u8, 3)) |value| try allocator.dupe(u8, value) else null, .expires_at = try row.get(i64, 4), .used_at = try row.get(?i64, 5) };
    try rows.finish(null);
    return result;
}

fn findCredential(store: *database_mod.Store, allocator: std.mem.Allocator, id: []const u8) !?Credential {
    if (id.len == 0 or id.len > 2048) return null;
    var rows = try store.connection.queryParams("SELECT user_id,public_key,sign_count,revoked_at FROM auth_credentials WHERE credential_id=?1", .{id}, .{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return null;
    const result: Credential = .{ .user_id = try allocator.dupe(u8, try row.get([]const u8, 0)), .public_key = try allocator.dupe(u8, try row.get([]const u8, 1)), .sign_count = try row.get(u32, 2), .revoked_at = try row.get(?i64, 3) };
    try rows.finish(null);
    return result;
}

fn randomToken(io: std.Io, allocator: std.mem.Allocator, byte_count: usize) ![]u8 {
    if (byte_count > 64) return error.TokenTooLarge;
    var bytes: [64]u8 = undefined;
    try io.randomSecure(bytes[0..byte_count]);
    defer std.crypto.secureZero(u8, &bytes);
    const output = try allocator.alloc(u8, byte_count * 2);
    const alphabet = "0123456789abcdef";
    for (bytes[0..byte_count], 0..) |byte, index| {
        output[index * 2] = alphabet[byte >> 4];
        output[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return output;
}

fn prune(store: *database_mod.Store, current: i64) !void {
    _ = try store.connection.execParams("DELETE FROM auth_challenges WHERE expires_at<=?1 OR used_at IS NOT NULL", .{current}, .{});
}

fn validatePolicy(policy: Policy) !void {
    if (policy.rp_id.len == 0 or policy.rp_id.len > 253) return error.InvalidPolicy;
    if (!(std.mem.startsWith(u8, policy.origin, "https://") or std.mem.startsWith(u8, policy.origin, "http://127.0.0.1:") or std.mem.startsWith(u8, policy.origin, "http://localhost:"))) return error.InvalidPolicy;
}

fn validateLabel(label: []const u8) !void {
    if (label.len == 0 or label.len > 64 or !std.unicode.utf8ValidateSlice(label)) return error.InvalidLabel;
}

fn validateTransports(value: []const u8) !void {
    if (value.len > 256) return error.InvalidTransports;
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| if (part.len != 0 and !std.mem.eql(u8, part, "internal") and !std.mem.eql(u8, part, "hybrid") and !std.mem.eql(u8, part, "usb") and !std.mem.eql(u8, part, "nfc") and !std.mem.eql(u8, part, "ble")) return error.InvalidTransports;
}

fn hash(value: []const u8) [64]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &raw, .{});
    return std.fmt.bytesToHex(raw, .lower);
}

fn now(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

fn challengeDeinit(allocator: std.mem.Allocator, value: Challenge) void {
    allocator.free(value.id);
    allocator.free(value.purpose);
    allocator.free(value.challenge);
    if (value.user_id) |user_id| allocator.free(user_id);
}

fn credentialDeinit(allocator: std.mem.Allocator, value: Credential) void {
    allocator.free(value.user_id);
    allocator.free(value.public_key);
}

fn jsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.encodeJsonString(value, .{}, writer);
}

test "passkey policy refuses cleartext non-loopback origins" {
    try validatePolicy(.{ .origin = "https://continuity.example", .rp_id = "continuity.example" });
    try std.testing.expectError(error.InvalidPolicy, validatePolicy(.{ .origin = "http://continuity.example", .rp_id = "continuity.example" }));
}
