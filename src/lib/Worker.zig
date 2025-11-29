const std = @import("std");

const Self = @This();
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
const Atomic = std.atomic.Value;
const pid_t = std.os.linux.pid_t;

allocator: Allocator,

mutex: Mutex,

pid_list: std.ArrayList(std.os.linux.pid_t),

should_stop: Atomic(bool),

thread: Thread,

thread_service: []const u8,


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
    self.*.pid_list = .empty;
    return self;
}

pub fn stop(self: *Self) void {
    self.should_stop.store(true, .release);
    const val = self.should_stop.load(.acquire);
    std.debug.print("should_stop: {} service: '{s}'\n", .{ val, self.*.thread_service });
    self.thread.join();
}

/// Append a pid to the `pid_list` (thread_safe).
pub fn addPidToList(self: *Self, pid: pid_t) !void {
    self.*.mutex.lock();
    defer self.*.mutex.unlock();
    try self.*.pid_list.append(self.*.allocator, pid);
}

/// return an allocated slice of all the pid link to the thread,
/// the caller need to free the resources.
pub fn slicePidList(self: *Self) ![]pid_t {
    self.*.mutex.lock();
    defer self.*.mutex.lock();
    return try self.*.pid_list.toOwnedSlice(self.*.allocator);
}

pub fn deinit(self: *Self) void {
    self.stop();
    const allocator = self.*.allocator;
    allocator.free(self.*.thread_service);
    allocator.destroy(self);
}
