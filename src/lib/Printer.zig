// This is a struct of type Printer

const std = @import("std");
const fs = std.fs;
const posix = std.posix;

const Self = @This();
const Allocator = std.mem.Allocator;

const file_type = enum(u8) { Stdout, Stderr };

allocator: Allocator,

buff: [4096]u8,

file_fs: ?*fs.File,

file_writer_internal: fs.File.Writer,

file_printer: *std.Io.Writer,

std_fs: fs.File,

printer: *std.Io.Writer,

writer_internal: fs.File.Writer,

/// Need to provide allocator and free return resources,
/// `file` variable is enum for type of printer `.Stdout` or `.Stderr`.
/// `opt_file_reader` variable you can pass a file reader to write also in another file aswell as printing on the standard file that you choose.
pub fn init(allocator: Allocator, file: file_type, opt_file_fs: ?*fs.File) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.*.allocator = allocator;
    switch (file) {
        .Stdout => self.*.std_fs = .stdout(),
        .Stderr => self.*.std_fs = .stderr(),
    }
    self.*.writer_internal = self.*.std_fs.writer(&self.*.buff);
    self.*.printer = &self.*.writer_internal.interface;
    self.*.file_fs = if (opt_file_fs) |file_reader| file_reader else null;
    if (opt_file_fs) |file_reader| {
        try file_reader.seekFromEnd(0);
        self.*.file_writer_internal = file_reader.writer(&.{});
        self.*.file_printer = &self.*.file_writer_internal.interface;
    } else {
        self.*.file_writer_internal = undefined;
        self.*.file_printer = undefined;
    }
    return self;
}

/// Lock Standard file stream `.exclusive` meaning only one process as access.
fn lockStd(self: *Self) !void {
    try self.*.std_fs.lock(.exclusive);
}

/// Unlock Standard file stream `.exclusive` now other process can access.
fn unlockStd(self: *Self) void {
    self.*.std_fs.unlock();
}

/// Lock file `.exclusive` meaning only one process as access.
fn lockFile(self: *Self) !void {
    if (self.*.file_fs) |file| {
        file.lock(.exclusive);
    }
    return error.NoFileFound;
}

/// Unlock file `.exclusive` now other process can access.
fn unlockFile(self: *Self) void {
    if (self.*.file_fs) |file| {
        file.unlock();
    }
}

/// Update file writer, get exclusive lock and change position to the end of file.
fn updateFileWriter(self: *Self) !void {
    if (self.*.file_fs == null) return error.NoFileFound;
    
    try self.lockFile();
    defer self.unlockFile();
    const file = self.*.file_fs.?;
    try file.seekFromEnd(0);
    self.*.file_writer_internal = file.writer(&.{});
    self.*.file_printer = &self.*.file_writer_internal.interface;
}

/// Will use format print string, and call `flush()` to make it print.
/// if at `init()` a file reader was provided will also print to the file.
pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) !void {
    try self.*.std_fs.lock(.exclusive);
    defer self.*.std_fs.unlock();

    const printer = self.*.printer;
    try printer.print(fmt, args);
    try printer.defaultFlush();

    if (self.*.file_fs) |file| {
        try file.seekFromEnd(0);
        try self.*.file_printer.print(fmt, args);
        try self.*.file_printer.defaultFlush();
    }
}

/// Will print only inside file
pub fn printFile(self: *Self, comptime fmt: []const u8, args: anytype) !void {
    if (self.*.file_fs) |_| {
        try self.*.file_printer.print(fmt, args);
        try self.*.file_printer.flush();
    }
}

/// Deinit the allocated resources and close the standard file.
pub fn deinit(self: *Self) void {
    const allocator = self.*.allocator;
    allocator.destroy(self);
}
