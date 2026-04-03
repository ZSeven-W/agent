//! Swarm — multi-agent coordination primitives.
//!
//! Modules:
//!   mailbox         — file-based teammate messaging
//!   permission_sync — file-based cross-agent permission coordination
//!   backends        — backend registry with in_process, tmux, iterm2 backends
//!   coordinator     — top-level multi-agent swarm coordinator

pub const mailbox = @import("swarm/mailbox.zig");
pub const Mailbox = mailbox.Mailbox;
pub const TeammateMessage = mailbox.TeammateMessage;

pub const permission_sync = @import("swarm/permission_sync.zig");
pub const PermissionSync = permission_sync.PermissionSync;
pub const PermissionRequest = permission_sync.PermissionRequest;
pub const PermissionResponse = permission_sync.PermissionResponse;

pub const backends = struct {
    pub const registry = @import("swarm/backends/registry.zig");
    pub const in_process = @import("swarm/backends/in_process.zig");
    pub const tmux = @import("swarm/backends/tmux.zig");
    pub const iterm2 = @import("swarm/backends/iterm2.zig");

    pub const BackendRegistry = registry.BackendRegistry;
    pub const BackendType = registry.BackendType;
    pub const InProcessTeammate = in_process.InProcessTeammate;
    pub const TmuxBackend = tmux.TmuxBackend;
    pub const ITerm2Backend = iterm2.ITerm2Backend;
};

pub const coordinator = @import("swarm/swarm.zig");
pub const Swarm = coordinator.Swarm;
pub const SwarmConfig = coordinator.SwarmConfig;

test {
    _ = mailbox;
    _ = permission_sync;
    _ = backends.registry;
    _ = backends.in_process;
    _ = backends.tmux;
    _ = backends.iterm2;
    _ = coordinator;
}
