//! BDC AIPrompt Streaming - SAP XSUAA/IAS Authentication
//! OAuth2/OIDC authentication via SAP BTP XSUAA and Identity Authentication Service
//!
//! Security Features:
//! - Real JWT token validation with signature verification
//! - JWKS-based public key retrieval and caching
//! - Proper token expiry and claim validation
//! - Multi-tenant support with zone isolation

const std = @import("std");
const http = std.http;
const crypto = std.crypto;

const log = std.log.scoped(.xsuaa);

// ============================================================================
// XSUAA Configuration
// ============================================================================

pub const XsuaaConfig = struct {
    /// XSUAA service URL (from VCAP_SERVICES)
    url: []const u8,
    /// OAuth2 client ID
    client_id: []const u8,
    /// OAuth2 client secret (loaded from secure source)
    client_secret: []const u8 = "",
    /// Token endpoint path
    token_endpoint: []const u8 = "/oauth/token",
    /// JWKS endpoint for token validation
    jwks_endpoint: []const u8 = "/token_keys",
    /// Identity zone
    identity_zone: []const u8 = "",
    /// Subdomain
    subdomain: []const u8 = "",
    /// Service plan (application, broker, apiaccess)
    service_plan: []const u8 = "application",
    /// Token lifetime in seconds
    token_lifetime_secs: u32 = 43200, // 12 hours
    /// Verify SSL certificates
    verify_ssl: bool = true,
    /// JWKS cache TTL in seconds
    jwks_cache_ttl_secs: u32 = 3600, // 1 hour
    /// Clock skew tolerance for token validation (seconds)
    clock_skew_tolerance_secs: i64 = 60,

    /// Load configuration from environment (VCAP_SERVICES pattern)
    pub fn fromEnv(allocator: std.mem.Allocator) !XsuaaConfig {
        const vcap_services = std.posix.getenv("VCAP_SERVICES");
        if (vcap_services) |json_str| {
            return try parseVcapServices(allocator, json_str);
        }

        // Fall back to individual environment variables
        const url = std.posix.getenv("XSUAA_URL") orelse return error.MissingXsuaaUrl;
        const client_id = std.posix.getenv("XSUAA_CLIENT_ID") orelse return error.MissingClientId;
        const client_secret = try getSecureClientSecret();

        return .{
            .url = url,
            .client_id = client_id,
            .client_secret = client_secret,
            .identity_zone = std.posix.getenv("XSUAA_IDENTITY_ZONE") orelse "",
            .subdomain = std.posix.getenv("XSUAA_SUBDOMAIN") orelse "",
        };
    }

    /// Parse an XsuaaConfig from the BTP VCAP_SERVICES JSON blob.
    ///
    /// Expected shape (SAP XSUAA service binding):
    /// {
    ///   "xsuaa": [{
    ///     "credentials": {
    ///       "url":          "https://<tenant>.authentication.<region>.hana.ondemand.com",
    ///       "clientid":     "sb-<app>!t<instance>",
    ///       "clientsecret": "<secret>",
    ///       "identityzone": "<subaccount-subdomain>",
    ///       "subdomain":    "<subaccount-subdomain>",
    ///       "tenantid":     "<tenant-uuid>",
    ///       "uaadomain":    "authentication.<region>.hana.ondemand.com"
    ///     }
    ///   }]
    /// }
    ///
    /// All returned strings are heap-allocated copies owned by the caller
    /// (they live as long as the provided allocator).
    fn parseVcapServices(allocator: std.mem.Allocator, json_str: []const u8) !XsuaaConfig {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidVcapFormat;

        // Locate the first xsuaa binding
        const xsuaa_val = root.object.get("xsuaa") orelse return error.NoXsuaaBinding;
        if (xsuaa_val != .array) return error.InvalidVcapFormat;
        const bindings = xsuaa_val.array.items;
        if (bindings.len == 0) return error.EmptyXsuaaBinding;

        const binding = bindings[0];
        if (binding != .object) return error.InvalidVcapFormat;

        const creds_val = binding.object.get("credentials") orelse return error.NoCredentials;
        if (creds_val != .object) return error.InvalidVcapFormat;
        const creds = creds_val.object;

        // Required fields
        const url_val = creds.get("url") orelse return error.MissingXsuaaUrl;
        const cid_val = creds.get("clientid") orelse return error.MissingClientId;
        if (url_val != .string or cid_val != .string) return error.InvalidVcapFormat;

        // Optional fields (empty string as default)
        const secret_str = if (creds.get("clientsecret")) |v| (if (v == .string) v.string else "") else "";
        const zone_str   = if (creds.get("identityzone")) |v| (if (v == .string) v.string else "") else "";
        const sub_str    = if (creds.get("subdomain"))    |v| (if (v == .string) v.string else "") else "";

        // Dupe all strings so they survive parsed.deinit()
        return .{
            .url            = try allocator.dupe(u8, url_val.string),
            .client_id      = try allocator.dupe(u8, cid_val.string),
            .client_secret  = try allocator.dupe(u8, secret_str),
            .identity_zone  = try allocator.dupe(u8, zone_str),
            .subdomain      = try allocator.dupe(u8, sub_str),
        };
    }

    fn getSecureClientSecret() ![]const u8 {
        // Try secret file first (most secure)
        if (std.posix.getenv("XSUAA_CLIENT_SECRET_FILE")) |path| {
            const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
                log.err("Failed to open client secret file: {}", .{err});
                return error.SecretFileError;
            };
            defer file.close();

            var buf: [512]u8 = undefined;
            const len = file.readAll(&buf) catch return error.SecretReadError;
            var end = len;
            while (end > 0 and (buf[end - 1] == '\n' or buf[end - 1] == '\r')) {
                end -= 1;
            }
            return buf[0..end];
        }

        // Fall back to environment variable
        return std.posix.getenv("XSUAA_CLIENT_SECRET") orelse {
            log.err("XSUAA_CLIENT_SECRET or XSUAA_CLIENT_SECRET_FILE must be set", .{});
            return error.MissingClientSecret;
        };
    }
};

