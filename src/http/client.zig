// src/http/client.zig
const std = @import("std");

pub const HttpRequest = struct {
    method: std.http.Method = .POST,
    url: []const u8,
    headers: []const Header = &.{},
    body: ?[]const u8 = null,

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };
};

pub const HttpError = error{
    ConnectionFailed,
    TlsError,
    Timeout,
    StatusError,
    OutOfMemory,
};

/// A streaming HTTP response.
///
/// `request` is heap-allocated so that the `std.http.Client.Response` stored
/// here can safely hold a pointer back to it (`Response.request = self.request`)
/// without the pointer becoming dangling when `StreamingResponse` is moved.
pub const StreamingResponse = struct {
    allocator: std.mem.Allocator,
    /// Heap-allocated so its address is stable across copies of this struct.
    request: *std.http.Client.Request,
    response: std.http.Client.Response,
    status: std.http.Status,
    transfer_buf: [8 * 1024]u8 = undefined,
    /// Lazily initialised on the first `readChunk` call — `bodyReader()` may
    /// only be called once (it asserts `reader.state == .received_head`).
    io_reader: ?*std.Io.Reader = null,

    /// Read the next chunk from the response body.
    /// Returns 0 at end-of-stream.
    pub fn readChunk(self: *StreamingResponse, buf: []u8) !usize {
        if (self.io_reader == null) {
            self.io_reader = self.response.reader(&self.transfer_buf);
        }
        return self.io_reader.?.readSliceShort(buf) catch |err| switch (err) {
            error.ReadFailed => return 0,
        };
    }

    pub fn close(self: *StreamingResponse) void {
        self.request.deinit();
        self.allocator.destroy(self.request);
    }
};

pub const HttpClient = struct {
    client: std.http.Client,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HttpClient {
        var client = std.http.Client{ .allocator = allocator };
        // Disable connection pooling — each request uses a fresh TCP connection.
        // Pooled connections from providers that silently close SSE streams cause
        // Bus errors and corrupted state on reuse.
        client.connection_pool.free_size = 0;
        return .{
            .client = client,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }

    /// Send a request and return a streaming response (body not yet consumed).
    ///
    /// The returned `StreamingResponse` heap-allocates the `std.http.Client.Request`
    /// so that internal pointers inside `Response` remain valid after the struct is
    /// moved.  Call `close()` on the returned value to release it.
    pub fn streamRequest(self: *HttpClient, req: HttpRequest) HttpError!StreamingResponse {
        std.debug.print("[http] url={s}\n", .{req.url});
        const uri = std.Uri.parse(req.url) catch {
            std.debug.print("[http] URI parse failed\n", .{});
            return error.ConnectionFailed;
        };

        var extra_headers: std.ArrayList(std.http.Header) = .{};
        defer extra_headers.deinit(self.allocator);
        for (req.headers) |h| {
            extra_headers.append(self.allocator, .{
                .name = h.name,
                .value = h.value,
            }) catch return error.OutOfMemory;
        }

        const request = self.allocator.create(std.http.Client.Request) catch return error.OutOfMemory;
        errdefer {
            request.deinit();
            self.allocator.destroy(request);
        }

        std.debug.print("[http] connecting...\n", .{});
        request.* = self.client.request(req.method, uri, .{
            .extra_headers = extra_headers.items,
        }) catch |err| {
            std.debug.print("[http] request failed: {s}\n", .{@errorName(err)});
            return error.ConnectionFailed;
        };

        // Save body preview BEFORE sendBodyComplete — it uses the body buffer
        // as a write buffer and overwrites the original content.
        var body_preview: [2000]u8 = undefined;
        var body_preview_len: usize = 0;
        var body_total_len: usize = 0;
        if (req.body) |b| {
            body_total_len = b.len;
            body_preview_len = @min(b.len, 2000);
            @memcpy(body_preview[0..body_preview_len], b[0..body_preview_len]);
        }

        std.debug.print("[http] sending body...\n", .{});
        if (req.body) |body| {
            request.sendBodyComplete(@constCast(body)) catch |err| {
                std.debug.print("[http] send body failed: {s}\n", .{@errorName(err)});
                return error.ConnectionFailed;
            };
        } else {
            request.sendBodiless() catch |err| {
                std.debug.print("[http] send bodiless failed: {s}\n", .{@errorName(err)});
                return error.ConnectionFailed;
            };
        }

        std.debug.print("[http] waiting for response...\n", .{});
        var redirect_buf: [4 * 1024]u8 = undefined;
        var response = request.receiveHead(&redirect_buf) catch |err| {
            std.debug.print("[http] receiveHead failed: {s}\n", .{@errorName(err)});
            return error.ConnectionFailed;
        };
        std.debug.print("[http] response status: {d}\n", .{@intFromEnum(response.head.status)});

        // For error responses, print diagnostics.
        if (response.head.status != .ok) {
            if (body_preview_len > 0) {
                std.debug.print("[http] request body ({d} bytes): {s}\n", .{ body_total_len, body_preview[0..body_preview_len] });
            }
            // Read error response body while Response is at original stack location.
            // reader() panics after the Response is moved into StreamingResponse.
            var err_buf: [4096]u8 = undefined;
            var err_transfer_buf: [8 * 1024]u8 = undefined;
            const err_reader = response.reader(&err_transfer_buf);
            const err_n = err_reader.readSliceShort(&err_buf) catch 0;
            if (err_n > 0) {
                std.debug.print("[http] response body: {s}\n", .{err_buf[0..err_n]});
            }
        }

        return .{
            .allocator = self.allocator,
            .request = request,
            .response = response,
            .status = response.head.status,
        };
    }
};

test "HttpClient init/deinit" {
    const allocator = std.testing.allocator;
    var client = HttpClient.init(allocator);
    defer client.deinit();
    // Just verify it doesn't crash
}
