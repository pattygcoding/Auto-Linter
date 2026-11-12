//! Shared rejection reporting.
//!
//! A parser either succeeds, fails because the document is invalid (`Invalid`,
//! with a human-readable message in the diagnostic), or fails because memory ran
//! out. Keeping the message in one place lets the validators stay free of error
//! string bookkeeping while still reporting the offset or line they stopped at.

const std = @import("std");

/// The only errors the formatters report.
pub const Error = error{ Invalid, OutOfMemory };

/// Records the first rejection reason as an owned message.
pub const Diagnostic = struct {
    allocator: std.mem.Allocator,
    /// Human-readable reason. Empty until `fail` is called.
    message: []const u8 = "",
    owned: bool = false,

    pub fn init(allocator: std.mem.Allocator) Diagnostic {
        return .{ .allocator = allocator };
    }

    /// Stores a formatted message and returns the `Invalid` error, so callers can
    /// write `return diagnostic.fail(...)`.
    pub fn fail(self: *Diagnostic, comptime format: []const u8, args: anytype) Error {
        if (self.owned) self.allocator.free(self.message);
        self.message = try std.fmt.allocPrint(self.allocator, format, args);
        self.owned = true;
        return error.Invalid;
    }

    pub fn deinit(self: *Diagnostic) void {
        if (self.owned) self.allocator.free(self.message);
        self.message = "";
        self.owned = false;
    }
};

/// Fails through an optional diagnostic.
///
/// Validation-only callers pass `null` and get the error without allocating a
/// message, which is what `json.isValid` does while auto-detecting.
pub fn fail(diagnostic: ?*Diagnostic, comptime format: []const u8, args: anytype) Error {
    if (diagnostic) |active| return active.fail(format, args);
    return error.Invalid;
}
