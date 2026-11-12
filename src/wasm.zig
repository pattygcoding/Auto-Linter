//! WebAssembly bridge.
//!
//! `wasm-bindgen` is deliberately not used: the module exports three plain
//! functions, so building is just `zig build` with no extra tooling and no
//! version pairing between a package manager and a generator. `formatter.js` is
//! the JavaScript half of the bridge.
//!
//! The host writes the two strings into memory it obtains from [`alloc`], calls
//! [`format_input`], and reads the answer out of the buffer that call returns. The
//! answer buffer stays owned by the module and is reused by the next call, so the
//! host must copy what it needs before formatting again.

const std = @import("std");
const root = @import("root.zig");

const allocator = std.heap.wasm_allocator;

/// The most recent result: four little-endian length bytes followed by UTF-8.
var result: std.ArrayList(u8) = .empty;

/// Returned only when the result buffer itself cannot be allocated; the host reads
/// a length of zero from it.
var empty_result = [4]u8{ 0, 0, 0, 0 };

/// Reserves `length` bytes for the host to write a string into.
export fn alloc(length: usize) ?[*]u8 {
    if (length == 0) return null;
    const buffer = allocator.alloc(u8, length) catch return null;
    return buffer.ptr;
}

/// Releases a buffer handed out by [`alloc`].
export fn dealloc(pointer: ?[*]u8, length: usize) void {
    const buffer = pointer orelse return;
    if (length == 0) return;
    allocator.free(buffer[0..length]);
}

/// Formats `input` with `mode` and returns a pointer to the result buffer.
///
/// The result is four little-endian length bytes followed by the formatted text,
/// or by an error message when the input was rejected. The pointer stays valid
/// until the next call.
export fn format_input(
    input_pointer: ?[*]const u8,
    input_length: usize,
    mode_pointer: ?[*]const u8,
    mode_length: usize,
) [*]const u8 {
    const input = sliceOrEmpty(input_pointer, input_length);
    const mode = sliceOrEmpty(mode_pointer, mode_length);

    const outcome = root.format(allocator, input, mode) catch return storeResult("out of memory");
    defer outcome.deinit(allocator);
    return switch (outcome) {
        .formatted => |formatted| storeResult(formatted.text),
        .rejected => |message| storeResult(message),
    };
}

fn sliceOrEmpty(pointer: ?[*]const u8, length: usize) []const u8 {
    const start = pointer orelse return "";
    if (length == 0) return "";
    return start[0..length];
}

fn storeResult(text: []const u8) [*]const u8 {
    result.clearRetainingCapacity();
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(text.len), .little);
    result.appendSlice(allocator, &header) catch return &empty_result;
    result.appendSlice(allocator, text) catch return &empty_result;
    return result.items.ptr;
}
