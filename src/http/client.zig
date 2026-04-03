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
        return .{
            .client = std.http.Client{ .allocator = allocator },
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
        const uri = std.Uri.parse(req.url) catch return error.ConnectionFailed;

        // Build extra_headers slice from our header format.
        var extra_headers: std.ArrayList(std.http.Header) = .{};
        defer extra_headers.deinit(self.allocator);
        for (req.headers) |h| {
            extra_headers.append(self.allocator, .{
                .name = h.name,
                .value = h.value,
            }) catch return error.OutOfMemory;
        }

        // Heap-allocate Request so that `Response.request` (a `*Request`) remains
        // valid even after this function returns and StreamingResponse is moved.
        const request = self.allocator.create(std.http.Client.Request) catch return error.OutOfMemory;
        errdefer {
            request.deinit();
            self.allocator.destroy(request);
        }

        request.* = self.client.request(req.method, uri, .{
            .extra_headers = extra_headers.items,
        }) catch return error.ConnectionFailed;

        if (req.body) |body| {
            // sendBodyComplete requires []u8; body is []const u8.
            // The function does not mutate the slice content, so this cast is safe.
            request.sendBodyComplete(@constCast(body)) catch return error.ConnectionFailed;
        } else {
            request.sendBodiless() catch return error.ConnectionFailed;
        }

        // Redirect buffer: only needed during receiveHead; can be stack-allocated.
        var redirect_buf: [4 * 1024]u8 = undefined;
        const response = request.receiveHead(&redirect_buf) catch return error.ConnectionFailed;

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
