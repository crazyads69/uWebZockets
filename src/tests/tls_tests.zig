const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const support = @import("test_support");
const test_options = @import("test_options");
const xev = @import("xev");

const tls = support.tls;
const http2 = support.http2;
const net = std.Io.net;

test "tls: client-auth modes disable early data" {
    try std.testing.expect(tls.early_data_enabled(.none));
    try std.testing.expect(!tls.early_data_enabled(.optional));
    try std.testing.expect(!tls.early_data_enabled(.required));
}

test "crypto: hmac verification uses the full digest" {
    const mac = support.crypto_subtle.sign_hmac_sha256("key", "message");
    try std.testing.expect(support.crypto_subtle.verify_hmac_sha256("key", "message", &mac));

    var tampered = mac;
    tampered[0] ^= 1;
    try std.testing.expect(!support.crypto_subtle.verify_hmac_sha256("key", "message", &tampered));
}

test "crypto: aes-gcm checks output size before sealing" {
    const key = [_]u8{0x11} ** 16;
    const nonce = [_]u8{0x22} ** support.crypto_subtle.aes_gcm_nonce_length;

    var short_output: [8]u8 = undefined;
    try std.testing.expectError(
        error.BufferTooSmall,
        support.crypto_subtle.encrypt_aes_gcm(&key, &nonce, "plaintext", "", &short_output),
    );

    var short_plaintext: [4]u8 = undefined;
    const ciphertext = [_]u8{0} ** (support.crypto_subtle.aes_gcm_tag_length + 8);
    try std.testing.expectError(
        error.BufferTooSmall,
        support.crypto_subtle.decrypt_aes_gcm(&key, &nonce, &ciphertext, "", &short_plaintext),
    );
}

/// One SSL endpoint plus the memory BIOs that carry its handshake records.
/// The SSL owns the BIOs after `SSL_set_bio`; this struct holds aliases.
const MemorySsl = struct {
    ssl: *c.SSL,
    incoming: *c.BIO,
    outgoing: *c.BIO,
};

test "ephemeral tls context initializes and releases" {
    var context = try tls.TlsContext.init_ephemeral(.{});
    defer context.deinit();

    try std.testing.expectEqual(@as(c_int, 1), c.SSL_CTX_check_private_key(context.ctx));
}

test "ephemeral http3 context initializes and releases" {
    var context = try tls.TlsContext.init_http3_ephemeral(.{});
    defer context.deinit();

    try std.testing.expectEqual(@as(c_int, 1), c.SSL_CTX_check_private_key(context.ctx));
}

test "ephemeral certificate completes an in-memory handshake" {
    var server_context = try tls.TlsContext.init_ephemeral(.{});
    defer server_context.deinit();

    const client_context = c.SSL_CTX_new(c.TLS_method()) orelse return error.ClientContextCreationFailed;
    defer c.SSL_CTX_free(client_context);
    // The generated certificate is self-signed, so there is no chain to trust;
    // the assertions below check the certificate content directly.
    c.SSL_CTX_set_verify(client_context, c.SSL_VERIFY_NONE, null);

    const server = try create_memory_ssl(server_context.ctx);
    defer c.SSL_free(server.ssl);
    c.SSL_set_accept_state(server.ssl);

    const client = try create_memory_ssl(client_context);
    defer c.SSL_free(client.ssl);
    c.SSL_set_connect_state(client.ssl);
    if (c.SSL_set_alpn_protos(client.ssl, "\x02h2", 3) != 0) {
        return error.ClientAlpnConfigurationFailed;
    }

    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        try drive_handshake(server.ssl, server.outgoing, client.incoming);
        try drive_handshake(client.ssl, client.outgoing, server.incoming);
        if (c.SSL_is_init_finished(server.ssl) == 1 and c.SSL_is_init_finished(client.ssl) == 1) break;
    }

    try std.testing.expectEqual(@as(c_int, 1), c.SSL_is_init_finished(server.ssl));
    try std.testing.expectEqual(@as(c_int, 1), c.SSL_is_init_finished(client.ssl));
    try std.testing.expectEqual(tls.ApplicationProtocol.http2, tls.negotiated_protocol(server.ssl));

    const certificate = c.SSL_get_peer_certificate(client.ssl) orelse {
        return error.MissingPeerCertificate;
    };
    defer c.X509_free(certificate);

    try std.testing.expect(c.X509_get0_notBefore(certificate) != null);
    try std.testing.expect(c.X509_get0_notAfter(certificate) != null);
    try expect_host_match(certificate, "localhost", 1);
    try expect_host_match(certificate, "example.test", 0);
    try expect_ip_match(certificate, "127.0.0.1", 1);
    try expect_ip_match(certificate, "::1", 1);
}

test "ephemeral certificate embeds caller names" {
    var context = try tls.TlsContext.init_ephemeral(.{
        .common_name = "api.example.test",
        .dns_names = &.{ "api.example.test", "localhost" },
        .ip_addresses = &.{"10.0.0.1"},
    });
    defer context.deinit();

    const certificate = c.SSL_CTX_get0_certificate(context.ctx) orelse {
        return error.MissingCertificate;
    };
    try expect_host_match(certificate, "api.example.test", 1);
    try expect_host_match(certificate, "localhost", 1);
    try expect_host_match(certificate, "other.example.test", 0);
    try expect_ip_match(certificate, "10.0.0.1", 1);
    try expect_ip_match(certificate, "127.0.0.1", 0);
}

test "required client authentication completes with a certificate from the configured ca" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try make_test_paths(std.testing.allocator, tmp.sub_path[0..]);
    defer paths.deinit(std.testing.allocator);

    const authority = try create_test_authority("mtls test ca", 1);
    defer free_test_authority(authority);
    const server_credential = try create_test_leaf_credential(authority, "server.test", 2, .server);
    defer free_test_credential(server_credential);
    const client_credential = try create_test_leaf_credential(authority, "client.test", 3, .client);
    defer free_test_credential(client_credential);
    try write_server_credentials(tmp.dir, authority.certificate, server_credential);

    var server_context = try tls.TlsContext.init_mtls(paths.server_certificate, paths.server_key, .{
        .mode = .required,
        .ca_path = paths.ca,
    });
    defer server_context.deinit();
    const client_context = try new_client_context(client_credential);
    defer c.SSL_CTX_free(client_context);

    const pair = try create_memory_pair(server_context.ctx, client_context);
    defer free_memory_pair(pair);

    const outcome = try drive_handshake_pair(pair);
    try std.testing.expectEqual(HandshakeOutcome.complete, outcome.server);
    try std.testing.expectEqual(HandshakeOutcome.complete, outcome.client);
    try std.testing.expectEqual(@as(c_long, c.X509_V_OK), c.SSL_get_verify_result(pair.server.ssl));
}

test "required client authentication rejects an anonymous client" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try make_test_paths(std.testing.allocator, tmp.sub_path[0..]);
    defer paths.deinit(std.testing.allocator);

    const authority = try create_test_authority("anonymous test ca", 10);
    defer free_test_authority(authority);
    const server_credential = try create_test_leaf_credential(authority, "server.test", 11, .server);
    defer free_test_credential(server_credential);
    try write_server_credentials(tmp.dir, authority.certificate, server_credential);

    var server_context = try tls.TlsContext.init_mtls(paths.server_certificate, paths.server_key, .{
        .mode = .required,
        .ca_path = paths.ca,
    });
    defer server_context.deinit();
    const client_context = try new_client_context(null);
    defer c.SSL_CTX_free(client_context);

    const pair = try create_memory_pair(server_context.ctx, client_context);
    defer free_memory_pair(pair);

    const outcome = try drive_handshake_pair(pair);
    try std.testing.expectEqual(HandshakeOutcome.failed, outcome.server);
    try std.testing.expect(c.SSL_get_verify_result(pair.server.ssl) != @as(c_long, c.X509_V_OK));
}

