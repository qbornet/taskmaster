const std = @import("std");

const Self = @This();
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
const Atomic = std.atomic.Value;

allocator: Allocator,

mutex: Mutex,

thread: Thread,

thread_service: []const u8,

should_stop: Atomic(bool),

fn workerLoop(self: *Self, function: anytype, args: anytype) !void {
    while (!self.should_stop.load(.acquire)) {
        try @call(.auto, function, args);
        std.Thread.sleep(std.time.ns_per_s * 3);
        std.debug.print("service: '{s}' Thread working...\n", .{self.*.thread_service});
    }
    std.debug.print("Thread stop\n", .{});
}

pub fn init(allocator: Allocator, service: []const u8, function: anytype, args: anytype) !*Self {
    const self = try allocator.create(Self);
    self.*.allocator = allocator;
    self.*.should_stop = Atomic(bool).init(false);
    self.*.thread_service = try allocator.dupe(u8, service);
    self.*.mutex = .{};
    self.*.thread = try Thread.spawn(.{ .allocator = allocator }, workerLoop, .{ self, function, args });
    return self;
}

pub fn stop(self: *Self) void {
    self.should_stop.store(true, .release);
    const val = self.should_stop.load(.acquire);
    std.debug.print("should_stop: {} service: '{s}'\n", .{ val, self.*.thread_service });
    self.thread.join();
}

pub fn deinit(self: *Self) void {
    self.stop();
    const allocator = self.*.allocator;
    allocator.free(self.*.thread_service);
    allocator.destroy(self);
}
