// This is a struct of type ProcessProgram
const std = @import("std");
const posix = std.posix;

const Program = @import("../parser/parser.zig").Program;
const Child = std.process.Child;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const Self = @This();

allocator: Allocator,

exited_pid_map: std.AutoArrayHashMap(posix.pid_t, bool),

mutex: *std.Thread.Mutex,

process_list: std.ArrayList(posix.pid_t),

program_name: []const u8,

/// Allocator is needed this struct is self managed.
pub fn init(allocator: Allocator, name: []const u8) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.*.allocator = allocator;
    self.*.process_list = .empty;
    self.*.exited_pid_map = .init(allocator);
    self.*.program_name = try allocator.dupe(u8, name);
    self.*.mutex = try allocator.create(std.Thread.Mutex);
    return self;
}

/// return true if process id exited the program properly false if not properly exited.
pub fn getExitedPid(self: *Self, pid: posix.pid_t) bool {
    self.*.mutex.lock();
    defer self.*.mutex.unlock();
    var exited_pid = self.*.exited_pid_map;
    const opt_val = exited_pid.get(pid);
    return if (opt_val != null and opt_val.?) true else false;
}

/// remove all the pid for underlying data structures such as process_list and exited_pid_map
pub fn removePid(self: *Self, pid: posix.pid_t, index_pid: usize) void {
    self.*.mutex.lock();
    defer self.*.mutex.unlock();
    var process_list = self.*.process_list;
    var exited_pid_map = self.*.exited_pid_map;

    _ = process_list.orderedRemove(index_pid);
    _ = exited_pid_map.orderedRemove(pid);
}

pub fn getProcessListItems(self: *Self) []Child.Id {
    self.*.mutex.lock();
    defer self.*.mutex.unlock();
    return self.*.process_list.items;
}

pub fn getSizeProcessList(self: *Self) usize {
    self.*.mutex.lock();
    defer self.*.mutex.unlock();
    return self.*.process_list.items.len;
}

pub fn pidAdd(self: *Self, pid: posix.pid_t) !void {
    self.*.mutex.lock();
    defer self.*.mutex.unlock();
    const allocator = self.*.allocator;

    try self.*.exited_pid_map.put(pid, false);
    try self.*.process_list.append(allocator, pid);
}

pub fn deinit(self: *Self) void {
    self.*.mutex.lock();
    const allocator = self.*.allocator;

    var process_list = self.*.process_list;
    var exit_pid_map = self.*.exited_pid_map;

    // call deinit on each structure only child_map need to free the content.
    exit_pid_map.deinit();
    process_list.deinit(allocator);
    allocator.free(self.*.program_name);
    self.*.mutex.unlock();
    allocator.destroy(self.*.mutex);
    allocator.destroy(self);
}