test "optional client authentication completes without a client certificate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try make_test_paths(std.testing.allocator, tmp.sub_path[0..]);
    defer paths.deinit(std.testing.allocator);

    const authority = try create_test_authority("optional test ca", 20);
    defer free_test_authority(authority);
    const server_credential = try create_test_leaf_credential(authority, "server.test", 21, .server);
    defer free_test_credential(server_credential);
    try write_server_credentials(tmp.dir, authority.certificate, server_credential);

    var server_context = try tls.TlsContext.init_mtls(paths.server_certificate, paths.server_key, .{
        .mode = .optional,
        .ca_path = paths.ca,
    });
    defer server_context.deinit();
    const client_context = try new_client_context(null);
    defer c.SSL_CTX_free(client_context);

    const pair = try create_memory_pair(server_context.ctx, client_context);
    defer free_memory_pair(pair);

    const outcome = try drive_handshake_pair(pair);
    try std.testing.expectEqual(HandshakeOutcome.complete, outcome.server);
    try std.testing.expectEqual(HandshakeOutcome.complete, outcome.client);
}

test "required client authentication rejects a certificate from another ca" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try make_test_paths(std.testing.allocator, tmp.sub_path[0..]);
    defer paths.deinit(std.testing.allocator);

    const authority = try create_test_authority("trusted test ca", 30);
    defer free_test_authority(authority);
    const unrelated_authority = try create_test_authority("unrelated test ca", 40);
    defer free_test_authority(unrelated_authority);
    const server_credential = try create_test_leaf_credential(authority, "server.test", 31, .server);
    defer free_test_credential(server_credential);
    const client_credential = try create_test_leaf_credential(unrelated_authority, "client.test", 41, .client);
    defer free_test_credential(client_credential);
    try write_server_credentials(tmp.dir, authority.certificate, server_credential);

    var server_context = try tls.TlsContext.init_mtls(paths.server_certificate, paths.server_key, .{
        .mode = .required,
        .ca_path = paths.ca,
    });
    defer server_context.deinit();
    const client_context = try new_client_context(client_credential);
    defer c.SSL_CTX_free(client_context);

    const pair = try create_memory_pair(server_context.ctx, client_context);
    defer free_memory_pair(pair);

    const outcome = try drive_handshake_pair(pair);
    try std.testing.expectEqual(HandshakeOutcome.failed, outcome.server);
}

test "none mode ignores the trust store path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try make_test_paths(std.testing.allocator, tmp.sub_path[0..]);
    defer paths.deinit(std.testing.allocator);

    const authority = try create_test_authority("none mode test ca", 50);
    defer free_test_authority(authority);
    const server_credential = try create_test_leaf_credential(authority, "server.test", 51, .server);
    defer free_test_credential(server_credential);
    try write_server_credentials(tmp.dir, authority.certificate, server_credential);

    var context = try tls.TlsContext.init_mtls(paths.server_certificate, paths.server_key, .{
        .mode = .none,
    });
    defer context.deinit();

    try std.testing.expectEqual(@as(c_int, 1), c.SSL_CTX_check_private_key(context.ctx));
}

test "client auth configuration errors fail before a context is returned" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try make_test_paths(std.testing.allocator, tmp.sub_path[0..]);
    defer paths.deinit(std.testing.allocator);

    const authority = try create_test_authority("misconfigured test ca", 60);
    defer free_test_authority(authority);
    const server_credential = try create_test_leaf_credential(authority, "server.test", 61, .server);
    defer free_test_credential(server_credential);
    try write_server_credentials(tmp.dir, authority.certificate, server_credential);

    try std.testing.expectError(error.InvalidClientAuthConfig, tls.TlsContext.init_mtls(
        paths.server_certificate,
        paths.server_key,
        .{ .mode = .required },
    ));
    const missing_ca: [:0]const u8 = "/nonexistent-uwebzockets-mtls-ca.pem";
    try std.testing.expectError(error.TrustStoreLoadFailed, tls.TlsContext.init_mtls(
        paths.server_certificate,
        paths.server_key,
        .{ .mode = .optional, .ca_path = missing_ca },
    ));
}

fn expect_host_match(certificate: *c.X509, name: [*:0]const u8, expected: c_int) !void {
    try std.testing.expectEqual(
        expected,
        c.X509_check_host(
            certificate,
            name,
            std.mem.len(name),
            c.X509_CHECK_FLAG_NEVER_CHECK_SUBJECT,
            null,
        ),
    );
}

fn expect_ip_match(certificate: *c.X509, address: [*:0]const u8, expected: c_int) !void {
    try std.testing.expectEqual(
        expected,
        c.X509_check_ip_asc(certificate, address, 0),
    );
}

fn create_memory_ssl(ctx: *c.SSL_CTX) !MemorySsl {
    const ssl = c.SSL_new(ctx) orelse return error.SslCreationFailed;
    errdefer c.SSL_free(ssl);

    const incoming = c.BIO_new(c.BIO_s_mem()) orelse return error.BioCreationFailed;
    errdefer _ = c.BIO_free(incoming);

    const outgoing = c.BIO_new(c.BIO_s_mem()) orelse return error.BioCreationFailed;
    errdefer _ = c.BIO_free(outgoing);

    c.SSL_set_bio(ssl, incoming, outgoing);
    return .{ .ssl = ssl, .incoming = incoming, .outgoing = outgoing };
}

/// Both endpoints of one memory-BIO handshake.
const MemoryPair = struct {
    server: MemorySsl,
    client: MemorySsl,
};

/// Creates accepting and connecting endpoints with the given contexts.
fn create_memory_pair(server_ctx: *c.SSL_CTX, client_ctx: *c.SSL_CTX) !MemoryPair {
    const server = try create_memory_ssl(server_ctx);
    errdefer c.SSL_free(server.ssl);
    c.SSL_set_accept_state(server.ssl);

    const client = try create_memory_ssl(client_ctx);
    errdefer c.SSL_free(client.ssl);
    c.SSL_set_connect_state(client.ssl);
    return .{ .server = server, .client = client };
}

/// Releases both endpoints; each SSL owns its BIOs after `SSL_set_bio`.
fn free_memory_pair(pair: MemoryPair) void {
    c.SSL_free(pair.server.ssl);
    c.SSL_free(pair.client.ssl);
}

/// Terminal state of one handshake step.
const HandshakeOutcome = enum {
    /// The endpoint needs more records before it can finish.
    pending,
    /// The handshake finished (`SSL_is_init_finished`).
    complete,
    /// `SSL_do_handshake` reported a fatal error.
    failed,
};

/// Terminal states observed from both ends of one handshake.
const HandshakePairOutcome = struct {
    server: HandshakeOutcome,
    client: HandshakeOutcome,
};

fn drive_handshake(ssl: *c.SSL, outgoing: *c.BIO, incoming: *c.BIO) !void {
    if (try drive_handshake_step(ssl, outgoing, incoming) == .failed) {
        return error.HandshakeFailed;
    }
}

