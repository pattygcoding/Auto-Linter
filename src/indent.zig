//! Indentation shared by the JSON and YAML writers.

const std = @import("std");

/// One indentation level used for both JSON and YAML output.
pub const INDENT = "    ";

/// Appends `columns` spaces to `output`.
pub fn pushSpaces(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    columns: usize,
) std.mem.Allocator.Error!void {
    var remaining = columns;
    while (remaining > 0) : (remaining -= 1) {
        try output.append(allocator, ' ');
    }
}