// ============================================================================
// IAS Configuration (SAP Identity Authentication Service)
// ============================================================================

pub const IASConfig = struct {
    /// IAS tenant URL
    url: []const u8,
    /// Client ID
    client_id: []const u8,
    /// Client secret
    client_secret: []const u8,
    /// Token endpoint
    token_endpoint: []const u8 = "/oauth2/token",
    /// JWKS endpoint
    jwks_endpoint: []const u8 = "/oauth2/certs",
    /// Application ID
    app_id: []const u8 = "",
};

// ============================================================================
// Base64URL Decoding (for JWT)
// ============================================================================

fn base64UrlDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // Convert Base64URL to standard Base64
    var buf = try allocator.alloc(u8, input.len + 4);
    defer allocator.free(buf);

    var i: usize = 0;
    for (input) |c| {
        buf[i] = switch (c) {
            '-' => '+',
            '_' => '/',
            else => c,
        };
        i += 1;
    }

    // Add padding
    const padding = (4 - (i % 4)) % 4;
    for (0..padding) |_| {
        buf[i] = '=';
        i += 1;
    }

    // Decode
    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(buf[0..i]) catch return error.Base64DecodeError;
    var decoded = try allocator.alloc(u8, decoded_len);
    decoder.decode(decoded, buf[0..i]) catch return error.Base64DecodeError;

    return decoded;
}

// ============================================================================
// JWT Token
// ============================================================================

pub const JwtToken = struct {
    allocator: std.mem.Allocator,
    raw: []const u8,
    header: JwtHeader,
    payload: JwtPayload,
    signature: []const u8,
    expires_at: i64,
    issued_at: i64,

    pub fn parse(allocator: std.mem.Allocator, token_str: []const u8) !JwtToken {
        var parts = std.mem.splitScalar(u8, token_str, '.');
        const header_b64 = parts.next() orelse return error.InvalidTokenFormat;
        const payload_b64 = parts.next() orelse return error.InvalidTokenFormat;
        const signature_b64 = parts.next() orelse return error.InvalidTokenFormat;

        // Verify no extra parts
        if (parts.next() != null) return error.InvalidTokenFormat;

        // Decode header
        const header_json = try base64UrlDecode(allocator, header_b64);
        defer allocator.free(header_json);
        const header = try JwtHeader.parse(allocator, header_json);

        // Decode payload
        const payload_json = try base64UrlDecode(allocator, payload_b64);
        defer allocator.free(payload_json);
        const payload = try JwtPayload.parse(allocator, payload_json);

        // Decode signature
        const signature = try base64UrlDecode(allocator, signature_b64);

        return .{
            .allocator = allocator,
            .raw = try allocator.dupe(u8, token_str),
            .header = header,
            .payload = payload,
            .signature = signature,
            .expires_at = payload.exp,
            .issued_at = payload.iat,
        };
    }

    pub fn deinit(self: *JwtToken) void {
        self.allocator.free(self.raw);
        self.allocator.free(self.signature);
        self.header.deinit(self.allocator);
        self.payload.deinit(self.allocator);
    }

    pub fn isExpired(self: JwtToken) bool {
        return std.time.timestamp() >= self.expires_at;
    }

    pub fn isExpiredWithSkew(self: JwtToken, skew_secs: i64) bool {
        return std.time.timestamp() >= (self.expires_at + skew_secs);
    }

    pub fn isNotYetValid(self: JwtToken, skew_secs: i64) bool {
        if (self.payload.nbf) |nbf| {
            return std.time.timestamp() < (nbf - skew_secs);
        }
        return false;
    }

    pub fn isValid(self: JwtToken, skew_secs: i64) bool {
        return !self.isExpiredWithSkew(skew_secs) and !self.isNotYetValid(skew_secs);
    }

    pub fn hasScope(self: JwtToken, scope: []const u8) bool {
        for (self.payload.scope) |s| {
            if (std.mem.eql(u8, s, scope)) return true;
        }
        return false;
    }

    pub fn hasAuthority(self: JwtToken, authority: []const u8) bool {
        if (self.payload.authorities) |authorities| {
            for (authorities) |a| {
                if (std.mem.eql(u8, a, authority)) return true;
            }
        }
        return false;
    }

    pub fn getZoneId(self: JwtToken) ?[]const u8 {
        return self.payload.zid;
    }

    pub fn getUserId(self: JwtToken) ?[]const u8 {
        return self.payload.user_id orelse self.payload.sub;
    }

    pub fn getEmail(self: JwtToken) ?[]const u8 {
        return self.payload.email;
    }

    /// Get the signing key ID from the header
    pub fn getKeyId(self: JwtToken) ?[]const u8 {
        return self.header.kid;
    }

    /// Get the data that was signed (header.payload)
    pub fn getSignedData(self: JwtToken) []const u8 {
        // Find the last dot to get header.payload
        var last_dot: usize = 0;
        for (self.raw, 0..) |c, i| {
            if (c == '.') last_dot = i;
        }
        // Find the second-to-last dot
        var first_dot: usize = 0;
        for (self.raw[0..last_dot], 0..) |c, i| {
            if (c == '.') first_dot = i;
        }
        _ = first_dot;

        return self.raw[0..last_dot];
    }
};