/// Drives one endpoint once and reports its terminal state.
fn drive_handshake_step(ssl: *c.SSL, outgoing: *c.BIO, incoming: *c.BIO) !HandshakeOutcome {
    const result = c.SSL_do_handshake(ssl);
    const outcome: HandshakeOutcome = switch (c.SSL_get_error(ssl, result)) {
        c.SSL_ERROR_NONE => if (c.SSL_is_init_finished(ssl) == 1) .complete else .pending,
        c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => .pending,
        else => .failed,
    };
    try transfer_pending_bytes(outgoing, incoming);
    return outcome;
}

/// Drives both endpoints until each reaches a terminal state. A failed or
/// finished endpoint is not driven again, and the round bound keeps a stalled
/// peer from spinning forever.
fn drive_handshake_pair(pair: MemoryPair) !HandshakePairOutcome {
    var outcome = HandshakePairOutcome{ .server = .pending, .client = .pending };
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        if (outcome.server != .pending and outcome.client != .pending) break;
        if (outcome.server == .pending) {
            // Server records flow to the client's incoming BIO, and the other
            // way around; each endpoint only ever writes to its own outgoing.
            outcome.server = try drive_handshake_step(
                pair.server.ssl,
                pair.server.outgoing,
                pair.client.incoming,
            );
        }
        if (outcome.client == .pending) {
            outcome.client = try drive_handshake_step(
                pair.client.ssl,
                pair.client.outgoing,
                pair.server.incoming,
            );
        }
    }
    return outcome;
}

fn transfer_pending_bytes(source: *c.BIO, destination: *c.BIO) !void {
    var buffer: [4096]u8 = undefined;
    while (c.BIO_ctrl_pending(source) > 0) {
        const read = c.BIO_read(source, &buffer, buffer.len);
        if (read <= 0) return error.HandshakeIoFailed;
        if (c.BIO_write(destination, &buffer, read) != read) return error.HandshakeIoFailed;
    }
}

/// One generated test key pair and its X.509 certificate.
const TestCredential = struct {
    key: *c.EVP_PKEY,
    certificate: *c.X509,
};

/// A generated test CA: signing key plus self-signed CA certificate.
const TestAuthority = struct {
    key: *c.EVP_PKEY,
    certificate: *c.X509,
};

/// Extended key usage installed on a generated test leaf certificate.
const TestLeafUsage = enum {
    /// `serverAuth`, for the certificate the test server presents.
    server,
    /// `clientAuth`, for the certificate the test client presents.
    client,
};

/// NUL-terminated filesystem paths for one test's credentials.
const TestPaths = struct {
    ca: [:0]u8,
    server_certificate: [:0]u8,
    server_key: [:0]u8,

    fn deinit(self: TestPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.ca);
        allocator.free(self.server_certificate);
        allocator.free(self.server_key);
    }
};

/// Builds absolute paths inside the tmpDir made by `std.testing.tmpDir`, which
/// creates its random directory at `.zig-cache/tmp/<sub_path>` relative to the
/// process working directory.
fn make_test_paths(allocator: std.mem.Allocator, sub_path: []const u8) !TestPaths {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);

    const ca = try std.fs.path.joinZ(allocator, &.{ cwd, ".zig-cache", "tmp", sub_path, "ca.pem" });
    errdefer allocator.free(ca);
    const server_certificate = try std.fs.path.joinZ(
        allocator,
        &.{ cwd, ".zig-cache", "tmp", sub_path, "server.pem" },
    );
    errdefer allocator.free(server_certificate);
    return .{
        .ca = ca,
        .server_certificate = server_certificate,
        .server_key = try std.fs.path.joinZ(
            allocator,
            &.{ cwd, ".zig-cache", "tmp", sub_path, "server-key.pem" },
        ),
    };
}

/// Writes the CA bundle and server certificate/key PEM files consumed by
/// `TlsContext.init_mtls`.
fn write_server_credentials(dir: std.Io.Dir, authority: *c.X509, credential: TestCredential) !void {
    try write_certificate_pem(dir, "ca.pem", authority);
    try write_certificate_pem(dir, "server.pem", credential.certificate);
    try write_private_key_pem(dir, "server-key.pem", credential.key);
}

/// Writes one certificate to `sub_path` in the temporary test directory.
fn write_certificate_pem(dir: std.Io.Dir, sub_path: []const u8, certificate: *c.X509) !void {
    const bio = c.BIO_new(c.BIO_s_mem()) orelse return error.PemSerializationFailed;
    defer _ = c.BIO_free(bio);
    if (c.PEM_write_bio_X509(bio, certificate) != 1) return error.PemSerializationFailed;
    try write_pem_bio(dir, sub_path, bio);
}

/// Writes one unencrypted PKCS#8 private key to `sub_path`.
fn write_private_key_pem(dir: std.Io.Dir, sub_path: []const u8, key: *c.EVP_PKEY) !void {
    const bio = c.BIO_new(c.BIO_s_mem()) orelse return error.PemSerializationFailed;
    defer _ = c.BIO_free(bio);
    if (c.PEM_write_bio_PrivateKey(bio, key, null, null, 0, null, null) != 1) {
        return error.PemSerializationFailed;
    }
    try write_pem_bio(dir, sub_path, bio);
}

/// Copies a memory BIO holding one PEM block to a file.
fn write_pem_bio(dir: std.Io.Dir, sub_path: []const u8, bio: *c.BIO) !void {
    var buffer: [8192]u8 = undefined;
    const available = c.BIO_ctrl_pending(bio);
    if (available == 0 or available > buffer.len) return error.PemSerializationFailed;

    const length = c.BIO_read(bio, &buffer, buffer.len);
    if (length <= 0 or @as(usize, @intCast(length)) != available) {
        return error.PemSerializationFailed;
    }
    try dir.writeFile(std.testing.io, .{
        .sub_path = sub_path,
        .data = buffer[0..@intCast(length)],
    });
}

/// Creates a TLS client context. `credential` is null for an anonymous client
/// that answers the server's certificate request with an empty list.
fn new_client_context(credential: ?TestCredential) !*c.SSL_CTX {
    const ctx = c.SSL_CTX_new(c.TLS_method()) orelse return error.ClientContextCreationFailed;
    errdefer c.SSL_CTX_free(ctx);

    // Server authenticity is not under test; client auth is one-directional.
    c.SSL_CTX_set_verify(ctx, c.SSL_VERIFY_NONE, null);
    if (credential) |value| {
        if (c.SSL_CTX_use_certificate(ctx, value.certificate) != 1) {
            return error.ClientCertificateInstallFailed;
        }
        if (c.SSL_CTX_use_PrivateKey(ctx, value.key) != 1) {
            return error.ClientPrivateKeyInstallFailed;
        }
    }
    return ctx;
}

/// Generates a P-256 key pair for one test credential.
fn generate_test_key() !*c.EVP_PKEY {
    const keygen = c.EVP_PKEY_CTX_new_id(c.EVP_PKEY_EC, null) orelse {
        return error.TestKeyGenerationFailed;
    };
    defer c.EVP_PKEY_CTX_free(keygen);

    if (c.EVP_PKEY_keygen_init(keygen) != 1) return error.TestKeyGenerationFailed;
    if (c.EVP_PKEY_CTX_set_ec_paramgen_curve_nid(keygen, c.NID_X9_62_prime256v1) != 1) {
        return error.TestKeyGenerationFailed;
    }

    var key: ?*c.EVP_PKEY = null;
    if (c.EVP_PKEY_keygen(keygen, &key) != 1) return error.TestKeyGenerationFailed;
    return key orelse error.TestKeyGenerationFailed;
}

