const std = @import("std");
const passcay = @import("passcay");
const zbor = @import("zbor");

pub const Registration = struct {
    credential_id: []const u8,
    public_key: []const u8,
    algorithm: i32,
    sign_count: u32,
    aaguid: []const u8,
    backup_eligible: bool,
    backup_state: bool,

    pub fn deinit(self: Registration, allocator: std.mem.Allocator) void {
        allocator.free(self.credential_id);
        allocator.free(self.public_key);
        allocator.free(self.aaguid);
    }
};

pub const Authentication = struct {
    recommended_sign_count: u32,
    backup_state: bool,
    sign_count_regressed: bool,
};

pub fn verifyRegistration(allocator: std.mem.Allocator, attestation_object: []const u8, client_data_json: []const u8, challenge: []const u8, origin: []const u8, rp_id: []const u8) !Registration {
    try validateEncoded(attestation_object, 128 * 1024);
    try validateEncoded(client_data_json, 16 * 1024);
    try guardClientData(allocator, client_data_json);
    const verified = try passcay.register.verify(allocator, .{
        .attestation_object = attestation_object,
        .client_data_json = client_data_json,
    }, .{
        .challenge = challenge,
        .origin = origin,
        .rp_id = rp_id,
        .require_user_verification = true,
        .require_user_presence = true,
        .attestation = null,
    });
    defer verified.deinit(allocator);
    try validateEncoded(verified.credential_id, 1024);
    const public_key_bytes = try passcay.util.decodeBase64Url(allocator, verified.public_key);
    defer allocator.free(public_key_bytes);
    const algorithm = try coseAlgorithm(public_key_bytes);
    if (algorithm != -7 and algorithm != -257) return error.UnsupportedAlgorithm;
    try validateBackupFlags(verified.flags);
    return .{
        .credential_id = try allocator.dupe(u8, verified.credential_id),
        .public_key = try allocator.dupe(u8, verified.public_key),
        .algorithm = algorithm,
        .sign_count = verified.sign_count,
        .aaguid = try allocator.dupe(u8, verified.aaguid),
        .backup_eligible = verified.flags & 0x08 != 0,
        .backup_state = verified.flags & 0x10 != 0,
    };
}

pub fn verifyAuthentication(allocator: std.mem.Allocator, authenticator_data: []const u8, client_data_json: []const u8, signature: []const u8, public_key: []const u8, challenge: []const u8, origin: []const u8, rp_id: []const u8, known_sign_count: u32) !Authentication {
    try validateEncoded(authenticator_data, 8 * 1024);
    try validateEncoded(client_data_json, 16 * 1024);
    try validateEncoded(signature, 8 * 1024);
    try guardClientData(allocator, client_data_json);
    const verified = try passcay.auth.verify(allocator, .{
        .authenticator_data = authenticator_data,
        .client_data_json = client_data_json,
        .signature = signature,
    }, .{
        .public_key = public_key,
        .challenge = challenge,
        .origin = origin,
        .rp_id = rp_id,
        .require_user_verification = true,
        .require_user_presence = true,
        .enable_sign_count_check = false,
        .known_sign_count = known_sign_count,
    });
    defer verified.deinit(allocator);
    try validateBackupFlags(verified.flags);
    return .{
        .recommended_sign_count = @max(verified.sign_count, known_sign_count),
        .backup_state = verified.flags & 0x10 != 0,
        .sign_count_regressed = known_sign_count > 0 and verified.sign_count > 0 and verified.sign_count < known_sign_count,
    };
}

const ClientDataGuard = struct { crossOrigin: ?bool = null, topOrigin: ?[]const u8 = null };

fn guardClientData(allocator: std.mem.Allocator, encoded: []const u8) !void {
    const decoded = try passcay.util.decodeBase64Url(allocator, encoded);
    defer allocator.free(decoded);
    if (decoded.len > 16 * 1024) return error.WebAuthnFieldTooLarge;
    const parsed = try std.json.parseFromSlice(ClientDataGuard, allocator, decoded, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.crossOrigin orelse false or parsed.value.topOrigin != null) return error.CrossOriginCeremony;
}

fn validateEncoded(value: []const u8, decoded_limit: usize) !void {
    if (value.len == 0) return error.MissingWebAuthnField;
    if (value.len > decoded_limit * 4 / 3 + 8) return error.WebAuthnFieldTooLarge;
}

fn validateBackupFlags(flags: u8) !void {
    if (flags & 0x10 != 0 and flags & 0x08 == 0) return error.InvalidBackupFlags;
}

fn coseAlgorithm(public_key: []const u8) !i32 {
    const item = try zbor.DataItem.new(public_key);
    var map = item.map() orelse return error.InvalidCoseKey;
    while (map.next()) |pair| {
        if ((pair.key.int() orelse continue) != 3) continue;
        const value = pair.value.int() orelse return error.InvalidCoseKey;
        if (value < std.math.minInt(i32) or value > std.math.maxInt(i32)) return error.UnsupportedAlgorithm;
        return @intCast(value);
    }
    return error.InvalidCoseKey;
}
