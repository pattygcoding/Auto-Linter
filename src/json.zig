//! Strict JSON validation and four-space indentation.
//!
//! This mirrors the implementation the project used before the move to Zig
//! (`encoding/json.Valid` plus `encoding/json.Indent` with a four-space indent):
//! insignificant whitespace is dropped, every member of an object or array starts
//! on its own line, empty objects and arrays stay inline, and every other byte is
//! copied through untouched. Key order, numeric precision and existing string
//! escapes therefore survive formatting.

const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const indent_module = @import("indent.zig");

const Allocator = std.mem.Allocator;
const Error = diagnostic.Error;
const INDENT = indent_module.INDENT;

const Container = enum { object, array };

/// What the scanner expects to read next.
const State = enum {
    /// A value: at the start of the document, an array element, or after `:`.
    value,
    /// A value or `]`, immediately after `[`.
    value_or_close,
    /// An object key string.
    key,
    /// An object key string or `}`, immediately after `{`.
    key_or_close,
    /// The `:` separating an object key from its value.
    colon,
    /// A `,` or the closing bracket of the current container.
    after_value,
    /// The single top-level value is complete; only whitespace may follow.
    top,
};

const Token = union(enum) {
    open: u8,
    close: u8,
    comma,
    colon,
    scalar: []const u8,
};

