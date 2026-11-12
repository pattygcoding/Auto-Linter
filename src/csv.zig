//! CSV and TSV validation and formatting.
//!
//! Records are parsed with RFC 4180 quoting rules and re-emitted with one field
//! per delimiter and one record per line: fields that do not need quoting lose
//! their quotes, fields that do need them keep RFC-compatible `""` escapes, line
//! endings become LF, and every record ends with a newline. The text of every
//! field is preserved, including leading and trailing spaces.

const std = @import("std");
const diagnostic = @import("diagnostic.zig");

const Allocator = std.mem.Allocator;
const Error = diagnostic.Error;

/// The field separator to use.
pub const Delimiter = enum {
    comma,
    tab,

    fn byte(self: Delimiter) u8 {
        return switch (self) {
            .comma => ',',
            .tab => '\t',
        };
    }
};

/// Validates `input` as delimited text and re-emits it with normalised quoting.
pub fn format(
    allocator: Allocator,
    input: []const u8,
    diag: ?*diagnostic.Diagnostic,
    delimiter: Delimiter,
) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var parser = Parser{
        .input = input,
        .separator = delimiter.byte(),
        .diagnostic = diag,
    };
    var field = Field{ .allocator = allocator };
    defer field.buffer.deinit(allocator);

    while (parser.position < parser.input.len) {
        var first = true;
        while (true) {
            if (!first) try output.append(allocator, parser.separator);
            const text = try parser.parseField(&field);
            try writeField(&output, allocator, text, parser.separator);
            first = false;
            if (parser.finishField()) break;
        }
        try output.append(allocator, '\n');
    }
    return try output.toOwnedSlice(allocator);
}

/// Reusable buffer for the unescaped text of one quoted field.
const Field = struct {
    allocator: Allocator,
    buffer: std.ArrayList(u8) = .empty,
};

const Parser = struct {
    input: []const u8,
    separator: u8,
    position: usize = 0,
    diagnostic: ?*diagnostic.Diagnostic = null,

    fn fail(self: *Parser, comptime format_string: []const u8, args: anytype) Error {
        return diagnostic.fail(self.diagnostic, format_string, args);
    }

    /// Parses one field. Quoted fields are unescaped into `field.buffer`; the
    /// returned slice is only valid until the next call.
    fn parseField(self: *Parser, field: *Field) Error![]const u8 {
        const input = self.input;
        if (self.position >= input.len) return "";
        if (input[self.position] != '"') {
            const start = self.position;
            while (self.position < input.len) {
                const byte = input[self.position];
                if (byte == self.separator or byte == '\r' or byte == '\n') break;
                if (byte == '"') {
                    return self.fail("unexpected quote in an unquoted field at offset {d}", .{self.position});
                }
                self.position += 1;
            }
            return input[start..self.position];
        }

        field.buffer.clearRetainingCapacity();
        self.position += 1;
        while (true) {
            if (self.position >= input.len) {
                return self.fail("unterminated quoted field at offset {d}", .{self.position});
            }
            const byte = input[self.position];
            if (byte == '"') {
                if (self.position + 1 < input.len and input[self.position + 1] == '"') {
                    try field.buffer.append(field.allocator, '"');
                    self.position += 2;
                    continue;
                }
                self.position += 1;
                break;
            }
            try field.buffer.append(field.allocator, byte);
            self.position += 1;
        }

        if (self.position < input.len) {
            const byte = input[self.position];
            if (byte != self.separator and byte != '\r' and byte != '\n') {
                return self.fail("unexpected character 0x{x:0>2} after a closing quote at offset {d}", .{
                    byte,
                    self.position,
                });
            }
        }
        return field.buffer.items;
    }

    /// Consumes the delimiter or record terminator that follows a field and
    /// reports whether the record ended.
    fn finishField(self: *Parser) bool {
        if (self.position >= self.input.len) return true;
        switch (self.input[self.position]) {
            '\r' => {
                self.position += 1;
                if (self.position < self.input.len and self.input[self.position] == '\n') self.position += 1;
                return true;
            },
            '\n' => {
                self.position += 1;
                return true;
            },
            else => {
                self.position += 1;
                return false;
            },
        }
    }
};