/// Creates a self-signed P-256 CA certificate suitable for signing leaves.
fn create_test_authority(common_name: []const u8, serial: c_long) !TestAuthority {
    const key = try generate_test_key();
    errdefer c.EVP_PKEY_free(key);

    const certificate = try open_test_certificate(key, serial, common_name);
    errdefer c.X509_free(certificate);

    try add_test_extension(certificate, c.NID_basic_constraints, "critical,CA:TRUE");
    try add_test_extension(certificate, c.NID_key_usage, "critical,keyCertSign,cRLSign");

    const subject = c.X509_get_subject_name(certificate) orelse {
        return error.TestCertificateCreationFailed;
    };
    if (c.X509_set_issuer_name(certificate, subject) != 1) return error.TestCertificateCreationFailed;
    if (c.X509_sign(certificate, key, c.EVP_sha256()) == 0) return error.TestCertificateSigningFailed;
    return .{ .key = key, .certificate = certificate };
}

/// Creates a P-256 leaf certificate signed by `authority`.
fn create_test_leaf_credential(
    authority: TestAuthority,
    common_name: []const u8,
    serial: c_long,
    usage: TestLeafUsage,
) !TestCredential {
    const key = try generate_test_key();
    errdefer c.EVP_PKEY_free(key);

    const certificate = try open_test_certificate(key, serial, common_name);
    errdefer c.X509_free(certificate);

    try add_test_extension(certificate, c.NID_basic_constraints, "critical,CA:FALSE");
    try add_test_extension(certificate, c.NID_key_usage, "critical,digitalSignature");
    try add_test_extension(certificate, c.NID_ext_key_usage, switch (usage) {
        .server => "serverAuth",
        .client => "clientAuth",
    });

    const issuer = c.X509_get_subject_name(authority.certificate) orelse {
        return error.TestCertificateCreationFailed;
    };
    if (c.X509_set_issuer_name(certificate, issuer) != 1) return error.TestCertificateCreationFailed;
    if (c.X509_sign(certificate, authority.key, c.EVP_sha256()) == 0) {
        return error.TestCertificateSigningFailed;
    }
    return .{ .key = key, .certificate = certificate };
}

/// Allocates an X.509v3 certificate with serial, validity window, subject
/// common name, and public key; the caller adds the issuer and extensions.
fn open_test_certificate(key: *c.EVP_PKEY, serial: c_long, common_name: []const u8) !*c.X509 {
    const certificate = c.X509_new() orelse return error.TestCertificateCreationFailed;
    errdefer c.X509_free(certificate);

    // Version 2 is X.509v3, the minimum version that carries extensions.
    if (c.X509_set_version(certificate, 2) != 1) return error.TestCertificateCreationFailed;
    if (c.ASN1_INTEGER_set(c.X509_get_serialNumber(certificate), serial) != 1) {
        return error.TestCertificateCreationFailed;
    }
    // Backdate an hour for clock skew; expire after 90 days.
    if (c.X509_gmtime_adj(c.X509_getm_notBefore(certificate), -3600) == null) {
        return error.TestCertificateCreationFailed;
    }
    if (c.X509_gmtime_adj(c.X509_getm_notAfter(certificate), 90 * 24 * 3600) == null) {
        return error.TestCertificateCreationFailed;
    }

    const subject = c.X509_get_subject_name(certificate) orelse {
        return error.TestCertificateCreationFailed;
    };
    if (c.X509_NAME_add_entry_by_txt(
        subject,
        "CN",
        c.MBSTRING_UTF8,
        common_name.ptr,
        @intCast(common_name.len),
        -1,
        0,
    ) != 1) {
        return error.TestCertificateCreationFailed;
    }
    if (c.X509_set_pubkey(certificate, key) != 1) return error.TestCertificateCreationFailed;
    return certificate;
}

fn add_test_extension(certificate: *c.X509, nid: c_int, value: [*:0]const u8) !void {
    const extension = c.X509V3_EXT_nconf_nid(null, null, nid, value) orelse {
        return error.TestCertificateExtensionFailed;
    };
    defer c.X509_EXTENSION_free(extension);
    if (c.X509_add_ext(certificate, extension, -1) != 1) {
        return error.TestCertificateExtensionFailed;
    }
}

fn free_test_credential(credential: TestCredential) void {
    c.X509_free(credential.certificate);
    c.EVP_PKEY_free(credential.key);
}

fn free_test_authority(authority: TestAuthority) void {
    c.X509_free(authority.certificate);
    c.EVP_PKEY_free(authority.key);
}

/// Worker application type shared by the cluster TLS tests.
const ClusterTestApp = support.app.configured_app_with_timeout(2, 1024, 4096, 0);

/// Per-worker capacities used by every cluster TLS test.
const cluster_test_config = support.config.ServerConfig{
    .max_connections = 2,
    .max_ws_message_size = 1024,
    .write_queue_size = 4096,
    .idle_timeout_ms = 0,
    .max_body_size = 8192,
    .max_route_nodes = 8,
    .max_pattern_routes = 4,
    .max_middleware = 2,
};

/// Ciphertext capacity of each side of the test client's memory BIO pair.
const cluster_tls_bio_capacity = 16 * 1024;

fn cluster_ok_handler(_: *support.http_request.Request, response: *support.http_response.Response) void {
    response.end("200 OK", "cluster-ok") catch @panic("cluster test handler response failed");
}

fn configure_cluster_routes(worker: *ClusterTestApp, _: usize) !void {
    _ = try worker.get("/", cluster_ok_handler);
}

/// Builds a two-worker cluster with the shared test configuration.
fn init_test_cluster() !ClusterTestApp.cluster(2) {
    return ClusterTestApp.cluster(2).init_with_options(
        std.testing.allocator,
        std.testing.io,
        cluster_test_config,
        .{ .cpu_affinity = false },
    );
}

/// Runs one cluster's event loops on a foreign thread for integration tests.
const ClusterRunner = struct {
    group: *ClusterTestApp.cluster(2),
    failure: ?anyerror = null,

    fn run(self: *ClusterRunner) void {
        self.group.run() catch |err| {
            self.failure = err;
        };
    }
};

/// Returns the port one worker's listener is bound to.
fn worker_port(worker: *const ClusterTestApp) !u16 {
    if (builtin.os.tag == .windows) return error.WorkerPortUnsupported;
    const server = worker.server orelse return error.WorkerNotListening;
    var address: std.posix.sockaddr.in = undefined;
    var address_length: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    switch (std.posix.errno(std.posix.system.getsockname(
        xev.tcp_fd(server.listener),
        @ptrCast(&address),
        &address_length,
    ))) {
        .SUCCESS => {},
        else => return error.ListenerAddressUnavailable,
    }
    return std.mem.bigToNative(u16, address.port);
}

/// Reserves one loopback port, then closes the listener so the cluster can
/// bind it with SO_REUSEPORT.
fn reserve_loopback_port() !u16 {
    var address = try net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    return server.socket.address.getPort();
}