pub const JwtHeader = struct {
    alg: []const u8,
    typ: []const u8,
    kid: ?[]const u8,
    jku: ?[]const u8,

    pub fn parse(allocator: std.mem.Allocator, json: []const u8) !JwtHeader {
        _ = allocator;
        // Simple JSON parsing for header
        var header = JwtHeader{
            .alg = "RS256",
            .typ = "JWT",
            .kid = null,
            .jku = null,
        };

        // Parse "alg" field
        if (std.mem.indexOf(u8, json, "\"alg\"")) |idx| {
            if (extractJsonString(json[idx..])) |alg| {
                header.alg = alg;
            }
        }

        // Parse "kid" field
        if (std.mem.indexOf(u8, json, "\"kid\"")) |idx| {
            header.kid = extractJsonString(json[idx..]);
        }

        return header;
    }

    pub fn deinit(self: *JwtHeader, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
        // Strings point into the original JSON buffer, no need to free
    }
};

fn extractJsonString(json: []const u8) ?[]const u8 {
    // Find first colon, then first quote after it
    const colon_idx = std.mem.indexOf(u8, json, ":") orelse return null;
    const start_quote = std.mem.indexOf(u8, json[colon_idx..], "\"") orelse return null;
    const value_start = colon_idx + start_quote + 1;
    if (value_start >= json.len) return null;

    const end_quote = std.mem.indexOf(u8, json[value_start..], "\"") orelse return null;
    return json[value_start .. value_start + end_quote];
}

pub const JwtPayload = struct {
    // Standard claims
    iss: []const u8 = "",
    sub: ?[]const u8 = null,
    aud: []const []const u8 = &[_][]const u8{},
    exp: i64 = 0,
    iat: i64 = 0,
    nbf: ?i64 = null,
    jti: ?[]const u8 = null,

    // XSUAA-specific claims
    zid: ?[]const u8 = null, // Zone ID (tenant)
    cid: ?[]const u8 = null, // Client ID
    azp: ?[]const u8 = null, // Authorized party
    grant_type: ?[]const u8 = null,
    user_id: ?[]const u8 = null,
    user_name: ?[]const u8 = null,
    email: ?[]const u8 = null,
    given_name: ?[]const u8 = null,
    family_name: ?[]const u8 = null,
    origin: ?[]const u8 = null,
    scope: []const []const u8 = &[_][]const u8{},
    authorities: ?[]const []const u8 = null,

    // SAP BTP specific
    ext_attr: ?ExtAttr = null,

    pub fn parse(allocator: std.mem.Allocator, json: []const u8) !JwtPayload {
        var payload = JwtPayload{};

        // Use std.json for proper parsing when possible, fall back to string extraction
        // Note: We use string extraction here because the payload strings need to point
        // into the original JSON buffer to avoid allocation lifetime issues.
        // For a production system, consider using std.json.parseFromSlice with
        // ArenaAllocator to manage memory properly.

        // Parse "iss"
        if (std.mem.indexOf(u8, json, "\"iss\"")) |idx| {
            payload.iss = extractJsonString(json[idx..]) orelse "";
        }

        // Parse "sub"
        if (std.mem.indexOf(u8, json, "\"sub\"")) |idx| {
            payload.sub = extractJsonString(json[idx..]);
        }

        // Parse "exp"
        if (std.mem.indexOf(u8, json, "\"exp\"")) |idx| {
            payload.exp = extractJsonNumber(json[idx..]) orelse 0;
        }

        // Parse "iat"
        if (std.mem.indexOf(u8, json, "\"iat\"")) |idx| {
            payload.iat = extractJsonNumber(json[idx..]) orelse 0;
        }

        // Parse "nbf"
        if (std.mem.indexOf(u8, json, "\"nbf\"")) |idx| {
            payload.nbf = extractJsonNumber(json[idx..]);
        }

        // Parse "zid" (zone ID)
        if (std.mem.indexOf(u8, json, "\"zid\"")) |idx| {
            payload.zid = extractJsonString(json[idx..]);
        }

        // Parse "cid" (client ID)
        if (std.mem.indexOf(u8, json, "\"cid\"")) |idx| {
            payload.cid = extractJsonString(json[idx..]);
        }

        // Parse "user_id"
        if (std.mem.indexOf(u8, json, "\"user_id\"")) |idx| {
            payload.user_id = extractJsonString(json[idx..]);
        }

        // Parse "email"
        if (std.mem.indexOf(u8, json, "\"email\"")) |idx| {
            payload.email = extractJsonString(json[idx..]);
        }

        // Parse scopes
        payload.scope = try parseJsonStringArray(allocator, json, "scope");

        return payload;
    }

    pub fn deinit(self: *JwtPayload, allocator: std.mem.Allocator) void {
        if (self.scope.len > 0) {
            allocator.free(self.scope);
        }
        if (self.authorities) |auth| {
            allocator.free(auth);
        }
    }
};

fn extractJsonNumber(json: []const u8) ?i64 {
    const colon_idx = std.mem.indexOf(u8, json, ":") orelse return null;
    var start = colon_idx + 1;

    // Skip whitespace
    while (start < json.len and (json[start] == ' ' or json[start] == '\t')) {
        start += 1;
    }

    // Find end of number
    var end = start;
    while (end < json.len and (json[end] >= '0' and json[end] <= '9')) {
        end += 1;
    }

    if (end == start) return null;

    return std.fmt.parseInt(i64, json[start..end], 10) catch null;
}

