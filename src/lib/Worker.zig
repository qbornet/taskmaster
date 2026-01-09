const std = @import("std");

const Self = @This();
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
const Atomic = std.atomic.Value;
const pid_t = std.os.linux.pid_t;

allocator: Allocator,

should_stop: Atomic(bool),

thread: Thread,

thread_service: []const u8,


fn workerLoop(self: *Self, function: anytype, args: anytype) !void {
    while (!self.should_stop.load(.acquire)) {
        try @call(.auto, function, args);
        std.Thread.sleep(std.time.ns_per_s * 3);
    }
}

pub fn init(allocator: Allocator, service: []const u8, function: anytype, args: anytype) !*Self {
    const self = try allocator.create(Self);
    self.*.allocator = allocator;
    self.*.should_stop = Atomic(bool).init(false);
    self.*.thread_service = try allocator.dupe(u8, service);
    self.*.thread = try Thread.spawn(.{ .allocator = allocator }, workerLoop, .{ self, function, args });
    return self;
}

pub fn stop(self: *Self) void {
    self.should_stop.store(true, .release);
    self.thread.join();
}
pub fn deinit(self: *Self) void {
    if (!self.should_stop.load(.acquire)) self.stop();
    const allocator = self.*.allocator;
    allocator.free(self.*.thread_service);
    allocator.destroy(self);
}