/// Runs one CA-verified HTTP/1.1 exchange against a cluster worker port.
fn expect_https_ok(port: u16, ca_path: [:0]const u8) !void {
    const io = std.testing.io;
    var address = try net.IpAddress.parse("127.0.0.1", port);
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    try set_cluster_client_timeout(stream.socket.handle);

    const client_context = c.SSL_CTX_new(c.TLS_method()) orelse {
        return error.ClientContextCreationFailed;
    };
    defer c.SSL_CTX_free(client_context);
    if (c.SSL_CTX_set_min_proto_version(client_context, c.TLS1_3_VERSION) != 1) {
        return error.ClientContextCreationFailed;
    }
    if (c.SSL_CTX_set_max_proto_version(client_context, c.TLS1_3_VERSION) != 1) {
        return error.ClientContextCreationFailed;
    }
    if (c.SSL_CTX_load_verify_locations(client_context, ca_path.ptr, null) != 1) {
        return error.TrustStoreLoadFailed;
    }
    c.SSL_CTX_set_verify(client_context, c.SSL_VERIFY_PEER, null);

    const ssl = c.SSL_new(client_context) orelse return error.SslCreationFailed;
    defer c.SSL_free(ssl);
    const network_bio = try attach_client_bio(ssl);
    defer _ = c.BIO_free(network_bio);
    c.SSL_set_connect_state(ssl);

    const server_name: [:0]const u8 = "localhost";
    if (c.SSL_set_tlsext_host_name(ssl, server_name.ptr) != 1) {
        return error.SniConfigurationFailed;
    }
    // The production client checks only the DNS SAN, not the deprecated CN.
    c.SSL_set_hostflags(ssl, c.X509_CHECK_FLAG_NEVER_CHECK_SUBJECT);
    if (c.SSL_set1_host(ssl, server_name.ptr) != 1) return error.HostnameVerificationFailed;
    if (c.SSL_set_alpn_protos(ssl, "\x08http/1.1", 9) != 0) {
        return error.ClientAlpnConfigurationFailed;
    }

    try drive_client_handshake(io, stream.socket.handle, ssl, network_bio);
    try std.testing.expectEqual(@as(c_long, c.X509_V_OK), c.SSL_get_verify_result(ssl));
    try std.testing.expectEqual(tls.ApplicationProtocol.http1, tls.negotiated_protocol(ssl));

    try ssl_write_all(
        io,
        stream.socket.handle,
        ssl,
        network_bio,
        "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
    );
    try expect_http1_cluster_ok(io, stream.socket.handle, ssl, network_bio);
}

/// Reads one HTTP/1.1 response and asserts the cluster route status and body.
fn expect_http1_cluster_ok(
    io: std.Io,
    handle: net.Socket.Handle,
    ssl: *c.SSL,
    network_bio: *c.BIO,
) !void {
    var buffer: [4096]u8 = undefined;
    var total: usize = 0;
    var rounds: usize = 0;
    while (rounds < 32) : (rounds += 1) {
        if (std.mem.indexOf(u8, buffer[0..total], "cluster-ok") != null) {
            try std.testing.expect(std.mem.startsWith(u8, buffer[0..total], "HTTP/1.1 200"));
            return;
        }
        if (total == buffer.len) return error.ResponseTooLarge;
        const read = c.SSL_read(ssl, buffer[total..].ptr, @intCast(buffer.len - total));
        if (read > 0) {
            total += @intCast(read);
            continue;
        }
        const ssl_error = c.SSL_get_error(ssl, read);
        if (ssl_error == c.SSL_ERROR_ZERO_RETURN) {
            if (std.mem.indexOf(u8, buffer[0..total], "cluster-ok") == null) {
                return error.ResponseMissingBody;
            }
            try std.testing.expect(std.mem.startsWith(u8, buffer[0..total], "HTTP/1.1 200"));
            return;
        }
        if (ssl_error != c.SSL_ERROR_WANT_READ and ssl_error != c.SSL_ERROR_WANT_WRITE) {
            return error.ResponseReadFailed;
        }
        try flush_cluster_bio(io, handle, network_bio);
        try fill_cluster_bio(io, handle, network_bio);
    }
    return error.ResponseMissingBody;
}

/// Creates a P-256 server leaf with a DNS SAN for verified loopback clients.
fn create_test_localhost_credential(authority: TestAuthority, serial: c_long) !TestCredential {
    const key = try generate_test_key();
    errdefer c.EVP_PKEY_free(key);

    const certificate = try open_test_certificate(key, serial, "localhost");
    errdefer c.X509_free(certificate);

    try add_test_extension(certificate, c.NID_basic_constraints, "critical,CA:FALSE");
    try add_test_extension(certificate, c.NID_key_usage, "critical,digitalSignature");
    try add_test_extension(certificate, c.NID_ext_key_usage, "serverAuth");
    try add_test_extension(certificate, c.NID_subject_alt_name, "DNS:localhost");

    const issuer = c.X509_get_subject_name(authority.certificate) orelse {
        return error.TestCertificateCreationFailed;
    };
    if (c.X509_set_issuer_name(certificate, issuer) != 1) return error.TestCertificateCreationFailed;
    if (c.X509_sign(certificate, authority.key, c.EVP_sha256()) == 0) {
        return error.TestCertificateSigningFailed;
    }
    return .{ .key = key, .certificate = certificate };
}

test "tls cluster: enable_https installs one context per worker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try make_test_paths(std.testing.allocator, tmp.sub_path[0..]);
    defer paths.deinit(std.testing.allocator);

    const authority = try create_test_authority("cluster enable ca", 100);
    defer free_test_authority(authority);
    const credential = try create_test_leaf_credential(authority, "server.test", 101, .server);
    defer free_test_credential(credential);
    try write_server_credentials(tmp.dir, authority.certificate, credential);

    var group = try init_test_cluster();
    defer group.deinit();

    try group.enable_https(paths.server_certificate, paths.server_key);

    const first = group.worker(0).?.tls_ctx orelse return error.MissingWorkerTlsContext;
    const second = group.worker(1).?.tls_ctx orelse return error.MissingWorkerTlsContext;
    try std.testing.expect(first.ctx != second.ctx);
}

test "tls cluster: repeat enable_https returns TlsAlreadyEnabled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try make_test_paths(std.testing.allocator, tmp.sub_path[0..]);
    defer paths.deinit(std.testing.allocator);

    const authority = try create_test_authority("cluster repeat ca", 102);
    defer free_test_authority(authority);
    const credential = try create_test_leaf_credential(authority, "server.test", 103, .server);
    defer free_test_credential(credential);
    try write_server_credentials(tmp.dir, authority.certificate, credential);

    var group = try init_test_cluster();
    defer group.deinit();

    try group.enable_https(paths.server_certificate, paths.server_key);
    const first_ctx = group.worker(0).?.tls_ctx.?.ctx;
    const second_ctx = group.worker(1).?.tls_ctx.?.ctx;

    try std.testing.expectError(
        error.TlsAlreadyEnabled,
        group.enable_https(paths.server_certificate, paths.server_key),
    );
    try std.testing.expectEqual(first_ctx, group.worker(0).?.tls_ctx.?.ctx);
    try std.testing.expectEqual(second_ctx, group.worker(1).?.tls_ctx.?.ctx);
}

test "tls cluster: enable_https after listen returns AlreadyListening" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try make_test_paths(std.testing.allocator, tmp.sub_path[0..]);
    defer paths.deinit(std.testing.allocator);

    const authority = try create_test_authority("cluster listen ca", 104);
    defer free_test_authority(authority);
    const credential = try create_test_leaf_credential(authority, "server.test", 105, .server);
    defer free_test_credential(credential);
    try write_server_credentials(tmp.dir, authority.certificate, credential);

    var group = try init_test_cluster();
    defer group.deinit();

    try group.listen("127.0.0.1", 0);
    try std.testing.expectError(
        error.AlreadyListening,
        group.enable_https(paths.server_certificate, paths.server_key),
    );
    try std.testing.expect(group.worker(0).?.tls_ctx == null);
    try std.testing.expect(group.worker(1).?.tls_ctx == null);
}