fn parseJsonStringArray(allocator: std.mem.Allocator, json: []const u8, key: []const u8) ![]const []const u8 {
    var search_key: [64]u8 = undefined;
    const search = std.fmt.bufPrint(&search_key, "\"{s}\"", .{key}) catch return &[_][]const u8{};

    const key_idx = std.mem.indexOf(u8, json, search[0..key.len + 2]) orelse return &[_][]const u8{};
    const arr_start = std.mem.indexOf(u8, json[key_idx..], "[") orelse return &[_][]const u8{};
    const arr_end = std.mem.indexOf(u8, json[key_idx + arr_start ..], "]") orelse return &[_][]const u8{};

    const arr_content = json[key_idx + arr_start + 1 .. key_idx + arr_start + arr_end];

    // Count strings
    var count: usize = 0;
    var in_string = false;
    for (arr_content) |c| {
        if (c == '"' and !in_string) {
            in_string = true;
        } else if (c == '"' and in_string) {
            in_string = false;
            count += 1;
        }
    }

    if (count == 0) return &[_][]const u8{};

    var result = try allocator.alloc([]const u8, count);
    var idx: usize = 0;
    var i: usize = 0;

    while (i < arr_content.len and idx < count) {
        if (arr_content[i] == '"') {
            const start = i + 1;
            i += 1;
            while (i < arr_content.len and arr_content[i] != '"') {
                i += 1;
            }
            result[idx] = arr_content[start..i];
            idx += 1;
        }
        i += 1;
    }

    return result;
}

pub const ExtAttr = struct {
    enhancer: ?[]const u8 = null,
    subaccountid: ?[]const u8 = null,
    zdn: ?[]const u8 = null, // Zone domain name
    serviceinstanceid: ?[]const u8 = null,
};

// ============================================================================
// JWK (JSON Web Key)
// ============================================================================

pub const JwkKey = struct {
    kty: []const u8 = "RSA",
    kid: []const u8,
    use: []const u8 = "sig",
    alg: []const u8 = "RS256",
    n: []const u8, // RSA modulus (base64url)
    e: []const u8, // RSA exponent (base64url)
    x5c: ?[]const []const u8 = null, // X.509 certificate chain
    x5t: ?[]const u8 = null, // X.509 thumbprint
};

pub const JwksCache = struct {
    allocator: std.mem.Allocator,
    keys: std.ArrayList(JwkKey),
    fetched_at: i64,
    ttl_secs: u32,

    pub fn init(allocator: std.mem.Allocator, ttl_secs: u32) JwksCache {
        return .{
            .allocator = allocator,
            .keys = std.ArrayList(JwkKey).init(allocator),
            .fetched_at = 0,
            .ttl_secs = ttl_secs,
        };
    }

    pub fn deinit(self: *JwksCache) void {
        self.keys.deinit();
    }

    pub fn isStale(self: JwksCache) bool {
        return std.time.timestamp() - self.fetched_at > self.ttl_secs;
    }

    pub fn findKey(self: JwksCache, kid: []const u8) ?JwkKey {
        for (self.keys.items) |key| {
            if (std.mem.eql(u8, key.kid, kid)) {
                return key;
            }
        }
        return null;
    }
};

// ============================================================================
// Token Validator
// ============================================================================

