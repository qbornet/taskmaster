/// This is a struct type SpinLock
/// faster lock then mutex.

const std = @import("std");

const Thread = std.Thread;
const Self = @This();
const State = enum(u8) { Unlocked = 0, Locked };
const AtomicState = std.atomic.Value(State);

value: AtomicState = AtomicState.init(.Unlocked),

pub fn lock(self: *Self) void {
    while (true) {
        switch(self.value.swap(.Locked, .acquire)) {
            .Locked => {},
            .Unlocked => break,
        }
    }
}

pub fn tryLock(self: *Self) bool {
    return switch (self.value.swap(.Locked, .acquire)) {
        .Locked => return false,
        .Unlocked => return true,
    };
}

pub fn unlock(self: *Self) bool {
    self.value.store(.Unlocked, .release);
}
