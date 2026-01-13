const std = @import("std");
const posix = std.posix;


allocator: std.mem.Allocator,
history: std.ArrayList([]const u8),
buffer: std.ArrayList(u8),
cursor_pos: usize,
history_index: usize, 
orig_termios: posix.termios,

const Self = @This();

pub fn init(allocator: std.mem.Allocator) !Self {
    const orig = try posix.tcgetattr(posix.STDIN_FILENO);

    return .{
        .allocator = allocator,
        .history = .empty,
        .buffer = .empty,
        .cursor_pos = 0,
        .history_index = 0,
        .orig_termios = orig,
    };
}

pub fn deinit(self: *Self) void {
    self.disableRawMode();
    for (0..self.history.items.len, self.history.items) |_, line| {
        self.allocator.free(line);
    }
    self.history.deinit(self.allocator);
    self.buffer.deinit(self.allocator);
}

/// Enable Raw Mode: Turn off echo and canonical mode (buffering)
fn enableRawMode(self: *Self) !void {
    var raw = self.orig_termios;
    raw.lflag.ECHO = false; // ECHO: Don't show characters automatically
    raw.lflag.ISIG = true; // ISIG: Disable Ctrl+C/Z signals (optional, usually kept on for shells)
    raw.lflag.ICANON = false; // ICANON: Disable buffering (read byte-by-byte)
    raw.lflag.IEXTEN = false; // IEXTEN: Stop Ctrl+V (literal processing) and other extension
    try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
}

fn disableRawMode(self: *Self) void {
    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, self.orig_termios) catch {};
}

/// The Main Loop will start reading line until you find a `\n` or `\r` or `EOF`.
pub fn readLine(self: *Self, prompt: []const u8) !?[]const u8 {
    try self.enableRawMode();
    defer self.disableRawMode();

    // Reset buffer for new line
    self.buffer.clearRetainingCapacity();
    self.cursor_pos = 0;
    self.history_index = self.history.items.len; // Point to "new" empty line

    try self.refreshLine(prompt);

    var handled_escape = false;
    var buf: [2]u8 = undefined;
    const stdin_fs = std.fs.File.stdin();
    var input_wrapper = stdin_fs.reader(&buf);
    var stdin: *std.Io.Reader = &input_wrapper.interface;

    while (true) {
        try stdin.fill(1);
        if (stdin.buffer.len == 0) return null; // EOF

        const c = stdin.buffer[0];

        switch (c) {
            '\n', '\r' => { // Enter
                if (self.buffer.items.len > 0) {
                    const history_copy = try self.allocator.dupe(u8, self.buffer.items);
                    try self.history.append(self.allocator, history_copy);
                }
                const return_copy = try self.allocator.dupe(u8, self.buffer.items);
                std.debug.print("\r\n", .{}); // Move to next line visually
                return return_copy;
            },
            127 => { // Backspace
                if (self.cursor_pos > 0) {
                    _ = self.buffer.orderedRemove(self.cursor_pos - 1);
                    self.cursor_pos -= 1;
                    try self.refreshLine(prompt);
                }
            },
            '\x1b' => { // Arrows
                try self.handleEscape(stdin, prompt);
                handled_escape = true;
            },
            '\x15', '\x0C', '\x01', '\x05' => try self.handleControlCharacter(stdin, prompt), // Control Character
            else => { // Normal Character
                if (!std.ascii.isControl(c)) {
                    try self.buffer.insert(self.allocator, self.cursor_pos, c);
                    self.cursor_pos += 1;
                    try self.refreshLine(prompt);
                }
            },
        }
        if (handled_escape) {
            handled_escape = false;
            continue;
        }
        stdin.toss(1);
    }
}