/// Reports whether `input` is exactly one complete JSON value.
pub fn isValid(allocator: Allocator, input: []const u8) Allocator.Error!bool {
    var scanner = Scanner{ .allocator = allocator, .input = input };
    defer scanner.deinit();
    scanner.run() catch |err| switch (err) {
        error.Invalid => return false,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return true;
}

/// Re-indents `input` with four spaces per level, or reports why it is not JSON.
pub fn indent(allocator: Allocator, input: []const u8, diag: ?*diagnostic.Diagnostic) Error![]u8 {
    var emitter = Emitter.init(allocator);
    errdefer emitter.text.deinit(allocator);
    var scanner = Scanner{
        .allocator = allocator,
        .input = input,
        .emitter = &emitter,
        .diagnostic = diag,
    };
    defer scanner.deinit();
    try scanner.run();
    return try emitter.text.toOwnedSlice(allocator);
}

const Scanner = struct {
    allocator: Allocator,
    input: []const u8,
    position: usize = 0,
    state: State = .value,
    stack: std.ArrayList(Container) = .empty,
    emitter: ?*Emitter = null,
    diagnostic: ?*diagnostic.Diagnostic = null,

    fn deinit(self: *Scanner) void {
        self.stack.deinit(self.allocator);
    }

    fn fail(self: *Scanner, comptime format: []const u8, args: anytype) Error {
        return diagnostic.fail(self.diagnostic, format, args);
    }

    fn run(self: *Scanner) Error!void {
        const bytes = self.input;
        while (true) {
            if (self.state == .top) {
                // Whitespace after the top-level value is copied through verbatim.
                const start = self.position;
                while (self.position < bytes.len and isSpace(bytes[self.position])) self.position += 1;
                if (self.position < bytes.len) {
                    var buffer: [8]u8 = undefined;
                    return self.fail("invalid character {s} after top-level value at offset {d}", .{
                        quotedCharacter(&buffer, bytes[self.position]),
                        self.position,
                    });
                }
                if (self.emitter) |emitter| try emitter.raw(self.input[start..self.position]);
                return;
            }

            while (self.position < bytes.len and isSpace(bytes[self.position])) self.position += 1;
            if (self.position >= bytes.len) return self.fail("unexpected end of JSON input", .{});

            const token = try self.nextToken();
            if (self.emitter) |emitter| {
                switch (token) {
                    .open => |character| try emitter.open(character),
                    .close => |character| try emitter.close(character),
                    .comma => try emitter.comma(),
                    .colon => try emitter.colon(),
                    .scalar => |raw| try emitter.scalar(raw),
                }
            }
        }
    }

    fn nextToken(self: *Scanner) Error!Token {
        const byte = self.input[self.position];
        switch (self.state) {
            .value, .value_or_close => {
                if (byte == ']' and self.state == .value_or_close) return self.closeContainer(']');
                return self.parseValue();
            },
            .key, .key_or_close => {
                if (byte == '}' and self.state == .key_or_close) return self.closeContainer('}');
                if (byte != '"') {
                    var buffer: [8]u8 = undefined;
                    return self.fail(
                        "invalid character {s} looking for beginning of object key string at offset {d}",
                        .{ quotedCharacter(&buffer, byte), self.position },
                    );
                }
                const raw = try self.parseString();
                self.state = .colon;
                return .{ .scalar = raw };
            },
            .colon => {
                if (byte != ':') {
                    var buffer: [8]u8 = undefined;
                    return self.fail("invalid character {s} after object key at offset {d}", .{
                        quotedCharacter(&buffer, byte),
                        self.position,
                    });
                }
                self.position += 1;
                self.state = .value;
                return .colon;
            },
            .after_value => {
                const container: ?Container = if (self.stack.items.len > 0)
                    self.stack.items[self.stack.items.len - 1]
                else
                    null;
                const in_object = if (container) |value| value == .object else false;

                if (byte == ',') {
                    self.position += 1;
                    self.state = if (in_object) .key else .value;
                    return .comma;
                }
                if (byte == '}' and in_object) return self.closeContainer('}');
                if (byte == ']' and !in_object) return self.closeContainer(']');

                var buffer: [8]u8 = undefined;
                return self.fail("invalid character {s} {s} at offset {d}", .{
                    quotedCharacter(&buffer, byte),
                    if (in_object) "after object key:value pair" else "after array element",
                    self.position,
                });
            },
            .top => return self.fail("unexpected end of JSON input", .{}),
        }
    }
    fn parseValue(self: *Scanner) Error!Token {
        const byte = self.input[self.position];
        const token: Token = switch (byte) {
            '{' => {
                try self.stack.append(self.allocator, .object);
                self.position += 1;
                self.state = .key_or_close;
                return .{ .open = '{' };
            },
            '[' => {
                try self.stack.append(self.allocator, .array);
                self.position += 1;
                self.state = .value_or_close;
                return .{ .open = '[' };
            },
            '"' => .{ .scalar = try self.parseString() },
            't' => .{ .scalar = try self.parseLiteral("true") },
            'f' => .{ .scalar = try self.parseLiteral("false") },
            'n' => .{ .scalar = try self.parseLiteral("null") },
            '-', '0'...'9' => .{ .scalar = try self.parseNumber() },
            else => {
                var buffer: [8]u8 = undefined;
                return self.fail("invalid character {s} looking for beginning of value at offset {d}", .{
                    quotedCharacter(&buffer, byte),
                    self.position,
                });
            },
        };
        self.state = if (self.stack.items.len == 0) .top else .after_value;
        return token;
    }

    fn closeContainer(self: *Scanner, closing: u8) Error!Token {
        const expected: Container = if (closing == '}') .object else .array;
        const actual = self.stack.pop();
        if (actual == null or actual.? != expected) {
            var buffer: [8]u8 = undefined;
            return self.fail("invalid character {s} after top-level value at offset {d}", .{
                quotedCharacter(&buffer, self.input[self.position]),
                self.position,
            });
        }
        self.position += 1;
        self.state = if (self.stack.items.len == 0) .top else .after_value;
        return .{ .close = closing };
    }

    fn parseString(self: *Scanner) Error![]const u8 {
        const bytes = self.input;
        const start = self.position;
        self.position += 1;
        while (self.position < bytes.len) {
            const byte = bytes[self.position];
            switch (byte) {
                '"' => {
                    self.position += 1;
                    return bytes[start..self.position];
                },
                '\\' => {
                    self.position += 1;
                    if (self.position >= bytes.len) return self.fail("unexpected end of JSON input", .{});
                    const escape = bytes[self.position];
                    switch (escape) {
                        '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => self.position += 1,
                        'u' => {
                            self.position += 1;
                            var digit_index: usize = 0;
                            while (digit_index < 4) : (digit_index += 1) {
                                if (self.position >= bytes.len) {
                                    return self.fail("unexpected end of JSON input", .{});
                                }
                                const digit = bytes[self.position];
                                if (!std.ascii.isHex(digit)) {
                                    var buffer: [8]u8 = undefined;
                                    return self.fail(
                                        "invalid character {s} in \\u hexadecimal character escape at offset {d}",
                                        .{ quotedCharacter(&buffer, digit), self.position },
                                    );
                                }
                                self.position += 1;
                            }
                        },
                        else => {
                            var buffer: [8]u8 = undefined;
                            return self.fail("invalid character {s} in string escape code at offset {d}", .{
                                quotedCharacter(&buffer, escape),
                                self.position,
                            });
                        },
                    }
                },
                else => {
                    if (byte < 0x20) {
                        var buffer: [8]u8 = undefined;
                        return self.fail("invalid character {s} in string literal at offset {d}", .{
                            quotedCharacter(&buffer, byte),
                            self.position,
                        });
                    }
                    self.position += 1;
                },
            }
        }
        return self.fail("unexpected end of JSON input", .{});
    }

    fn parseLiteral(self: *Scanner, literal: []const u8) Error![]const u8 {
        const bytes = self.input;
        for (literal, 0..) |expected, offset| {
            const index = self.position + offset;
            if (index >= bytes.len) return self.fail("unexpected end of JSON input", .{});
            const actual = bytes[index];
            if (actual != expected) {
                var actual_buffer: [8]u8 = undefined;
                var expected_buffer: [8]u8 = undefined;
                return self.fail("invalid character {s} in literal {s} (expecting {s}) at offset {d}", .{
                    quotedCharacter(&actual_buffer, actual),
                    literal,
                    quotedCharacter(&expected_buffer, expected),
                    index,
                });
            }
        }
        const start = self.position;
        self.position += literal.len;
        return bytes[start..self.position];
    }

    fn parseNumber(self: *Scanner) Error![]const u8 {
        const bytes = self.input;
        const start = self.position;
        if (bytes[self.position] == '-') self.position += 1;

        if (self.position >= bytes.len) return self.fail("unexpected end of JSON input", .{});
        const first = bytes[self.position];
        if (first == '0') {
            self.position += 1;
        } else if (first >= '1' and first <= '9') {
            while (self.position < bytes.len and std.ascii.isDigit(bytes[self.position])) self.position += 1;
        } else {
            var buffer: [8]u8 = undefined;
            return self.fail("invalid character {s} in numeric literal at offset {d}", .{
                quotedCharacter(&buffer, first),
                self.position,
            });
        }

        if (self.position < bytes.len and bytes[self.position] == '.') {
            self.position += 1;
            const first_digit = self.position;
            while (self.position < bytes.len and std.ascii.isDigit(bytes[self.position])) self.position += 1;
            if (self.position == first_digit) {
                if (self.position >= bytes.len) return self.fail("unexpected end of JSON input", .{});
                var buffer: [8]u8 = undefined;
                return self.fail("invalid character {s} after decimal point in numeric literal at offset {d}", .{
                    quotedCharacter(&buffer, bytes[self.position]),
                    self.position,
                });
            }
        }

        if (self.position < bytes.len and (bytes[self.position] == 'e' or bytes[self.position] == 'E')) {
            self.position += 1;
            if (self.position < bytes.len and (bytes[self.position] == '+' or bytes[self.position] == '-')) {
                self.position += 1;
            }
            const first_digit = self.position;
            while (self.position < bytes.len and std.ascii.isDigit(bytes[self.position])) self.position += 1;
            if (self.position == first_digit) {
                if (self.position >= bytes.len) return self.fail("unexpected end of JSON input", .{});
                var buffer: [8]u8 = undefined;
                return self.fail("invalid character {s} in exponent of numeric literal at offset {d}", .{
                    quotedCharacter(&buffer, bytes[self.position]),
                    self.position,
                });
            }
        }

        return bytes[start..self.position];
    }
};

/// Mirrors `encoding/json.Indent`: whitespace between tokens is dropped, and a
/// newline plus one indent per nesting level is inserted before each member. The
/// indent is deferred until a token really arrives, which is what keeps `{}` and
/// `[]` on a single line.
const Emitter = struct {
    allocator: Allocator,
    text: std.ArrayList(u8) = .empty,
    pending_indent: bool = false,
    depth: usize = 0,

    fn init(allocator: Allocator) Emitter {
        return .{ .allocator = allocator };
    }

    fn append(self: *Emitter, bytes: []const u8) Allocator.Error!void {
        try self.text.appendSlice(self.allocator, bytes);
    }

    fn newline(self: *Emitter, depth: usize) Allocator.Error!void {
        try self.text.append(self.allocator, '\n');
        var level: usize = 0;
        while (level < depth) : (level += 1) {
            try self.append(INDENT);
        }
    }

    /// Runs before every token that opens or fills a container.
    fn beforeToken(self: *Emitter) Allocator.Error!void {
        if (self.pending_indent) {
            self.pending_indent = false;
            self.depth += 1;
            try self.newline(self.depth);
        }
    }

    fn open(self: *Emitter, character: u8) Allocator.Error!void {
        try self.beforeToken();
        try self.text.append(self.allocator, character);
        self.pending_indent = true;
    }

    fn close(self: *Emitter, character: u8) Allocator.Error!void {
        if (self.pending_indent) {
            self.pending_indent = false;
        } else {
            self.depth -|= 1;
            try self.newline(self.depth);
        }
        try self.text.append(self.allocator, character);
    }

    fn comma(self: *Emitter) Allocator.Error!void {
        try self.text.append(self.allocator, ',');
        try self.newline(self.depth);
    }

    fn colon(self: *Emitter) Allocator.Error!void {
        try self.append(": ");
    }

    fn scalar(self: *Emitter, text: []const u8) Allocator.Error!void {
        try self.beforeToken();
        try self.append(text);
    }

    fn raw(self: *Emitter, value: []const u8) Allocator.Error!void {
        try self.append(value);
    }
};

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

/// Renders a byte the way `encoding/json` reports it in scanner errors.
fn quotedCharacter(buffer: *[8]u8, byte: u8) []const u8 {
    return switch (byte) {
        '\'' => "'\\''",
        '"' => "'\"'",
        else => if (byte < 0x20)
            std.fmt.bufPrint(buffer, "'\\x{x:0>2}'", .{byte}) catch unreachable
        else blk: {
            buffer[0] = '\'';
            buffer[1] = byte;
            buffer[2] = '\'';
            break :blk buffer[0..3];
        },
    };
}

fn indentText(input: []const u8) ![]u8 {
    var diag = diagnostic.Diagnostic.init(std.testing.allocator);
    defer diag.deinit();
    return indent(std.testing.allocator, input, &diag) catch |err| switch (err) {
        error.Invalid => {
            std.debug.print("unexpected rejection of {s}: {s}\n", .{ input, diag.message });
            return error.UnexpectedRejection;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn indentError(input: []const u8) ![]u8 {
    var diag = diagnostic.Diagnostic.init(std.testing.allocator);
    defer diag.deinit();
    if (indent(std.testing.allocator, input, &diag)) |text| {
        std.testing.allocator.free(text);
        return error.ExpectedRejection;
    } else |err| switch (err) {
        error.Invalid => return try std.testing.allocator.dupe(u8, diag.message),
        error.OutOfMemory => return error.OutOfMemory,
    }
}

/// Inputs Go's `encoding/json` accepts, with the indentation this formatter must
/// produce for them.
const valid_cases = [_]struct { input: []const u8, expected: []const u8 }{
    .{ .input = "{}", .expected = "{}" },
    .{ .input = "[]", .expected = "[]" },
    .{ .input = "{\"a\":{}}", .expected = "{\n    \"a\": {}\n}" },
    .{ .input = "{\"a\":[]}", .expected = "{\n    \"a\": []\n}" },
    .{ .input = "{}   ", .expected = "{}   " },
    .{ .input = "[ ]", .expected = "[]" },
    .{ .input = "{ }", .expected = "{}" },
    .{ .input = "[\n]", .expected = "[]" },
    .{ .input = "{\n}", .expected = "{}" },
    .{ .input = "[ 1 , 2 ]", .expected = "[\n    1,\n    2\n]" },
    .{ .input = "\"\\uD800\"", .expected = "\"\\uD800\"" },
    .{ .input = "\"\\u0041\"", .expected = "\"\\u0041\"" },
    .{ .input = "-0", .expected = "-0" },
    .{ .input = "0.5e10", .expected = "0.5e10" },
    .{ .input = "1E5", .expected = "1E5" },
    .{ .input = "9007199254740993", .expected = "9007199254740993" },
    .{ .input = "null", .expected = "null" },
    .{ .input = "[true,false,null]", .expected = "[\n    true,\n    false,\n    null\n]" },
    .{ .input = "{\"\":1}", .expected = "{\n    \"\": 1\n}" },
    .{ .input = "{\n\"a\":1\n}", .expected = "{\n    \"a\": 1\n}" },
    .{ .input = "{\"a\":1}\n\n", .expected = "{\n    \"a\": 1\n}\n\n" },
    .{ .input = "{\"a\":1} ", .expected = "{\n    \"a\": 1\n} " },
    .{ .input = "{\"a\":1,\"a\":2}", .expected = "{\n    \"a\": 1,\n    \"a\": 2\n}" },
    .{
        .input = "{\"nested\":{\"number\":9007199254740993},\"html\":\"<b>\"}",
        .expected = "{\n    \"nested\": {\n        \"number\": 9007199254740993\n    },\n    \"html\": \"<b>\"\n}",
    },
    .{
        .input = "{ \"a\" : {\"b\" : [ 1 , 2 ] } }",
        .expected = "{\n    \"a\": {\n        \"b\": [\n            1,\n            2\n        ]\n    }\n}",
    },
    .{
        .input = "[{\"a\":1},{\"b\":2}]",
        .expected = "[\n    {\n        \"a\": 1\n    },\n    {\n        \"b\": 2\n    }\n]",
    },
    .{
        .input = "[[[[1]]]]",
        .expected = "[\n    [\n        [\n            [\n                1\n            ]\n        ]\n    ]\n]",
    },
    .{
        .input = "{\"a\":[{\"b\":[]}]}",
        .expected = "{\n    \"a\": [\n        {\n            \"b\": []\n        }\n    ]\n}",
    },
};

test "valid documents match go indentation" {
    for (&valid_cases) |case| {
        try std.testing.expect(try isValid(std.testing.allocator, case.input));
        const text = try indentText(case.input);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings(case.expected, text);
    }
}

/// Inputs Go's `encoding/json` rejects; this port must reject them too so
/// auto-detection keeps sending malformed JSON down the JSON error path.
const invalid_cases = [_][]const u8{
    "1.",
    "1.x",
    "01",
    "-",
    "1e",
    "1e+",
    "[1,]",
    "{\"a\":1,}",
    "tru",
    "{\"a\" 1}",
    "{}extra",
    "[1 2]",
    "\"a\\qb\"",
    "{\"a\":\"\\u12\"}",
    "[1,2]x",
    "  ",
    "",
    "{\"a\":1}{\"b\":2}",
    "[1,,2]",
    "[,1]",
    "{\"a\"::1}",
    "\"a\tb\"",
    "NaN",
    "Infinity",
    "'a'",
    "{a:1}",
    "// comment\n{}",
    "0x10",
    "+1",
    "1_000",
};

test "invalid documents are rejected" {
    for (invalid_cases) |input| {
        try std.testing.expect(!try isValid(std.testing.allocator, input));
        const message = try indentError(input);
        defer std.testing.allocator.free(message);
        try std.testing.expect(message.len > 0);
    }
}

test "errors name the offending character" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{
            .input = "{\"a\":1,}",
            .expected = "invalid character '}' looking for beginning of object key string at offset 7",
        },
        .{
            .input = "{}extra",
            .expected = "invalid character 'e' after top-level value at offset 2",
        },
        .{
            .input = "[1 2]",
            .expected = "invalid character '2' after array element at offset 3",
        },
        .{
            .input = "\"a\tb\"",
            .expected = "invalid character '\\x09' in string literal at offset 2",
        },
    };
    for (&cases) |case| {
        const message = try indentError(case.input);
        defer std.testing.allocator.free(message);
        try std.testing.expectEqualStrings(case.expected, message);
    }
}
