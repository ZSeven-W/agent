//! LRU file state cache with max entries and max bytes eviction.
//!
//! Internally maintains a doubly-linked list (most-recently-used at front,
//! least-recently-used at back) and a StringHashMap for O(1) lookup.
//! When inserting a new entry would exceed either `max_entries` or
//! `max_size_bytes`, the tail (LRU) entry is evicted until both constraints
//! are satisfied.

const std = @import("std");

// ---------------------------------------------------------------------------
// FileState
// ---------------------------------------------------------------------------

/// Snapshot of a file's content at a point in time.
pub const FileState = struct {
    content: []const u8,
    timestamp: i64,
    offset: ?usize = null,
    limit: ?usize = null,
    is_partial_view: bool = false,
};

// ---------------------------------------------------------------------------
// Internal linked-list node
// ---------------------------------------------------------------------------

const Node = struct {
    /// Owned copy of the map key (file path).
    key: []u8,
    value: FileState,
    prev: ?*Node,
    next: ?*Node,
};

// ---------------------------------------------------------------------------
// FileStateCache
// ---------------------------------------------------------------------------

pub const FileStateCache = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(*Node),
    /// Most-recently-used node (front of list), or null when empty.
    list_head: ?*Node,
    /// Least-recently-used node (back of list), or null when empty.
    list_tail: ?*Node,
    max_entries: usize,
    max_size_bytes: usize,
    len: usize,
    current_size_bytes: usize,

    /// Create a new, empty cache.
    ///
    /// `max_entries`    — maximum number of entries before LRU eviction.
    /// `max_size_bytes` — maximum total `content.len` before LRU eviction.
    pub fn init(
        allocator: std.mem.Allocator,
        max_entries: usize,
        max_size_bytes: usize,
    ) FileStateCache {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(*Node).init(allocator),
            .list_head = null,
            .list_tail = null,
            .max_entries = max_entries,
            .max_size_bytes = max_size_bytes,
            .len = 0,
            .current_size_bytes = 0,
        };
    }

    pub fn deinit(self: *FileStateCache) void {
        self.freeAllNodes();
        self.map.deinit();
    }

    // -----------------------------------------------------------------------
    // Public API
    // -----------------------------------------------------------------------

    /// Look up `path` and, if found, promote it to most-recently-used.
    pub fn get(self: *FileStateCache, path: []const u8) ?FileState {
        const node = self.map.get(path) orelse return null;
        self.promoteToFront(node);
        return node.value;
    }

    /// Insert or update an entry.  Evicts LRU entries when limits are exceeded.
    pub fn set(self: *FileStateCache, path: []const u8, state: FileState) !void {
        if (self.map.get(path)) |existing| {
            // Update in place: adjust byte counter and move to front.
            self.current_size_bytes -= existing.value.content.len;
            existing.value = state;
            self.current_size_bytes += state.content.len;
            self.promoteToFront(existing);
            return;
        }

        // Evict until there is room for the new entry.
        while (self.len >= self.max_entries or
            self.current_size_bytes + state.content.len > self.max_size_bytes)
        {
            if (self.len == 0) break; // Safety: nothing left to evict.
            self.evictLRU();
        }

        // Allocate a new node with an owned copy of the key.
        const key_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key_copy);

        const node = try self.allocator.create(Node);
        errdefer self.allocator.destroy(node);

        node.* = .{
            .key = key_copy,
            .value = state,
            .prev = null,
            .next = null,
        };

        try self.map.put(key_copy, node);

        self.insertAtFront(node);
        self.len += 1;
        self.current_size_bytes += state.content.len;
    }

    /// Return `true` if `path` is currently cached (does not affect LRU order).
    pub fn has(self: *FileStateCache, path: []const u8) bool {
        return self.map.contains(path);
    }

    /// Return the number of entries currently held.
    pub fn count(self: *FileStateCache) usize {
        return self.len;
    }

    /// Remove all cached entries.
    pub fn clear(self: *FileStateCache) void {
        self.freeAllNodes();
        self.map.clearRetainingCapacity();
        self.list_head = null;
        self.list_tail = null;
        self.len = 0;
        self.current_size_bytes = 0;
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    /// Unlink `node` from the list and re-insert it at the front (MRU position).
    fn promoteToFront(self: *FileStateCache, node: *Node) void {
        if (self.list_head == node) return; // Already at front.
        self.unlinkNode(node);
        self.insertAtFront(node);
    }

    /// Insert `node` at the front of the list (MRU position).
    fn insertAtFront(self: *FileStateCache, node: *Node) void {
        node.prev = null;
        node.next = self.list_head;
        if (self.list_head) |old_head| old_head.prev = node;
        self.list_head = node;
        if (self.list_tail == null) self.list_tail = node;
    }

    /// Remove `node` from the doubly-linked list without freeing it.
    fn unlinkNode(self: *FileStateCache, node: *Node) void {
        if (node.prev) |p| {
            p.next = node.next;
        } else {
            // node was the head
            self.list_head = node.next;
        }
        if (node.next) |n| {
            n.prev = node.prev;
        } else {
            // node was the tail
            self.list_tail = node.prev;
        }
        node.prev = null;
        node.next = null;
    }

    /// Evict the least-recently-used entry (the tail node).
    fn evictLRU(self: *FileStateCache) void {
        const lru = self.list_tail orelse return;
        self.unlinkNode(lru);
        _ = self.map.remove(lru.key);
        self.current_size_bytes -= lru.value.content.len;
        self.len -= 1;
        self.allocator.free(lru.key);
        self.allocator.destroy(lru);
    }

    /// Free every live node (called by `deinit` and `clear`).
    fn freeAllNodes(self: *FileStateCache) void {
        var current = self.list_head;
        while (current) |node| {
            const next = node.next;
            self.allocator.free(node.key);
            self.allocator.destroy(node);
            current = next;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "basic get/set" {
    const allocator = std.testing.allocator;
    var cache = FileStateCache.init(allocator, 10, 1024 * 1024);
    defer cache.deinit();

    const state = FileState{
        .content = "const x = 1;",
        .timestamp = 1_000_000,
    };
    try cache.set("a.zig", state);

    const result = cache.get("a.zig");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("const x = 1;", result.?.content);
    try std.testing.expectEqual(@as(i64, 1_000_000), result.?.timestamp);
}

test "evicts LRU on max entries" {
    const allocator = std.testing.allocator;
    var cache = FileStateCache.init(allocator, 2, 1024 * 1024);
    defer cache.deinit();

    try cache.set("a.zig", .{ .content = "a", .timestamp = 1 });
    try cache.set("b.zig", .{ .content = "b", .timestamp = 2 });
    // Inserting "c.zig" exceeds max_entries=2; "a.zig" (LRU) must be evicted.
    try cache.set("c.zig", .{ .content = "c", .timestamp = 3 });

    try std.testing.expectEqual(@as(usize, 2), cache.count());
    try std.testing.expect(!cache.has("a.zig")); // evicted
    try std.testing.expect(cache.has("b.zig"));
    try std.testing.expect(cache.has("c.zig"));
}

test "access promotes to head (LRU)" {
    const allocator = std.testing.allocator;
    var cache = FileStateCache.init(allocator, 2, 1024 * 1024);
    defer cache.deinit();

    try cache.set("a.zig", .{ .content = "a", .timestamp = 1 });
    try cache.set("b.zig", .{ .content = "b", .timestamp = 2 });

    // Access "a.zig" so it becomes MRU; "b.zig" becomes LRU.
    _ = cache.get("a.zig");

    // Inserting "c.zig" should evict "b.zig" (now the LRU), not "a.zig".
    try cache.set("c.zig", .{ .content = "c", .timestamp = 3 });

    try std.testing.expectEqual(@as(usize, 2), cache.count());
    try std.testing.expect(cache.has("a.zig")); // promoted, not evicted
    try std.testing.expect(!cache.has("b.zig")); // evicted
    try std.testing.expect(cache.has("c.zig"));
}

test "clear" {
    const allocator = std.testing.allocator;
    var cache = FileStateCache.init(allocator, 10, 1024 * 1024);
    defer cache.deinit();

    try cache.set("a.zig", .{ .content = "a", .timestamp = 1 });
    try cache.set("b.zig", .{ .content = "b", .timestamp = 2 });
    try std.testing.expectEqual(@as(usize, 2), cache.count());

    cache.clear();
    try std.testing.expectEqual(@as(usize, 0), cache.count());
}
