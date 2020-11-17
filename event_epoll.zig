const std = @import("std");
const pike = @import("pike.zig");

const os = std.os;
const mem = std.mem;

usingnamespace @import("waker.zig");

pub const Event = struct {
    const Self = @This();

    handle: pike.Handle,
    readers: Waker = .{},
    writers: Waker = .{},

    pub fn init() !Self {
        return Self{
            .handle = .{
                .inner = try os.eventfd(0, os.EFD_CLOEXEC | os.EFD_NONBLOCK),
                .wake_fn = wake,
            },
        };
    }

    pub fn deinit(self: *Self) void {
        os.close(self.handle.inner);

        if (self.writers.shutdown()) |task| pike.dispatch(task, .{});
        while (true) self.writers.wait() catch break;

        if (self.readers.shutdown()) |task| pike.dispatch(task, .{});
        while (true) self.readers.wait() catch break;
    }

    pub fn registerTo(self: *const Self, notifier: *const pike.Notifier) !void {
        try notifier.register(&self.handle, .{ .read = true, .write = true });
    }

    inline fn wake(handle: *pike.Handle, opts: pike.WakeOptions) void {
        const self = @fieldParentPtr(Self, "handle", handle);

        if (opts.write_ready) if (self.writers.notify()) |task| pike.dispatch(task, .{});
        if (opts.read_ready) if (self.readers.notify()) |task| pike.dispatch(task, .{});
        if (opts.shutdown) {
            if (self.writers.shutdown()) |task| pike.dispatch(task, .{});
            if (self.readers.shutdown()) |task| pike.dispatch(task, .{});
        }
    }

    fn ErrorUnionOf(comptime func: anytype) std.builtin.TypeInfo.ErrorUnion {
        return @typeInfo(@typeInfo(@TypeOf(func)).Fn.return_type.?).ErrorUnion;
    }

    inline fn call(self: *Self, comptime function: anytype, args: anytype, comptime opts: pike.CallOptions) !ErrorUnionOf(function).payload {
        while (true) {
            const result = @call(.{ .modifier = .always_inline }, function, args) catch |err| switch (err) {
                error.WouldBlock => {
                    if (comptime opts.write) {
                        try self.writers.wait();
                    } else if (comptime opts.read) {
                        try self.readers.wait();
                    }
                    continue;
                },
                else => return err,
            };

            return result;
        }
    }

    fn write(self: *Self, amount: u64) callconv(.Async) !void {
        const num_bytes = try self.call(os.write, .{
            self.handle.inner,
            mem.asBytes(&amount),
        }, .{ .write = true });

        if (num_bytes != @sizeOf(@TypeOf(amount))) {
            return error.ShortWrite;
        }
    }

    fn read(self: *Self) callconv(.Async) !void {
        var counter: u64 = 0;

        const num_bytes = try self.call(os.read, .{
            self.handle.inner,
            mem.asBytes(&counter),
        }, .{ .read = true });

        if (num_bytes != @sizeOf(@TypeOf(counter))) {
            return error.ShortRead;
        }
    }

    pub fn post(self: *Self) callconv(.Async) !void {
        try self.write(1);
        try self.read();
    }
};
