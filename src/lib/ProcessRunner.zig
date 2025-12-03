// This is a struct of type ProcessRunner
const std = @import("std");
const posix = std.posix;
const fmt = std.fmt;

const Allocator = std.mem.Allocator;
const Program = @import("../parser/parser.zig").Program;
const Self = @This();

allocator: Allocator,

mutex: std.Thread.Mutex,

stdout_file: std.fs.File,
stdout_path: []const u8,

stderr_file: std.fs.File,
stderr_path: []const u8,


/// Create ProcessRunner struct
pub fn init(allocator: Allocator, stdout_path: []const u8, stderr_path: []const u8) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.*.allocator = allocator;
    self.*.mutex = .{};
    self.*.stdout_path = try allocator.dupe(u8, stdout_path);
    self.*.stderr_path = try allocator.dupe(u8, stderr_path);
    return self;
}

/// Allocate resources need to the return resources.
fn parseExitCodes(self: *Self, exitcodes: []const u8) ![]u16 {
    var size: usize = 0;
    var iter = std.mem.splitScalar(u8, exitcodes, ',');
    while (iter.next()) : (size +=1) {}
    iter.reset();

    const allocator = self.*.allocator;
    var exitcode_result = try allocator.alloc(u16, size);
    errdefer allocator.free(exitcode_result);
    for (0..size, iter.next()) |i, line|{
        exitcode_result[i] = try fmt.parseInt(u16, line, 10);
    }
    return exitcode_result;
}

fn fileExistStdout(self: *Self) !bool {
    self.*.stdout_file = std.fs.createFileAbsolute(self.*.stdout_path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            std.debug.print("error: '{s}' log file already exist\n", .{self.*.stderr_path});
            return true;
        },
        else => return err,
    };
    return false;
}

fn fileExistStderr(self: *Self) !bool {
    self.*.stderr_file = std.fs.createFileAbsolute(self.*.stderr_path, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {
            std.debug.print("error: '{s}' log file already exist\n", .{self.*.stderr_path});
            return true;
        },
        else => return err,
    };
    return false;
}

/// start execution of command and return pid.
pub fn start(self: *Self,  program: *Program, exec: []const []const u8) !posix.pid_t {
    const allocator = self.*.allocator;
    const mutex = self.*.mutex;

    const envp = std.os.environ;
    const argv = try allocator.allocSentinel(?[*:0]const u8, exec.len, null);
    defer allocator.free(argv);
    for (0..exec.len, exec) |i, line| argv[i] = try allocator.dupeZ(u8, line);
    defer for (exec) |line| {
        allocator.free(line);
    };

    const old_umask = std.c.umask(program.umask);
    defer _ = std.c.umask(old_umask);

    const pid = try posix.fork();
    if (pid == 0) {
        // we are the child
        mutex.lock();
        if (self.fileExistStderr()) self.*.stderr_file = try std.fs.openFileAbsolute(self.*.stderr_path, .{ .mode = .write_only });
        if (self.fileExistStdout()) self.*.stdout_file = try std.fs.openFileAbsolute(self.*.stdout_path, .{ .mode = .write_only });
        mutex.unlock();
        try posix.dup2(self.*.stdout_file.handle, posix.STDOUT_FILENO);
        try posix.dup2(self.*.stderr_file.handle, posix.STDERR_FILENO);

        posix.close(self.*.stdout_file.handle);
        posix.close(self.*.stderr_file.handle);

        try posix.chdir(program.workingdir);


        const err = posix.execvpeZ(argv[0].?, argv, envp);
        if (err) {
            std.debug.print("error: '{s}'\n", .{@errorName(err)});
        }
        posix.exit(0);
    } 
    // we are the parent

    // here we return the pid the wait function is done by the thread,
    // for each program run by taskmaster. 
    // Why ? Because each thread are here to maintain the numprocs provided in config,
    // thus making them important to call for wait to check if process death is unexpected or not.
    return pid;
}

/// Destroy ProcessRunner struct `release` all allocated resources
pub fn deinit(self: *Self) void {
    const allocator = self.*.allocator;
    allocator.free(self.*.stdout_path);
    allocator.free(self.*.stderr_path);
    allocator.destroy(self);
    self.* = undefined;
}