test "tls cluster: enable_https on a released cluster returns ClusterDeinitialized" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try make_test_paths(std.testing.allocator, tmp.sub_path[0..]);
    defer paths.deinit(std.testing.allocator);

    const authority = try create_test_authority("cluster released ca", 106);
    defer free_test_authority(authority);
    const credential = try create_test_leaf_credential(authority, "server.test", 107, .server);
    defer free_test_credential(credential);
    try write_server_credentials(tmp.dir, authority.certificate, credential);

    var group = try init_test_cluster();
    defer group.deinit();
    group.deinit();

    try std.testing.expectError(
        error.ClusterDeinitialized,
        group.enable_https(paths.server_certificate, paths.server_key),
    );
    try std.testing.expectError(
        error.ClusterDeinitialized,
        group.listen("127.0.0.1", 0),
    );
}

test "tls cluster: malformed certificate is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try make_test_paths(std.testing.allocator, tmp.sub_path[0..]);
    defer paths.deinit(std.testing.allocator);

    const authority = try create_test_authority("cluster bad cert ca", 108);
    defer free_test_authority(authority);
    const credential = try create_test_leaf_credential(authority, "server.test", 109, .server);
    defer free_test_credential(credential);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "server.pem",
        .data = "not a certificate\n",
    });
    try write_private_key_pem(tmp.dir, "server-key.pem", credential.key);

    var group = try init_test_cluster();
    defer group.deinit();

    try std.testing.expectError(
        error.CertificateLoadFailed,
        group.enable_https(paths.server_certificate, paths.server_key),
    );
    try std.testing.expect(group.worker(0).?.tls_ctx == null);
    try std.testing.expect(group.worker(1).?.tls_ctx == null);
}

test "tls cluster: malformed private key is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try make_test_paths(std.testing.allocator, tmp.sub_path[0..]);
    defer paths.deinit(std.testing.allocator);

    const authority = try create_test_authority("cluster bad key ca", 110);
    defer free_test_authority(authority);
    const credential = try create_test_leaf_credential(authority, "server.test", 111, .server);
    defer free_test_credential(credential);
    try write_certificate_pem(tmp.dir, "server.pem", credential.certificate);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "server-key.pem",
        .data = "not a private key\n",
    });

    var group = try init_test_cluster();
    defer group.deinit();

    try std.testing.expectError(
        error.PrivateKeyLoadFailed,
        group.enable_https(paths.server_certificate, paths.server_key),
    );
    try std.testing.expect(group.worker(0).?.tls_ctx == null);
    try std.testing.expect(group.worker(1).?.tls_ctx == null);
}

test "tls cluster: mismatched certificate and key are rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try make_test_paths(std.testing.allocator, tmp.sub_path[0..]);
    defer paths.deinit(std.testing.allocator);

    const first_authority = try create_test_authority("cluster mismatch first ca", 112);
    defer free_test_authority(first_authority);
    const second_authority = try create_test_authority("cluster mismatch second ca", 113);
    defer free_test_authority(second_authority);
    const certificate_credential = try create_test_leaf_credential(
        first_authority,
        "server.test",
        114,
        .server,
    );
    defer free_test_credential(certificate_credential);
    const key_credential = try create_test_leaf_credential(
        second_authority,
        "server.test",
        115,
        .server,
    );
    defer free_test_credential(key_credential);
    try write_certificate_pem(tmp.dir, "server.pem", certificate_credential.certificate);
    try write_private_key_pem(tmp.dir, "server-key.pem", key_credential.key);

    var group = try init_test_cluster();
    defer group.deinit();

    // BoringSSL compares the public key inside `SSL_CTX_use_PrivateKey_file`
    // and rejects the key there, so the later `SSL_CTX_check_private_key`
    // mismatch branch is unreachable for PEM input; rejection is what matters.
    try std.testing.expectError(
        error.PrivateKeyLoadFailed,
        group.enable_https(paths.server_certificate, paths.server_key),
    );
    try std.testing.expect(group.worker(0).?.tls_ctx == null);
    try std.testing.expect(group.worker(1).?.tls_ctx == null);
}

test "tls cluster: failed credential enable leaves the group retryable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try make_test_paths(std.testing.allocator, tmp.sub_path[0..]);
    defer paths.deinit(std.testing.allocator);

    const authority = try create_test_authority("cluster retry ca", 116);
    defer free_test_authority(authority);
    const credential = try create_test_leaf_credential(authority, "server.test", 117, .server);
    defer free_test_credential(credential);

    var group = try init_test_cluster();
    defer group.deinit();

    // First call fails on the certificate before any context exists; fixing the
    // PEM files must make the same group enable successfully.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "server.pem",
        .data = "not a certificate\n",
    });
    try std.testing.expectError(
        error.CertificateLoadFailed,
        group.enable_https(paths.server_certificate, paths.server_key),
    );
    try std.testing.expect(group.worker(0).?.tls_ctx == null);
    try std.testing.expect(group.worker(1).?.tls_ctx == null);

    try write_certificate_pem(tmp.dir, "server.pem", credential.certificate);
    try write_private_key_pem(tmp.dir, "server-key.pem", credential.key);
    try group.enable_https(paths.server_certificate, paths.server_key);
    try std.testing.expect(group.worker(0).?.tls_ctx != null);
    try std.testing.expect(group.worker(1).?.tls_ctx != null);
}

test "tls cluster: partial enable releases created contexts exactly once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try make_test_paths(std.testing.allocator, tmp.sub_path[0..]);
    defer paths.deinit(std.testing.allocator);

    const authority = try create_test_authority("cluster partial ca", 116);
    defer free_test_authority(authority);
    const credential = try create_test_leaf_credential(authority, "server.test", 117, .server);
    defer free_test_credential(credential);
    try write_server_credentials(tmp.dir, authority.certificate, credential);

    var group = try init_test_cluster();
    defer group.deinit();

    const preset = try tls.TlsContext.init_ephemeral(.{});
    const preset_ctx = preset.ctx;
    group.worker(1).?.tls_ctx = preset;

    // Repeating the failure widens any double-free window in the rollback.
    for (0..3) |_| {
        try std.testing.expectError(
            error.TlsAlreadyEnabled,
            group.enable_https(paths.server_certificate, paths.server_key),
        );
        try std.testing.expect(group.worker(0).?.tls_ctx == null);
        try std.testing.expectEqual(preset_ctx, group.worker(1).?.tls_ctx.?.ctx);
    }

    if (group.worker(1).?.tls_ctx) |*preset_tls| preset_tls.deinit();
    group.worker(1).?.tls_ctx = null;

    try group.enable_https(paths.server_certificate, paths.server_key);
    try std.testing.expect(group.worker(0).?.tls_ctx != null);
    try std.testing.expect(group.worker(1).?.tls_ctx != null);
}

test "tls cluster: ephemeral enable gives every worker a distinct context" {
    var group = try init_test_cluster();
    defer group.deinit();

    try group.enable_https_ephemeral();

    const first = group.worker(0).?.tls_ctx orelse return error.MissingWorkerTlsContext;
    const second = group.worker(1).?.tls_ctx orelse return error.MissingWorkerTlsContext;
    try std.testing.expect(first.ctx != second.ctx);
}

