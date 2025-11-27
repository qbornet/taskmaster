// This is a struct of type ProcessProgram
const std = @import("std");

const Program = @import("../parser/parser.zig").Program;
const Child = std.process.Child;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const Self = @This();

allocator: Allocator,

child_map: std.StringArrayHashMap(std.ArrayList(*Child)),

exited_pid_map: std.AutoArrayHashMap(Child.Id, bool),

lock: *std.Thread.Mutex,

process_list: std.ArrayList(Child.Id),

program_name: []const u8,

/// return true if process id exited the program properly false if not properly exited.
pub fn getExitedPid(self: *Self, pid: Child.Id) bool {
    self.*.lock.lock();
    defer self.*.lock.unlock();
    var exited_pid = self.*.exited_pid_map;
    const opt_val = exited_pid.get(pid);
    return if (opt_val != null and opt_val.?) true else false;
}

/// remove all the pid for underlying data structures such as process_list and exited_pid_map
pub fn removePid(self: *Self, pid: Child.Id, index_pid: usize) void {
    self.*.lock.lock();
    defer self.*.lock.unlock();
    var process_list = self.*.process_list;
    var exited_pid_map = self.*.exited_pid_map;

    _ = process_list.orderedRemove(index_pid);
    _ = exited_pid_map.orderedRemove(pid);
}

pub fn getProcessListItems(self: *Self) []Child.Id {
    self.*.lock.lock();
    defer self.*.lock.unlock();
    return self.*.process_list.items;
}

pub fn getSizeProcessList(self: *Self) usize {
    self.*.lock.lock();
    defer self.*.lock.unlock();
    return self.*.process_list.items.len;
}

pub fn pidAdd(self: *Self, pid: Child.Id) !void {
    const lock = self.*.lock;
    lock.lock();
    const allocator = self.*.allocator;

    try self.*.exited_pid_map.put(pid, false);
    try self.*.process_list.append(allocator, pid);
    lock.unlock();
}

pub fn childAdd(self: *Self, child: *Child) !void {
    const lock = self.*.lock;
    lock.lock();
    defer lock.unlock();
    const allocator = self.*.allocator;
    const name = self.*.program_name;
    var child_map = self.*.child_map;

    const opt_childs = child_map.get(name);
    if (opt_childs == null) {
        var child_list: std.ArrayList(*Child) = .empty;
        try child_list.append(allocator, child);
        try child_map.put(name, child_list);
    } else {
        var childs = opt_childs.?;
        try childs.append(allocator, child);
        try child_map.put(name, childs);
    }
}

pub fn init(allocator: Allocator, name: []const u8) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.*.allocator = allocator;
    self.*.process_list = .empty;
    self.*.exited_pid_map = .init(allocator);
    self.*.child_map = .init(allocator);
    self.*.program_name = try allocator.dupe(u8, name);
    self.*.lock = try allocator.create(std.Thread.Mutex);
    return self;
}

pub fn deinit(self: *Self) void {
    const lock = self.*.lock;
    const allocator = self.*.allocator;
    defer allocator.destroy(self);
    lock.lock();
    defer allocator.destroy(lock);

    var process_list = self.*.process_list;
    var child_map = self.*.child_map;
    var exit_pid_map = self.*.exited_pid_map;

    var iter_child_map = child_map.iterator();
    while (iter_child_map.next()) |value| {
        value.value_ptr.deinit(allocator);
        allocator.destroy(value.value_ptr);
    }

    // call deinit on each structure only child_map need to free the content.
    child_map.deinit();
    exit_pid_map.deinit();
    process_list.deinit(allocator);
    allocator.free(self.*.program_name);
    lock.unlock();
}