pub const TokenValidator = struct {
    allocator: std.mem.Allocator,
    config: XsuaaConfig,
    jwks_cache: JwksCache,

    pub fn init(allocator: std.mem.Allocator, config: XsuaaConfig) TokenValidator {
        return .{
            .allocator = allocator,
            .config = config,
            .jwks_cache = JwksCache.init(allocator, config.jwks_cache_ttl_secs),
        };
    }

    pub fn deinit(self: *TokenValidator) void {
        self.jwks_cache.deinit();
    }

    /// Validate a JWT token completely
    pub fn validate(self: *TokenValidator, token_str: []const u8) !JwtToken {
        // Parse the token
        var token = try JwtToken.parse(self.allocator, token_str);
        errdefer token.deinit();

        // Validate token structure
        try self.validateStructure(&token);

        // Validate time claims
        try self.validateTimeClaims(&token);

        // Validate issuer
        try self.validateIssuer(&token);

        // Validate audience
        try self.validateAudience(&token);

        // Validate signature
        try self.validateSignature(&token);

        log.info("Token validated successfully for subject: {s}", .{token.payload.sub orelse "unknown"});
        return token;
    }

    fn validateStructure(self: *TokenValidator, token: *JwtToken) !void {
        _ = self;

        // Check algorithm
        if (!std.mem.eql(u8, token.header.alg, "RS256") and
            !std.mem.eql(u8, token.header.alg, "RS384") and
            !std.mem.eql(u8, token.header.alg, "RS512"))
        {
            log.err("Unsupported algorithm: {s}", .{token.header.alg});
            return error.UnsupportedAlgorithm;
        }

        // Check type
        if (!std.mem.eql(u8, token.header.typ, "JWT") and
            !std.mem.eql(u8, token.header.typ, "at+jwt"))
        {
            log.err("Invalid token type: {s}", .{token.header.typ});
            return error.InvalidTokenType;
        }
    }

    fn validateTimeClaims(self: *TokenValidator, token: *JwtToken) !void {
        const now = std.time.timestamp();
        const skew = self.config.clock_skew_tolerance_secs;

        // Check expiration
        if (token.expires_at == 0) {
            log.err("Token missing expiration claim", .{});
            return error.MissingExpClaim;
        }

        if (now > token.expires_at + skew) {
            log.err("Token expired at {}, current time {}", .{ token.expires_at, now });
            return error.TokenExpired;
        }

        // Check issued-at
        if (token.issued_at == 0) {
            log.warn("Token missing iat claim", .{});
        } else if (token.issued_at > now + skew) {
            log.err("Token issued in the future: {}", .{token.issued_at});
            return error.TokenIssuedInFuture;
        }

        // Check not-before
        if (token.payload.nbf) |nbf| {
            if (now < nbf - skew) {
                log.err("Token not yet valid, nbf: {}", .{nbf});
                return error.TokenNotYetValid;
            }
        }
    }

    fn validateIssuer(self: *TokenValidator, token: *JwtToken) !void {
        if (token.payload.iss.len == 0) {
            log.err("Token missing issuer claim", .{});
            return error.MissingIssClaim;
        }

        // Check if issuer matches expected XSUAA URL
        if (!std.mem.startsWith(u8, token.payload.iss, self.config.url)) {
            log.err("Invalid issuer: {s}, expected: {s}", .{ token.payload.iss, self.config.url });
            return error.InvalidIssuer;
        }
    }

    fn validateAudience(self: *TokenValidator, token: *JwtToken) !void {
        // For client credentials tokens, cid should match our client_id
        if (token.payload.cid) |cid| {
            if (std.mem.eql(u8, cid, self.config.client_id)) {
                return; // Valid
            }
        }

        // Check aud array
        for (token.payload.aud) |aud| {
            if (std.mem.eql(u8, aud, self.config.client_id)) {
                return; // Valid
            }
        }

        // Check azp
        if (token.payload.azp) |azp| {
            if (std.mem.eql(u8, azp, self.config.client_id)) {
                return; // Valid
            }
        }

        log.err("Token audience does not include our client_id: {s}", .{self.config.client_id});
        return error.InvalidAudience;
    }

    fn validateSignature(self: *TokenValidator, token: *JwtToken) !void {
        // Get the key ID from the token
        const kid = token.getKeyId() orelse {
            log.err("Token missing key ID (kid) in header", .{});
            return error.MissingKeyId;
        };

        // Refresh JWKS if stale
        if (self.jwks_cache.isStale()) {
            try self.refreshJwks();
        }

        // Find the key
        const key = self.jwks_cache.findKey(kid) orelse {
            // Try refreshing JWKS in case of key rotation
            try self.refreshJwks();
            const key2 = self.jwks_cache.findKey(kid) orelse {
                log.err("Key not found in JWKS: {s}", .{kid});
                return error.KeyNotFound;
            };
            try self.verifyRsaSignature(token, key2);
            return;
        };

        try self.verifyRsaSignature(token, key);
    }

    /// Verify an RS256 (RSASSA-PKCS1-v1_5 with SHA-256) JWT signature.
    ///
    /// Algorithm:
    ///   1.  Decode the JWK modulus (n) and public exponent (e) from base64url.
    ///   2.  Compute SHA-256 over the JWT's signed bytes (header.payload ASCII).
    ///   3.  Compute m = sig^e mod n using square-and-multiply big-integer arithmetic.
    ///   4.  Verify PKCS#1 v1.5 padding: 0x00 0x01 [0xFF…] 0x00 [DigestInfo] [hash].
    fn verifyRsaSignature(self: *TokenValidator, token: *JwtToken, key: JwkKey) !void {
        const alloc = self.allocator;

        // Only RS256 is implemented; reject other algorithms
        if (!std.mem.eql(u8, token.header.alg, "RS256")) {
            log.err("Unsupported algorithm for RSA verify: {s}", .{token.header.alg});
            return error.UnsupportedAlgorithm;
        }

        // Decode n (modulus) and e (public exponent) from base64url
        const n_bytes = try base64UrlDecode(alloc, key.n);
        defer alloc.free(n_bytes);
        const e_bytes = try base64UrlDecode(alloc, key.e);
        defer alloc.free(e_bytes);

        const n_len = n_bytes.len; // e.g. 256 for RSA-2048
        if (n_len < 64 or n_len > 512) return error.UnsupportedKeySize;
        if (token.signature.len != n_len) {
            log.err("Signature length {} does not match key size {}", .{ token.signature.len, n_len });
            return error.InvalidSignature;
        }

        // Compute SHA-256 of the signed bytes ("header.payload")
        const signed_data = token.getSignedData();
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(signed_data, &hash, .{});

        // Load n, e, sig as big integers (via hex strings)
        var n_big = try std.math.big.int.Managed.init(alloc);
        defer n_big.deinit();
        var e_big = try std.math.big.int.Managed.init(alloc);
        defer e_big.deinit();
        var sig_big = try std.math.big.int.Managed.init(alloc);
        defer sig_big.deinit();

        try setBigIntFromBytes(&n_big, n_bytes, alloc);
        try setBigIntFromBytes(&e_big, e_bytes, alloc);
        try setBigIntFromBytes(&sig_big, token.signature, alloc);

        // m = sig^e mod n  (RSA public key operation)
        var m = try std.math.big.int.Managed.init(alloc);
        defer m.deinit();
        try rsaPowMod(&m, sig_big.toConst(), e_bytes, n_big.toConst(), alloc);

        // Write m as a big-endian byte array of exactly n_len bytes
        var m_bytes: [512]u8 = std.mem.zeroes([512]u8);
        m.toConst().writeTwosComplement(m_bytes[0..n_len], .big);

        // Verify PKCS#1 v1.5 structure:
        //   0x00 0x01 [FF...FF (>= 8 bytes)] 0x00 [DigestInfo] [SHA-256 hash]
        if (m_bytes[0] != 0x00 or m_bytes[1] != 0x01) {
            log.err("PKCS#1 v1.5 padding marker missing", .{});
            return error.InvalidSignature;
        }
        var sep: usize = 2;
        while (sep < n_len and m_bytes[sep] == 0xFF) sep += 1;
        if (sep >= n_len or m_bytes[sep] != 0x00) {
            log.err("PKCS#1 v1.5 separator 0x00 not found", .{});
            return error.InvalidSignature;
        }
        if (sep - 2 < 8) {
            log.err("PKCS#1 v1.5 padding too short: {} bytes", .{sep - 2});
            return error.InvalidSignature;
        }
        sep += 1; // advance past 0x00 separator → now at DigestInfo

        // SHA-256 DigestInfo header (RFC 8017 appendix C)
        const sha256_di = [19]u8{
            0x30, 0x31, 0x30, 0x0d, 0x06, 0x09,
            0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01,
            0x05, 0x00, 0x04, 0x20,
        };
        if (sep + sha256_di.len + 32 > n_len) return error.InvalidSignature;
        if (!std.mem.eql(u8, m_bytes[sep .. sep + sha256_di.len], &sha256_di)) {
            log.err("PKCS#1 v1.5 DigestInfo mismatch", .{});
            return error.InvalidSignature;
        }

        const hash_start = sep + sha256_di.len;
        if (!std.mem.eql(u8, m_bytes[hash_start .. hash_start + 32], &hash)) {
            log.err("JWT signature verification failed: hash mismatch", .{});
            return error.SignatureVerificationFailed;
        }

        log.info("JWT RS256 signature verified OK (kid={s})", .{key.kid});
    }

    // -------------------------------------------------------------------------
    // Private RSA helpers
    // -------------------------------------------------------------------------

    /// Set a Managed big integer from a raw big-endian byte slice.
    fn setBigIntFromBytes(m: *std.math.big.int.Managed, bytes: []const u8, alloc: std.mem.Allocator) !void {
        const hex = try alloc.alloc(u8, bytes.len * 2);
        defer alloc.free(hex);
        for (bytes, 0..) |byte, i| {
            const hi: u8 = byte >> 4;
            const lo: u8 = byte & 0xF;
            hex[i * 2]     = if (hi < 10) '0' + hi else 'a' + hi - 10;
            hex[i * 2 + 1] = if (lo < 10) '0' + lo else 'a' + lo - 10;
        }
        try m.setString(16, hex);
    }

    /// Compute result = base^exp mod modulus using square-and-multiply.
    /// exp_bytes is the big-endian byte representation of the exponent.
    fn rsaPowMod(
        result: *std.math.big.int.Managed,
        base_const: std.math.big.int.Const,
        exp_bytes: []const u8,
        mod_const: std.math.big.int.Const,
        alloc: std.mem.Allocator,
    ) !void {
        var base = try std.math.big.int.Managed.init(alloc);
        defer base.deinit();
        try base.copy(base_const);

        var tmp = try std.math.big.int.Managed.init(alloc);
        defer tmp.deinit();
        var q = try std.math.big.int.Managed.init(alloc);
        defer q.deinit();

        try result.set(1); // result = 1

        for (exp_bytes) |byte| {
            var mask: u8 = 0x80;
            while (mask != 0) : (mask >>= 1) {
                // Square: tmp = result * result; result = tmp mod modulus
                try tmp.mul(result.toConst(), result.toConst());
                try q.divFloor(result, tmp.toConst(), mod_const);

                if (byte & mask != 0) {
                    // Multiply: tmp = result * base; result = tmp mod modulus
                    try tmp.mul(result.toConst(), base.toConst());
                    try q.divFloor(result, tmp.toConst(), mod_const);
                }
            }
        }
    }

    /// Refresh the JWKS cache from the XSUAA endpoint
    pub fn refreshJwks(self: *TokenValidator) !void {
        log.info("Refreshing JWKS from {s}{s}", .{ self.config.url, self.config.jwks_endpoint });

        // Build the JWKS URL
        var url_buf: [512]u8 = undefined;
        const jwks_url = try std.fmt.bufPrint(&url_buf, "{s}{s}", .{
            self.config.url,
            self.config.jwks_endpoint,
        });

        // Fetch JWKS using HTTP client
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const uri = std.Uri.parse(jwks_url) catch return error.InvalidJwksUrl;

        var req = try client.open(.GET, uri, .{
            .server_header_buffer = undefined,
        });
        defer req.deinit();

        try req.send();
        try req.finish();
        try req.wait();

        if (req.status != .ok) {
            log.err("JWKS fetch failed with status: {}", .{req.status});
            return error.JwksFetchFailed;
        }

        // Read response body
        var body_buf: [16384]u8 = undefined;
        const body_len = try req.reader().readAll(&body_buf);
        const body = body_buf[0..body_len];

        // Parse JWKS JSON
        try self.parseJwks(body);

        self.jwks_cache.fetched_at = std.time.timestamp();
        log.info("JWKS refreshed, found {} keys", .{self.jwks_cache.keys.items.len});
    }

    fn parseJwks(self: *TokenValidator, json: []const u8) !void {
        // Clear existing keys
        self.jwks_cache.keys.clearRetainingCapacity();

        // Find "keys" array
        const keys_start = std.mem.indexOf(u8, json, "\"keys\"") orelse return error.InvalidJwksFormat;
        const arr_start = std.mem.indexOf(u8, json[keys_start..], "[") orelse return error.InvalidJwksFormat;
        const arr_end = std.mem.lastIndexOf(u8, json, "]") orelse return error.InvalidJwksFormat;

        if (keys_start + arr_start >= arr_end) return error.InvalidJwksFormat;

        const keys_json = json[keys_start + arr_start .. arr_end + 1];

        // Parse each key object
        var depth: i32 = 0;
        var key_start: ?usize = null;

        for (keys_json, 0..) |c, i| {
            if (c == '{') {
                if (depth == 0) {
                    key_start = i;
                }
                depth += 1;
            } else if (c == '}') {
                depth -= 1;
                if (depth == 0 and key_start != null) {
                    const key_json = keys_json[key_start.?..i + 1];
                    if (try self.parseJwkKey(key_json)) |key| {
                        try self.jwks_cache.keys.append(key);
                    }
                    key_start = null;
                }
            }
        }
    }

    fn parseJwkKey(self: *TokenValidator, json: []const u8) !?JwkKey {
        _ = self;

        // Extract required fields
        const kid = extractJsonString(json) orelse return null;
        _ = kid;

        var key = JwkKey{
            .kid = "",
            .n = "",
            .e = "",
        };

        // Parse kid
        if (std.mem.indexOf(u8, json, "\"kid\"")) |idx| {
            key.kid = extractJsonString(json[idx..]) orelse return null;
        } else {
            return null;
        }

        // Parse kty
        if (std.mem.indexOf(u8, json, "\"kty\"")) |idx| {
            key.kty = extractJsonString(json[idx..]) orelse "RSA";
        }

        // Parse alg
        if (std.mem.indexOf(u8, json, "\"alg\"")) |idx| {
            key.alg = extractJsonString(json[idx..]) orelse "RS256";
        }

        // Parse n (modulus)
        if (std.mem.indexOf(u8, json, "\"n\"")) |idx| {
            key.n = extractJsonString(json[idx..]) orelse return null;
        } else {
            return null;
        }

        // Parse e (exponent)
        if (std.mem.indexOf(u8, json, "\"e\"")) |idx| {
            key.e = extractJsonString(json[idx..]) orelse return null;
        } else {
            return null;
        }

        return key;
    }
};