test "tls cluster: plaintext cluster lifecycle is unchanged" {
    var group = try init_test_cluster();
    defer group.deinit();

    try group.listen("127.0.0.1", 0);
    try std.testing.expect(group.worker(0).?.server != null);
    try std.testing.expect(group.worker(1).?.server != null);
    try std.testing.expect(group.worker(0).?.tls_ctx == null);
    try std.testing.expect(group.worker(1).?.tls_ctx == null);
}

test "tls cluster: each worker completes a real client handshake on its own context" {
    // The ASan and MSan runtimes abort this binary while tearing down OS threads.
    if (test_options.sanitize or test_options.memory_sanitize) return error.SkipZigTest;
    // The verified client reads one worker's bound port and arms SO_RCVTIMEO.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try make_test_paths(std.testing.allocator, tmp.sub_path[0..]);
    defer paths.deinit(std.testing.allocator);

    const authority = try create_test_authority("cluster handshake ca", 118);
    defer free_test_authority(authority);
    const credential = try create_test_localhost_credential(authority, 119);
    defer free_test_credential(credential);
    try write_server_credentials(tmp.dir, authority.certificate, credential);

    var group = try init_test_cluster();
    defer group.deinit();

    try group.configure(configure_cluster_routes);
    try group.enable_https(paths.server_certificate, paths.server_key);
    try group.listen("127.0.0.1", 0);
    const first_port = try worker_port(group.worker(0).?);
    const second_port = try worker_port(group.worker(1).?);

    var runner = ClusterRunner{ .group = &group };
    const thread = try std.Thread.spawn(.{}, ClusterRunner.run, .{&runner});
    var joined = false;
    defer {
        group.request_shutdown();
        if (!joined) thread.join();
    }

    try expect_https_ok(first_port, paths.ca);
    try expect_https_ok(second_port, paths.ca);

    group.request_shutdown();
    thread.join();
    joined = true;
    try std.testing.expect(runner.failure == null);
}

test "tls cluster: shared port serves TLS connections" {
    // The ASan and MSan runtimes abort this binary while tearing down OS threads.
    if (test_options.sanitize or test_options.memory_sanitize) return error.SkipZigTest;
    // The verified client arms SO_RCVTIMEO, which std.posix lacks on Windows.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try make_test_paths(std.testing.allocator, tmp.sub_path[0..]);
    defer paths.deinit(std.testing.allocator);

    const authority = try create_test_authority("cluster shared port ca", 120);
    defer free_test_authority(authority);
    const credential = try create_test_localhost_credential(authority, 121);
    defer free_test_credential(credential);
    try write_server_credentials(tmp.dir, authority.certificate, credential);

    var group = try init_test_cluster();
    defer group.deinit();

    try group.configure(configure_cluster_routes);
    try group.enable_https(paths.server_certificate, paths.server_key);

    // A reserved port can race another process between close and bind, so one
    // fresh reservation retries before the test reports failure.
    var port: u16 = 0;
    var bound = false;
    for (0..2) |_| {
        port = try reserve_loopback_port();
        group.listen("127.0.0.1", port) catch |err| {
            if (err == error.AddressInUse) continue;
            return err;
        };
        bound = true;
        break;
    }
    if (!bound) return error.AddressInUse;

    var runner = ClusterRunner{ .group = &group };
    const thread = try std.Thread.spawn(.{}, ClusterRunner.run, .{&runner});
    var joined = false;
    defer {
        group.request_shutdown();
        if (!joined) thread.join();
    }

    for (0..4) |_| try expect_https_ok(port, paths.ca);

    group.request_shutdown();
    thread.join();
    joined = true;
    try std.testing.expect(runner.failure == null);
}

test "tls cluster: h2 ALPN negotiates on a TLS cluster worker" {
    // The ASan and MSan runtimes abort this binary while tearing down OS threads.
    if (test_options.sanitize or test_options.memory_sanitize) return error.SkipZigTest;
    // SO_RCVTIMEO keeps one stalled h2 read from hanging the test; std.posix
    // does not expose it on Windows.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var group = try init_test_cluster();
    defer group.deinit();

    try group.configure(configure_cluster_routes);
    try group.enable_https_ephemeral();
    try group.listen("127.0.0.1", 0);
    const port = try worker_port(group.worker(0).?);

    var runner = ClusterRunner{ .group = &group };
    const thread = try std.Thread.spawn(.{}, ClusterRunner.run, .{&runner});
    var joined = false;
    defer {
        group.request_shutdown();
        if (!joined) thread.join();
    }

    try expect_h2_cluster_response(port);

    group.request_shutdown();
    thread.join();
    joined = true;
    try std.testing.expect(runner.failure == null);
}

/// Drives one verified h2 request against a cluster worker and asserts a 200.
fn expect_h2_cluster_response(port: u16) !void {
    const io = std.testing.io;
    var address = try net.IpAddress.parse("127.0.0.1", port);
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    try set_cluster_client_timeout(stream.socket.handle);

    const client_context = c.SSL_CTX_new(c.TLS_method()) orelse {
        return error.ClientContextCreationFailed;
    };
    defer c.SSL_CTX_free(client_context);
    if (c.SSL_CTX_set_min_proto_version(client_context, c.TLS1_3_VERSION) != 1) {
        return error.ClientContextCreationFailed;
    }
    if (c.SSL_CTX_set_max_proto_version(client_context, c.TLS1_3_VERSION) != 1) {
        return error.ClientContextCreationFailed;
    }
    // The cluster uses ephemeral self-signed credentials; ALPN is what this
    // test observes, not server authenticity.
    c.SSL_CTX_set_verify(client_context, c.SSL_VERIFY_NONE, null);

    const ssl = c.SSL_new(client_context) orelse return error.SslCreationFailed;
    defer c.SSL_free(ssl);
    const network_bio = try attach_client_bio(ssl);
    defer _ = c.BIO_free(network_bio);
    c.SSL_set_connect_state(ssl);

    const server_name: [:0]const u8 = "localhost";
    if (c.SSL_set_tlsext_host_name(ssl, server_name.ptr) != 1) {
        return error.SniConfigurationFailed;
    }
    if (c.SSL_set_alpn_protos(ssl, "\x02h2", 3) != 0) {
        return error.ClientAlpnConfigurationFailed;
    }

    try drive_client_handshake(io, stream.socket.handle, ssl, network_bio);
    try std.testing.expectEqual(tls.ApplicationProtocol.http2, tls.negotiated_protocol(ssl));

    var request: [512]u8 = undefined;
    @memcpy(request[0..http2.client_preface.len], http2.client_preface);
    var request_length: usize = http2.client_preface.len;
    try append_frame(&request, &request_length, .settings, 0, 0, "");

    var block: [256]u8 = undefined;
    var block_length: usize = 0;
    block_length = try append_hpack_literal(&block, block_length, ":method", "GET");
    block_length = try append_hpack_literal(&block, block_length, ":scheme", "https");
    block_length = try append_hpack_literal(&block, block_length, ":path", "/");
    block_length = try append_hpack_literal(&block, block_length, "host", "localhost");
    try append_frame(&request, &request_length, .headers, 0x5, 1, block[0..block_length]);
    try ssl_write_all(io, stream.socket.handle, ssl, network_bio, request[0..request_length]);

    try expect_h2_status_200(io, stream.socket.handle, ssl, network_bio);
}

