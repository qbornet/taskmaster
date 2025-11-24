/// This is a struct type ProcessProgram

const std = @import("std");

const SpinLock = @import("SpinLock.zig");
const Child = std.process.Child; 
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const Self = @This();

allocator: Allocator,

child_map: std.StringArrayHashMap(*Child),

exited_pid_map: std.AutoArrayHashMap(Child.Id, bool),

lock: SpinLock,

process_list: std.ArrayList(Child.Id),

pub fn init(allocator: Allocator) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.*.allocator = allocator;
    self.*.process_list = .empty;
    self.*.exited_pid_map = .init(allocator);
    self.*.child_map = .init(allocator);
    self.*.lock = .{};
}

pub fn deinit(self: *Self) void {
    const lock = self.*.lock;
    const allocator = self.*.allocator;
    defer allocator.destroy(self);
    lock.lock();

    const process_list = self.*.process_list;
    const child_map = self.*.child_map;
    const exit_pid_map = self.*.exited_pid_map;

    var iter_child_map = child_map.iterator();
    while (iter_child_map.next()) |value| {
        allocator.destroy(value.value_ptr.*);
    }

    // call deinit on each structure only child_map need to free the content.
    child_map.deinit();
    exit_pid_map.deinit();
    process_list.deinit();
    lock.unlock();
}