fn handleControlCharacter(self: *Self, reader: *std.Io.Reader, prompt: []const u8) !void {
    const char = reader.buffer[0];
    switch (char) {
        '\x15' => {
            self.buffer.clearRetainingCapacity();
            self.cursor_pos = 0;
            try self.refreshLine(prompt);
        },
        '\x0C' => {
            self.buffer.clearRetainingCapacity();
            self.cursor_pos = 0;
            try self.clearLine(prompt);
            try self.refreshLine(prompt);
        },
        '\x01' => {
            self.cursor_pos = 0;
            try self.refreshLine(prompt);
        },
        '\x05' => {
            self.cursor_pos = self.buffer.items.len;
            try self.refreshLine(prompt);
        },
        else => std.debug.print("need to handle ctrl '{x}'\n", .{char}),
    }
}

fn handleEscape(self: *Self, reader: *std.Io.Reader, prompt: []const u8) !void {
    // Read next 2 bytes: [ and A/B/C/D
    reader.toss(1);
    try reader.fill(2);
    if (reader.buffer.len != 2) return;
    const seq = reader.buffer;

    // Arrow escape seqence
    if (seq[0] == '[') {
        switch (seq[1]) {
            'A' => { // Up Arrow (Prev History)
                if (self.history_index > 0) {
                    self.history_index -= 1;
                    try self.loadHistory();
                    try self.refreshLine(prompt);
                } else {
                    self.history_index = self.history.items.len;
                    try self.loadHistory();
                    try self.refreshLine(prompt);
                }
            },
            'B' => { // Down Arrow (Next History)
                if (self.history_index < self.history.items.len) {
                    self.history_index += 1;
                    try self.loadHistory();
                    try self.refreshLine(prompt);
                } else if (self.history.items.len != 0) {
                    self.history_index = self.history_index % self.history.items.len;
                    try self.loadHistory();
                    try self.refreshLine(prompt);
                }
            },
            'C' => { // Right Arrow
                if (self.cursor_pos < self.buffer.items.len) {
                    self.cursor_pos += 1;
                    try self.refreshLine(prompt);
                }
            },
            'D' => { // Left Arrow
                if (self.cursor_pos > 0) {
                    self.cursor_pos -= 1;
                    try self.refreshLine(prompt);
                }
            },
            else => {},
        }
    }
    reader.toss(2);
}

/// Fetch history line via history_index.
fn loadHistory(self: *Self) !void {
    self.buffer.clearRetainingCapacity();
    if (self.history_index < self.history.items.len) {
        const item = self.history.items[self.history_index];
        try self.buffer.appendSlice(self.allocator, item);
    }
    self.cursor_pos = self.buffer.items.len; // Move cursor to end
}

/// Clear all screen line. reset prompt at top
fn clearLine(self: *Self, prompt: []const u8) !void {
    var buf: [65535]u8 = undefined;
    const stdout_fs = std.fs.File.stdout();
    var writer_stdout = stdout_fs.writer(&buf);
    var writer: *std.Io.Writer = &writer_stdout.interface;

    try writer.writeByte('\r');
    try writer.print("\x1b[2J", .{}); // Clear line
    try writer.print("\x1b[2H", .{}); // Move cursor to the top
    const absolute_col = prompt.len + self.cursor_pos + 1;
    try writer.print("\x1b[{d}G", .{absolute_col}); // Put cursor to proper position
    try writer.flush();
}

/// Redraws the entire line based on current state
fn refreshLine(self: *Self, prompt: []const u8) !void {
    var buf: [65535]u8 = undefined;
    const stdout_fs = std.fs.File.stdout();
    var writer_stdout = stdout_fs.writer(&buf);
    var writer: *std.Io.Writer = &writer_stdout.interface;

    try writer.writeByte('\r'); // Move cursor to the begining.
    try writer.print("\x1b[2K", .{}); // Clear line
    try writer.print("{s}{s}", .{ prompt, self.buffer.items });

    // \x1b[<N>G moves to absolute column N (1-based)
    const absolute_col = prompt.len + self.cursor_pos + 1;
    try writer.print("\x1b[{d}G", .{absolute_col});
    try writer.flush();
}