/// Attaches a memory BIO pair to `ssl` and returns the network side.
fn attach_client_bio(ssl: *c.SSL) !*c.BIO {
    var ssl_bio: ?*c.BIO = null;
    var network_bio: ?*c.BIO = null;
    if (c.BIO_new_bio_pair(
        &ssl_bio,
        cluster_tls_bio_capacity,
        &network_bio,
        cluster_tls_bio_capacity,
    ) != 1) {
        return error.BioCreationFailed;
    }
    c.SSL_set_bio(ssl, ssl_bio.?, ssl_bio.?);
    return network_bio.?;
}

/// Bounds one blocking client read so a stalled server fails the test.
fn set_cluster_client_timeout(handle: net.Socket.Handle) !void {
    // SO_RCVTIMEO keeps one stalled read from hanging the test; std.posix
    // does not expose it on Windows.
    if (builtin.os.tag == .windows) return;
    var timeout = std.posix.timeval{ .sec = 5, .usec = 0 };
    try std.posix.setsockopt(
        handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&timeout),
    );
}

fn drive_client_handshake(
    io: std.Io,
    handle: net.Socket.Handle,
    ssl: *c.SSL,
    network_bio: *c.BIO,
) !void {
    var rounds: usize = 0;
    while (c.SSL_is_init_finished(ssl) == 0 and rounds < 64) : (rounds += 1) {
        const result = c.SSL_do_handshake(ssl);
        switch (c.SSL_get_error(ssl, result)) {
            c.SSL_ERROR_NONE, c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => {},
            else => return error.TlsHandshakeFailed,
        }
        try flush_cluster_bio(io, handle, network_bio);
        if (c.SSL_is_init_finished(ssl) == 1) return;
        try fill_cluster_bio(io, handle, network_bio);
    }
    if (c.SSL_is_init_finished(ssl) != 1) return error.TlsHandshakeStalled;
}

/// Drains ciphertext from a BIO to the socket.
fn flush_cluster_bio(io: std.Io, handle: net.Socket.Handle, outgoing: *c.BIO) !void {
    var buffer: [cluster_tls_bio_capacity]u8 = undefined;
    while (c.BIO_ctrl_pending(outgoing) > 0) {
        const pending: usize = @intCast(c.BIO_ctrl_pending(outgoing));
        const read = c.BIO_read(outgoing, &buffer, @intCast(@min(pending, buffer.len)));
        if (read <= 0) return error.HandshakeIoFailed;
        const available = buffer[0..@intCast(read)];
        var offset: usize = 0;
        while (offset < available.len) {
            const written = io.vtable.netWrite(
                io.userdata,
                handle,
                available[offset..],
                &.{""},
                0,
            ) catch return error.HandshakeIoFailed;
            if (written == 0) return error.HandshakeIoFailed;
            offset += written;
        }
    }
}

/// Reads ciphertext from the socket into a BIO.
fn fill_cluster_bio(io: std.Io, handle: net.Socket.Handle, incoming: *c.BIO) !void {
    var buffer: [cluster_tls_bio_capacity]u8 = undefined;
    var data = [1][]u8{&buffer};
    const read = io.vtable.netRead(io.userdata, handle, &data) catch {
        return error.HandshakeIoFailed;
    };
    if (read == 0) return error.HandshakeIoFailed;
    var offset: usize = 0;
    while (offset < read) {
        const written = c.BIO_write(incoming, buffer[offset..].ptr, @intCast(read - offset));
        if (written <= 0) return error.HandshakeIoFailed;
        offset += @intCast(written);
    }
}

fn ssl_write_all(
    io: std.Io,
    handle: net.Socket.Handle,
    ssl: *c.SSL,
    network_bio: *c.BIO,
    bytes: []const u8,
) !void {
    var written_total: usize = 0;
    var rounds: usize = 0;
    while (written_total < bytes.len and rounds < 16) : (rounds += 1) {
        const written = c.SSL_write(
            ssl,
            bytes[written_total..].ptr,
            @intCast(bytes.len - written_total),
        );
        if (written > 0) {
            written_total += @intCast(written);
            try flush_cluster_bio(io, handle, network_bio);
            continue;
        }
        const ssl_error = c.SSL_get_error(ssl, written);
        if (ssl_error != c.SSL_ERROR_WANT_WRITE and ssl_error != c.SSL_ERROR_WANT_READ) {
            return error.SslWriteFailed;
        }
        if (ssl_error == c.SSL_ERROR_WANT_READ) try fill_cluster_bio(io, handle, network_bio);
        try flush_cluster_bio(io, handle, network_bio);
    }
    if (written_total != bytes.len) return error.SslWriteStalled;
}

/// Reads frames until the stream 1 HEADERS block starts with `:status 200`.
fn expect_h2_status_200(
    io: std.Io,
    handle: net.Socket.Handle,
    ssl: *c.SSL,
    network_bio: *c.BIO,
) !void {
    var buffer: [8192]u8 = undefined;
    var total: usize = 0;
    var rounds: usize = 0;
    while (rounds < 32) : (rounds += 1) {
        var offset: usize = 0;
        while (total - offset >= 9) {
            const header = try http2.FrameHeader.parse(buffer[offset..][0..9]);
            const frame_length = 9 + header.payload_length;
            if (frame_length > total - offset) break;
            if (header.frame_type == @intFromEnum(http2.FrameType.headers) and
                header.stream_id == 1)
            {
                try std.testing.expect(header.payload_length > 0);
                try std.testing.expectEqual(@as(u8, 0x88), buffer[offset + 9]);
                return;
            }
            offset += frame_length;
        }
        if (total == buffer.len) return error.ResponseFramesTooLarge;
        const read = c.SSL_read(ssl, buffer[total..].ptr, @intCast(buffer.len - total));
        if (read <= 0) {
            const ssl_error = c.SSL_get_error(ssl, read);
            if (ssl_error != c.SSL_ERROR_WANT_READ and ssl_error != c.SSL_ERROR_WANT_WRITE) {
                return error.ResponseReadFailed;
            }
            try flush_cluster_bio(io, handle, network_bio);
            try fill_cluster_bio(io, handle, network_bio);
            continue;
        }
        total += @intCast(read);
    }
    return error.ResponseHeadersMissing;
}

/// Appends one frame header and payload to `output`.
fn append_frame(
    output: []u8,
    offset: *usize,
    frame_type: http2.FrameType,
    flags: u8,
    stream_id: u32,
    payload: []const u8,
) !void {
    if (9 + payload.len > output.len - offset.*) return error.OutputTooSmall;
    var frame_header: [9]u8 = undefined;
    try (http2.FrameHeader{
        .payload_length = @intCast(payload.len),
        .frame_type = @intFromEnum(frame_type),
        .flags = flags,
        .stream_id = stream_id,
    }).encode(&frame_header);
    @memcpy(output[offset.* .. offset.* + 9], &frame_header);
    offset.* += 9;
    @memcpy(output[offset.* .. offset.* + payload.len], payload);
    offset.* += payload.len;
}

/// Encodes one literal HPACK field without indexing.
fn append_hpack_literal(
    buffer: []u8,
    offset: usize,
    name: []const u8,
    value: []const u8,
) !usize {
    const required = 2 + name.len + 1 + value.len;
    if (required > buffer.len - offset) return error.OutputTooSmall;
    var cursor = offset;
    buffer[cursor] = 0;
    cursor += 1;
    buffer[cursor] = @intCast(name.len);
    cursor += 1;
    @memcpy(buffer[cursor .. cursor + name.len], name);
    cursor += name.len;
    buffer[cursor] = @intCast(value.len);
    cursor += 1;
    @memcpy(buffer[cursor .. cursor + value.len], value);
    return cursor + value.len;
}