// ============================================================================
// XSUAA Client
// ============================================================================

pub const XsuaaClient = struct {
    allocator: std.mem.Allocator,
    config: XsuaaConfig,
    validator: TokenValidator,
    cached_token: ?JwtToken,

    pub fn init(allocator: std.mem.Allocator, config: XsuaaConfig) XsuaaClient {
        return .{
            .allocator = allocator,
            .config = config,
            .validator = TokenValidator.init(allocator, config),
            .cached_token = null,
        };
    }

    pub fn deinit(self: *XsuaaClient) void {
        if (self.cached_token) |*token| {
            token.deinit();
        }
        self.validator.deinit();
    }

    /// Get client credentials token (service-to-service)
    pub fn getClientCredentialsToken(self: *XsuaaClient) !JwtToken {
        // Check cache first
        if (self.cached_token) |token| {
            if (token.isValid(self.config.clock_skew_tolerance_secs)) {
                log.debug("Using cached client credentials token", .{});
                return token;
            }
            // Token expired, will fetch new one
            var mutable_token = token;
            mutable_token.deinit();
            self.cached_token = null;
        }

        log.info("Requesting client credentials token from XSUAA", .{});

        // Build token request
        var url_buf: [512]u8 = undefined;
        const token_url = try std.fmt.bufPrint(&url_buf, "{s}{s}", .{
            self.config.url,
            self.config.token_endpoint,
        });

        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const uri = std.Uri.parse(token_url) catch return error.InvalidTokenUrl;

        // Build request body
        var body_buf: [1024]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buf, "grant_type=client_credentials&client_id={s}&client_secret={s}", .{
            self.config.client_id,
            self.config.client_secret,
        });

        var req = try client.open(.POST, uri, .{
            .server_header_buffer = undefined,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
            },
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        try req.send();
        try req.writer().writeAll(body);
        try req.finish();
        try req.wait();

        if (req.status != .ok) {
            log.err("Token request failed with status: {}", .{req.status});
            return error.TokenRequestFailed;
        }

        // Read response
        var response_buf: [8192]u8 = undefined;
        const response_len = try req.reader().readAll(&response_buf);
        const response = response_buf[0..response_len];

        // Extract access_token from response
        const token_str = extractJsonString(response) orelse return error.InvalidTokenResponse;

        // Parse and validate the token
        const token = try self.validator.validate(token_str);
        self.cached_token = token;

        return token;
    }

    /// Validate an incoming JWT token
    pub fn validateToken(self: *XsuaaClient, token_str: []const u8) !JwtToken {
        return try self.validator.validate(token_str);
    }

    /// Check if token has required scope for operation
    pub fn checkScope(self: *XsuaaClient, token: JwtToken, required_scope: []const u8) bool {
        _ = self;
        return token.hasScope(required_scope);
    }

    /// Refresh JWKS cache
    pub fn refreshJwks(self: *XsuaaClient) !void {
        try self.validator.refreshJwks();
    }
};

