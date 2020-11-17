const std = @import("std");
const pike = @import("pike.zig");
const windows = @import("os/windows.zig");

pub const Event = struct {
    const Self = @This();

    port: windows.HANDLE = windows.INVALID_HANDLE_VALUE,

    pub fn init() !Self {
        return Self{};
    }

    pub fn deinit(self: *Self) void {}

    pub fn registerTo(self: *Self, notifier: *const pike.Notifier) !void {
        self.port = notifier.handle;
    }

    pub fn post(self: *const Self) callconv(.Async) !void {
        try windows.PostQueuedCompletionStatus(self.port, 0, 0, null);
    }
};
