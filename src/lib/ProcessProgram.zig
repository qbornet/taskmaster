// This is a struct of type ProcessProgram
const std = @import("std");
const posix = std.posix;

const Program = @import("../parser/parser.zig").Program;
const Atomic = std.atomic.Value;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const Self = @This();

allocator: Allocator,

exited_pid_map: std.AutoArrayHashMap(posix.pid_t, bool),

mutex: *std.Thread.Mutex,

restarting: Atomic(bool),

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
    self.*.restarting = .init(true);
    self.*.mutex = try allocator.create(std.Thread.Mutex);
    return self;
}

/// return `process_list` resources need to use mutex for using `process_list`
pub fn getProcessList(self: *Self) std.ArrayList(posix.pid_t) {
    return self.*.process_list;
}

/// return size of process_list
pub fn getSizeProcessList(self: *Self) usize {
    return self.*.process_list.items.len;
}

/// Will add pid to the process_list and other this will only be done once the,
/// `starttimes` is passed if not will wait.
pub fn pidAdd(self: *Self, pid: posix.pid_t) !void {
    self.*.mutex.lock();
    defer self.*.mutex.unlock();
    const allocator = self.*.allocator;
    try self.*.exited_pid_map.put(pid, false);
    try self.*.process_list.append(allocator, pid);
}

/// Change the provided pid to the status of exited.
pub fn pidExit(self: *Self, pid: posix.pid_t) !void {
    self.*.mutex.lock();
    defer self.*.mutex.unlock();
    try self.*.exited_pid_map.put(pid, true);
}

/// Will remove pid from `exited_pid_map` this should be done when pid value is set to true.
pub fn pidMapRemove(self: *Self, pid: posix.pid_t) usize {
    self.*.mutex.lock();
    defer self.*.mutex.unlock();
    const ret = self.*.exited_pid_map.orderedRemove(pid);
    return if (ret) 1 else 0;
}

/// Will remove pid from `process_list` this remove individualy each pid or if array is passed multiple,
/// array should be sorted.
pub fn pidListRemove(self: *Self, opt_pid: ?usize, opt_pids: ?[]usize) void {
    self.*.mutex.lock();
    defer self.*.mutex.unlock();
    if (opt_pids) |pids| {
        self.*.process_list.orderedRemoveMany(pids);
    } else if (opt_pid) |pid| {
        _ = self.*.process_list.orderedRemove(pid);
    }
}

/// Return optional from pid if present value true if pid exited properly else false. 
pub fn pidCheck(self: *Self, pid: posix.pid_t) ?bool {
    self.*.mutex.lock();
    defer self.*.mutex.unlock();
    return self.*.exited_pid_map.get(pid);
}

/// Will set restarting atomic to false.
pub fn stopRestarting(self: *Self) void {
    self.restarting.store(false, .release);
}

/// Return value of atomic about restart, `false` mean no restart should be done,
/// `true` mean restart should be done.
pub fn getRestarting(self: *Self) bool {
    return self.*.restarting.load(.acquire);
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