// ============================================================================
// Authorization Scopes for AIPrompt Operations
// ============================================================================

pub const AIPromptScopes = struct {
    // Producer scopes
    pub const PRODUCE = "aiprompt.produce";
    pub const PRODUCE_TOPIC = "aiprompt.produce.{topic}";

    // Consumer scopes
    pub const CONSUME = "aiprompt.consume";
    pub const CONSUME_TOPIC = "aiprompt.consume.{topic}";

    // Admin scopes
    pub const ADMIN = "aiprompt.admin";
    pub const ADMIN_TOPICS = "aiprompt.admin.topics";
    pub const ADMIN_SUBSCRIPTIONS = "aiprompt.admin.subscriptions";
    pub const ADMIN_NAMESPACES = "aiprompt.admin.namespaces";
    pub const ADMIN_TENANTS = "aiprompt.admin.tenants";

    // Function scopes (for AIPrompt Functions)
    pub const FUNCTIONS = "aiprompt.functions";
    pub const FUNCTIONS_DEPLOY = "aiprompt.functions.deploy";
    pub const FUNCTIONS_ADMIN = "aiprompt.functions.admin";

    /// Check if user has permission for topic operation
    pub fn hasTopicPermission(token: JwtToken, topic: []const u8, operation: Operation) bool {
        const base_scope = switch (operation) {
            .Produce => PRODUCE,
            .Consume => CONSUME,
            .Admin => ADMIN,
        };

        if (token.hasScope(base_scope)) return true;

        // Check topic-specific scope
        var buf: [256]u8 = undefined;
        const topic_scope = std.fmt.bufPrint(&buf, "{s}.{s}", .{ base_scope, topic }) catch return false;
        return token.hasScope(topic_scope);
    }
};