fn fieldNeedsQuoting(text: []const u8, separator: u8) bool {
    if (text.len == 0) return false;
    if (text[0] == ' ' or text[0] == '\t') return true;
    if (text[text.len - 1] == ' ' or text[text.len - 1] == '\t') return true;
    for (text) |byte| {
        if (byte == separator or byte == '"' or byte == '\r' or byte == '\n') return true;
    }
    return false;
}

fn writeField(
    output: *std.ArrayList(u8),
    allocator: Allocator,
    text: []const u8,
    separator: u8,
) Allocator.Error!void {
    if (!fieldNeedsQuoting(text, separator)) {
        try output.appendSlice(allocator, text);
        return;
    }
    try output.append(allocator, '"');
    for (text) |byte| {
        if (byte == '"') try output.append(allocator, '"');
        try output.append(allocator, byte);
    }
    try output.append(allocator, '"');
}

fn formatText(input: []const u8, delimiter: Delimiter) ![]u8 {
    var diag = diagnostic.Diagnostic.init(std.testing.allocator);
    defer diag.deinit();
    return format(std.testing.allocator, input, &diag, delimiter) catch |err| switch (err) {
        error.Invalid => {
            std.debug.print("unexpected rejection of {s}: {s}\n", .{ input, diag.message });
            return error.UnexpectedRejection;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn rejectionMessage(input: []const u8, delimiter: Delimiter) ![]u8 {
    var diag = diagnostic.Diagnostic.init(std.testing.allocator);
    defer diag.deinit();
    if (format(std.testing.allocator, input, &diag, delimiter)) |text| {
        std.testing.allocator.free(text);
        return error.ExpectedRejection;
    } else |err| switch (err) {
        error.Invalid => return try std.testing.allocator.dupe(u8, diag.message),
        error.OutOfMemory => return error.OutOfMemory,
    }
}

fn expectFormat(input: []const u8, expected: []const u8, delimiter: Delimiter) !void {
    const once = try formatText(input, delimiter);
    defer std.testing.allocator.free(once);
    try std.testing.expectEqualStrings(expected, once);

    const twice = try formatText(once, delimiter);
    defer std.testing.allocator.free(twice);
    try std.testing.expectEqualStrings(once, twice);
}

test "normalises records quoting and line endings" {
    try expectFormat("a,b\nc,d\n", "a,b\nc,d\n", .comma);
    try expectFormat("a,b\r\nc,d\r\n", "a,b\nc,d\n", .comma);
    try expectFormat("\"a,b\",c\n", "\"a,b\",c\n", .comma);
    try expectFormat("\"He said \"\"hi\"\"\",1\n", "\"He said \"\"hi\"\"\",1\n", .comma);
    // Quotes that are not needed are dropped.
    try expectFormat("a,\"\"\n", "a,\n", .comma);
    try expectFormat("\"plain\"\n", "plain\n", .comma);
    // Leading and trailing spaces belong to the field, so they are quoted back.
    try expectFormat("a, spaced \n", "a,\" spaced \"\n", .comma);
    try expectFormat("a,b,", "a,b,\n", .comma);
}

test "keeps newlines that are inside quoted fields" {
    try expectFormat("\"line1\nline2\",x\n", "\"line1\nline2\",x\n", .comma);
    try expectFormat("\"\"\"quoted\"\"\"\n", "\"\"\"quoted\"\"\"\n", .comma);
}

test "supports tab separated values" {
    try expectFormat("a\tb\n", "a\tb\n", .tab);
    try expectFormat("a\t\"x\ty\"\n", "a\t\"x\ty\"\n", .tab);
    // A comma is ordinary data in a TSV file.
    try expectFormat("a,\tb\n", "a,\tb\n", .tab);
}

test "rejects malformed records" {
    for ([_][]const u8{ "\"unterminated", "\"a\"b\n", "a\"b\n", "\"\n" }) |input| {
        const message = try rejectionMessage(input, .comma);
        defer std.testing.allocator.free(message);
        try std.testing.expect(message.len > 0);
    }
}
