const std = @import("std");

const Self = @This();
const Allocator = std.mem.Allocator;
const Thread =  std.Thread;
const Mutex = std.Thread.Mutex;
const Atomic = std.atomic.Value;


allocator: Allocator,

mutex: Mutex,

thread: Thread,

should_stop: Atomic(bool),

fn workerLoop(self: *Self, function: anytype, args: anytype) !void {
    while (!self.should_stop.load(.acquire)) {
        try @call(.auto, function, args);
    }
    std.debug.print("Thread stop\n", .{});
}

pub fn init(allocator: Allocator, function: anytype, args: anytype) !*Self {
    const self = try allocator.create(Self);
    self.*.allocator = allocator;
    self.*.should_stop = Atomic(bool).init(false);
    self.*.mutex = .{};
    self.*.thread = try Thread.spawn(.{ .allocator = allocator }, workerLoop, .{self, function, args});
    return self;
}

pub fn stop(self: *Self) void {
    self.should_stop.store(true, .release);
    self.thread.join();
}

pub fn deinit(self: *Self) void {
    const allocator = self.*.allocator;
    allocator.destroy(self);
}