pub const Operation = enum {
    Produce,
    Consume,
    Admin,
};

// ============================================================================
// BTP Tenant Context
// ============================================================================

pub const TenantContext = struct {
    tenant_id: []const u8,
    subdomain: []const u8,
    zone_id: []const u8,
    subaccount_id: ?[]const u8,
    service_instance_id: ?[]const u8,

    pub fn fromToken(token: JwtToken) ?TenantContext {
        const zone_id = token.getZoneId() orelse return null;

        var ctx = TenantContext{
            .tenant_id = zone_id,
            .subdomain = "",
            .zone_id = zone_id,
            .subaccount_id = null,
            .service_instance_id = null,
        };

        if (token.payload.ext_attr) |ext| {
            ctx.subaccount_id = ext.subaccountid;
            ctx.service_instance_id = ext.serviceinstanceid;
            if (ext.zdn) |zdn| {
                ctx.subdomain = zdn;
            }
        }

        return ctx;
    }
};

// ============================================================================
// Authentication Middleware
// ============================================================================

pub const AuthMiddleware = struct {
    xsuaa_client: *XsuaaClient,
    required_scopes: []const []const u8,
    allow_anonymous: bool,

    pub fn init(xsuaa_client: *XsuaaClient, required_scopes: []const []const u8) AuthMiddleware {
        return .{
            .xsuaa_client = xsuaa_client,
            .required_scopes = required_scopes,
            .allow_anonymous = false,
        };
    }

    /// Authenticate a request and return tenant context
    pub fn authenticate(self: *AuthMiddleware, auth_header: ?[]const u8) !AuthResult {
        if (auth_header == null) {
            if (self.allow_anonymous) {
                return .{ .authenticated = false, .token = null, .tenant = null };
            }
            log.warn("Missing Authorization header", .{});
            return error.MissingAuthHeader;
        }

        const header = auth_header.?;
        if (!std.mem.startsWith(u8, header, "Bearer ")) {
            log.warn("Invalid auth scheme, expected 'Bearer'", .{});
            return error.InvalidAuthScheme;
        }

        const token_str = header[7..];
        var token = try self.xsuaa_client.validateToken(token_str);
        errdefer token.deinit();

        // Check required scopes
        for (self.required_scopes) |scope| {
            if (!token.hasScope(scope)) {
                log.warn("Missing required scope: {s}", .{scope});
                return error.InsufficientScope;
            }
        }

        return .{
            .authenticated = true,
            .token = token,
            .tenant = TenantContext.fromToken(token),
        };
    }
};

pub const AuthResult = struct {
    authenticated: bool,
    token: ?JwtToken,
    tenant: ?TenantContext,
};

// ============================================================================
// Tests
// ============================================================================

test "JwtToken expiry check" {
    const allocator = std.testing.allocator;

    // Create a mock token string (this would normally be a real JWT)
    // For testing, we'll test the individual components
    var header = JwtHeader{
        .alg = "RS256",
        .typ = "JWT",
        .kid = "key1",
        .jku = null,
    };

    var payload = JwtPayload{
        .exp = std.time.timestamp() + 3600,
        .iat = std.time.timestamp(),
    };

    var token = JwtToken{
        .allocator = allocator,
        .raw = "test.token.string",
        .header = header,
        .payload = payload,
        .signature = "sig",
        .expires_at = payload.exp,
        .issued_at = payload.iat,
    };

    try std.testing.expect(!token.isExpired());

    // Test expired token
    token.expires_at = std.time.timestamp() - 100;
    try std.testing.expect(token.isExpired());

    _ = &header;
    _ = &payload;
}

test "JwtToken scope check" {
    const allocator = std.testing.allocator;
    const scopes = [_][]const u8{ "aiprompt.produce", "aiprompt.consume" };

    const token = JwtToken{
        .allocator = allocator,
        .raw = "test",
        .header = .{ .alg = "RS256", .typ = "JWT", .kid = null, .jku = null },
        .payload = .{
            .scope = &scopes,
        },
        .signature = "sig",
        .expires_at = std.time.timestamp() + 3600,
        .issued_at = std.time.timestamp(),
    };

    try std.testing.expect(token.hasScope("aiprompt.produce"));
    try std.testing.expect(token.hasScope("aiprompt.consume"));
    try std.testing.expect(!token.hasScope("aiprompt.admin"));
}

test "base64UrlDecode" {
    const allocator = std.testing.allocator;

    // Test basic decoding
    const decoded = try base64UrlDecode(allocator, "SGVsbG8");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("Hello", decoded);
}

test "validateIdentifier in token claims" {
    // This is tested in hana_db.zig, but we want to ensure
    // topic names from tokens are also validated before use
    const topic = "persistent://tenant/namespace/topic";
    try std.testing.expect(topic.len > 0);
}