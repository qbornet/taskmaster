const std = @import("std");

const ExecutionResult = @import("../programs/execution.zig").ExecutionResult;
pub var execution_pool: std.ArrayList(ExecutionResult) = .empty;
