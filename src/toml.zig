//! TOML validation and formatting.
//!
//! Validation walks the document the way a TOML parser does: table headers,
//! dotted keys, strings (including multiline strings), arrays, inline tables and
//! scalar values. Formatting then normalises the parts of a TOML file that carry
//! no meaning: leading indentation, spaces around the key/value separator, and
//! trailing whitespace outside multiline strings. Array contents are indented
//! four columns per nesting level, which is the only nesting TOML has.

const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const indent_module = @import("indent.zig");

const Allocator = std.mem.Allocator;
const Error = diagnostic.Error;
const STEP = indent_module.INDENT.len;

/// Validates `input` and returns it re-indented with four spaces per array level.
pub fn format(allocator: Allocator, input: []const u8, diag: ?*diagnostic.Diagnostic) Error![]u8 {
    var parser = Parser{ .input = input, .diagnostic = diag };
    try parser.run();
    return reindent(allocator, input);
}

/// Reports whether `input` is valid TOML that contains at least one `key = value`
/// line. Auto-detection uses the assignment as the signal that a document is TOML
/// rather than a YAML plain scalar.
pub fn looksLikeToml(input: []const u8) bool {
    var parser = Parser{ .input = input };
    parser.run() catch return false;
    return parser.saw_assignment;
}

const Parser = struct {
    input: []const u8,
    position: usize = 0,
    diagnostic: ?*diagnostic.Diagnostic = null,
    saw_assignment: bool = false,

    fn fail(self: *Parser, comptime format_string: []const u8, args: anytype) Error {
        return diagnostic.fail(self.diagnostic, format_string, args);
    }

    fn atEnd(self: *Parser) bool {
        return self.position >= self.input.len;
    }

    fn peek(self: *Parser) u8 {
        return self.input[self.position];
    }

    fn skipSpaces(self: *Parser) void {
        while (!self.atEnd() and (self.peek() == ' ' or self.peek() == '\t')) self.position += 1;
    }

    fn skipComment(self: *Parser) void {
        if (!self.atEnd() and self.peek() == '#') {
            while (!self.atEnd() and self.peek() != '\n') self.position += 1;
        }
    }

    /// Skips whitespace, newlines and comments between statements.
    fn skipBlank(self: *Parser) void {
        while (!self.atEnd()) {
            switch (self.peek()) {
                ' ', '\t', '\r', '\n' => self.position += 1,
                '#' => self.skipComment(),
                else => return,
            }
        }
    }

    /// Skips whitespace, newlines and comments inside an array.
    fn skipArraySpace(self: *Parser) void {
        while (!self.atEnd()) {
            switch (self.peek()) {
                ' ', '\t', '\r', '\n' => self.position += 1,
                '#' => self.skipComment(),
                else => return,
            }
        }
    }

    fn run(self: *Parser) Error!void {
        while (true) {
            self.skipBlank();
            if (self.atEnd()) return;
            if (self.peek() == '[') {
                try self.parseTableHeader();
            } else {
                try self.parseKeyValue();
                self.saw_assignment = true;
            }
        }
    }

    fn parseTableHeader(self: *Parser) Error!void {
        self.position += 1;
        var array_table = false;
        if (!self.atEnd() and self.peek() == '[') {
            array_table = true;
            self.position += 1;
        }
        self.skipSpaces();
        try self.parseKeyPath();
        self.skipSpaces();
        if (self.atEnd() or self.peek() != ']') {
            return self.fail("unterminated table header at offset {d}", .{self.position});
        }
        self.position += 1;
        if (array_table) {
            if (self.atEnd() or self.peek() != ']') {
                return self.fail("unterminated array-of-tables header at offset {d}", .{self.position});
            }
            self.position += 1;
        }
        try self.expectLineEnd();
    }

    fn parseKeyValue(self: *Parser) Error!void {
        try self.parseKeyPath();
        self.skipSpaces();
        if (self.atEnd() or self.peek() != '=') {
            return self.fail("expected '=' after a key at offset {d}", .{self.position});
        }
        self.position += 1;
        self.skipSpaces();
        try self.parseValue();
        try self.expectLineEnd();
    }

    fn expectLineEnd(self: *Parser) Error!void {
        self.skipSpaces();
        self.skipComment();
        if (self.atEnd()) return;
        switch (self.peek()) {
            '\n' => self.position += 1,
            '\r' => {
                self.position += 1;
                if (!self.atEnd() and self.peek() == '\n') self.position += 1;
            },
            else => return self.fail("unexpected character 0x{x:0>2} at offset {d}", .{
                self.peek(),
                self.position,
            }),
        }
    }

    fn parseKeyPath(self: *Parser) Error!void {
        try self.parseSimpleKey();
        self.skipSpaces();
        while (!self.atEnd() and self.peek() == '.') {
            self.position += 1;
            self.skipSpaces();
            try self.parseSimpleKey();
            self.skipSpaces();
        }
    }

    fn parseSimpleKey(self: *Parser) Error!void {
        if (self.atEnd()) return self.fail("expected a key at offset {d}", .{self.position});
        switch (self.peek()) {
            '"' => try self.parseBasicString(),
            '\'' => try self.parseLiteralString(),
            else => {
                const start = self.position;
                while (!self.atEnd() and isBareKeyChar(self.peek())) self.position += 1;
                if (self.position == start) {
                    return self.fail("expected a key at offset {d}", .{self.position});
                }
            },
        }
    }

    fn parseValue(self: *Parser) Error!void {
        if (self.atEnd()) return self.fail("expected a value at offset {d}", .{self.position});
        const rest = self.input[self.position..];
        if (std.mem.startsWith(u8, rest, "\"\"\"")) {
            try self.parseMultilineString('"');
            return;
        }
        if (std.mem.startsWith(u8, rest, "'''")) {
            try self.parseMultilineString('\'');
            return;
        }
        switch (self.peek()) {
            '"' => try self.parseBasicString(),
            '\'' => try self.parseLiteralString(),
            '[' => try self.parseArray(),
            '{' => try self.parseInlineTable(),
            else => try self.parseScalar(),
        }
    }

    fn parseScalar(self: *Parser) Error!void {
        const start = self.position;
        while (!self.atEnd() and !isScalarTerminator(self.peek())) self.position += 1;
        if (self.position == start) {
            return self.fail("expected a value at offset {d}", .{self.position});
        }
        const token = self.input[start..self.position];

        // TOML allows a space between the date and time of an offset date-time.
        if (isDate(token) and !self.atEnd() and self.peek() == ' ') {
            const after_space = self.position + 1;
            if (after_space < self.input.len and std.ascii.isDigit(self.input[after_space])) {
                self.position = after_space;
                const time_start = self.position;
                while (!self.atEnd() and !isScalarTerminator(self.peek())) self.position += 1;
                if (!isTime(self.input[time_start..self.position])) {
                    return self.fail("invalid date-time value at offset {d}", .{start});
                }
                return;
            }
        }
        if (!isValidScalar(token)) {
            return self.fail("invalid value at offset {d}", .{start});
        }
    }
    fn parseBasicString(self: *Parser) Error!void {
        self.position += 1;
        while (!self.atEnd()) {
            const byte = self.peek();
            if (byte == '"') {
                self.position += 1;
                return;
            }
            if (byte == '\n' or byte == '\r') break;
            if (byte == '\\') {
                try self.parseEscape();
                continue;
            }
            self.position += 1;
        }
        return self.fail("unterminated string at offset {d}", .{self.position});
    }

    fn parseEscape(self: *Parser) Error!void {
        self.position += 1;
        if (self.atEnd()) return self.fail("unterminated escape sequence at offset {d}", .{self.position});
        switch (self.peek()) {
            'b', 't', 'n', 'f', 'r', '"', '\\' => self.position += 1,
            'u' => {
                self.position += 1;
                try self.expectHexDigits(4);
            },
            'U' => {
                self.position += 1;
                try self.expectHexDigits(8);
            },
            else => return self.fail("invalid escape sequence at offset {d}", .{self.position}),
        }
    }

    fn expectHexDigits(self: *Parser, count: usize) Error!void {
        var index: usize = 0;
        while (index < count) : (index += 1) {
            if (self.atEnd() or !std.ascii.isHex(self.peek())) {
                return self.fail("invalid unicode escape at offset {d}", .{self.position});
            }
            self.position += 1;
        }
    }

    fn parseLiteralString(self: *Parser) Error!void {
        self.position += 1;
        while (!self.atEnd()) {
            const byte = self.peek();
            if (byte == '\'') {
                self.position += 1;
                return;
            }
            if (byte == '\n' or byte == '\r') break;
            self.position += 1;
        }
        return self.fail("unterminated literal string at offset {d}", .{self.position});
    }
    fn parseMultilineString(self: *Parser, quote: u8) Error!void {
        self.position += 3;
        while (!self.atEnd()) {
            if (self.peek() == quote and self.startsWithTriple(quote)) {
                self.position += 3;
                var extra: usize = 0;
                while (extra < 2 and !self.atEnd() and self.peek() == quote) : (extra += 1) {
                    self.position += 1;
                }
                return;
            }
            if (quote == '"' and self.peek() == '\\') {
                try self.parseMultilineEscape();
                continue;
            }
            self.position += 1;
        }
        return self.fail("unterminated multiline string at offset {d}", .{self.position});
    }

    fn startsWithTriple(self: *Parser, quote: u8) bool {
        if (self.position + 3 > self.input.len) return false;
        return self.input[self.position] == quote and
            self.input[self.position + 1] == quote and
            self.input[self.position + 2] == quote;
    }

    fn parseMultilineEscape(self: *Parser) Error!void {
        self.position += 1;
        if (self.atEnd()) return self.fail("unterminated escape sequence at offset {d}", .{self.position});
        switch (self.peek()) {
            ' ', '\t', '\r', '\n' => {
                while (!self.atEnd() and isWhitespaceByte(self.peek())) self.position += 1;
            },
            'b', 't', 'n', 'f', 'r', '"', '\\' => self.position += 1,
            'u' => {
                self.position += 1;
                try self.expectHexDigits(4);
            },
            'U' => {
                self.position += 1;
                try self.expectHexDigits(8);
            },
            else => return self.fail("invalid escape sequence at offset {d}", .{self.position}),
        }
    }

    fn parseArray(self: *Parser) Error!void {
        self.position += 1;
        while (true) {
            self.skipArraySpace();
            if (self.atEnd()) return self.fail("unterminated array at offset {d}", .{self.position});
            if (self.peek() == ']') {
                self.position += 1;
                return;
            }
            try self.parseValue();
            self.skipArraySpace();
            if (self.atEnd()) return self.fail("unterminated array at offset {d}", .{self.position});
            switch (self.peek()) {
                ',' => self.position += 1,
                ']' => {
                    self.position += 1;
                    return;
                },
                else => return self.fail("expected ',' or ']' after an array element at offset {d}", .{
                    self.position,
                }),
            }
        }
    }

    fn parseInlineTable(self: *Parser) Error!void {
        self.position += 1;
        self.skipSpaces();
        if (!self.atEnd() and self.peek() == '}') {
            self.position += 1;
            return;
        }
        while (true) {
            try self.parseKeyPath();
            self.skipSpaces();
            if (self.atEnd() or self.peek() != '=') {
                return self.fail("expected '=' in an inline table at offset {d}", .{self.position});
            }
            self.position += 1;
            self.skipSpaces();
            try self.parseValue();
            self.skipSpaces();
            if (self.atEnd()) return self.fail("unterminated inline table at offset {d}", .{self.position});
            switch (self.peek()) {
                ',' => {
                    self.position += 1;
                    self.skipSpaces();
                    if (!self.atEnd() and self.peek() == '}') {
                        return self.fail("trailing comma in an inline table at offset {d}", .{self.position});
                    }
                },
                '}' => {
                    self.position += 1;
                    return;
                },
                else => return self.fail("expected ',' or '}}' in an inline table at offset {d}", .{
                    self.position,
                }),
            }
        }
    }
};

fn isWhitespaceByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

fn isBareKeyChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn isScalarTerminator(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or
        byte == '#' or byte == ',' or byte == ']' or byte == '}';
}

fn isValidScalar(token: []const u8) bool {
    if (std.mem.eql(u8, token, "true") or std.mem.eql(u8, token, "false")) return true;
    if (std.mem.eql(u8, token, "inf") or std.mem.eql(u8, token, "+inf") or std.mem.eql(u8, token, "-inf")) return true;
    if (std.mem.eql(u8, token, "nan") or std.mem.eql(u8, token, "+nan") or std.mem.eql(u8, token, "-nan")) return true;
    if (isDateTime(token)) return true;
    if (isTime(token)) return true;
    return isNumber(token);
}

fn isNumber(token: []const u8) bool {
    if (token.len == 0) return false;
    var rest = token;
    if (rest[0] == '+' or rest[0] == '-') rest = rest[1..];
    if (rest.len == 0) return false;

    if (std.mem.startsWith(u8, rest, "0x")) return digitsWithUnderscores(rest[2..], 16);
    if (std.mem.startsWith(u8, rest, "0o")) return digitsWithUnderscores(rest[2..], 8);
    if (std.mem.startsWith(u8, rest, "0b")) return digitsWithUnderscores(rest[2..], 2);

    const integer_end = scanDigitRun(rest, 0) orelse return false;
    if (rest[0] == '0' and integer_end > 1) return false;

    var index = integer_end;
    if (index < rest.len and rest[index] == '.') {
        index = scanDigitRun(rest, index + 1) orelse return false;
    }
    if (index < rest.len and (rest[index] == 'e' or rest[index] == 'E')) {
        var exponent = index + 1;
        if (exponent < rest.len and (rest[exponent] == '+' or rest[exponent] == '-')) {
            exponent += 1;
        }
        index = scanDigitRun(rest, exponent) orelse return false;
    }
    return index == rest.len;
}

fn scanDigitRun(text: []const u8, start: usize) ?usize {
    if (start >= text.len or !std.ascii.isDigit(text[start])) return null;
    var index = start + 1;
    while (index < text.len) {
        if (std.ascii.isDigit(text[index])) {
            index += 1;
            continue;
        }
        if (text[index] == '_' and index + 1 < text.len and std.ascii.isDigit(text[index + 1])) {
            index += 2;
            continue;
        }
        break;
    }
    return index;
}

fn digitsWithUnderscores(text: []const u8, base: u8) bool {
    if (text.len == 0) return false;
    var previous_underscore = true;
    for (text) |byte| {
        if (byte == '_') {
            if (previous_underscore) return false;
            previous_underscore = true;
            continue;
        }
        const is_digit = switch (base) {
            16 => std.ascii.isHex(byte),
            8 => byte >= '0' and byte <= '7',
            2 => byte == '0' or byte == '1',
            else => false,
        };
        if (!is_digit) return false;
        previous_underscore = false;
    }
    return !previous_underscore;
}

fn digitsAt(text: []const u8, start: usize, count: usize) bool {
    if (start + count > text.len) return false;
    for (text[start .. start + count]) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn parseTwoDigits(text: []const u8, start: usize) ?u8 {
    if (!digitsAt(text, start, 2)) return null;
    return (text[start] - '0') * 10 + (text[start + 1] - '0');
}

fn isDate(text: []const u8) bool {
    if (text.len != 10) return false;
    if (!digitsAt(text, 0, 4) or text[4] != '-' or !digitsAt(text, 5, 2) or
        text[7] != '-' or !digitsAt(text, 8, 2)) return false;
    const month = parseTwoDigits(text, 5).?;
    const day = parseTwoDigits(text, 8).?;
    return month >= 1 and month <= 12 and day >= 1 and day <= 31;
}

fn isTime(text: []const u8) bool {
    if (text.len < 8) return false;
    if (!digitsAt(text, 0, 2) or text[2] != ':' or !digitsAt(text, 3, 2) or
        text[5] != ':' or !digitsAt(text, 6, 2)) return false;
    const hour = parseTwoDigits(text, 0).?;
    const minute = parseTwoDigits(text, 3).?;
    const second = parseTwoDigits(text, 6).?;
    if (hour > 23 or minute > 59 or second > 60) return false;

    var index: usize = 8;
    if (index < text.len and text[index] == '.') {
        index += 1;
        const fraction_start = index;
        while (index < text.len and std.ascii.isDigit(text[index])) index += 1;
        if (index == fraction_start) return false;
    }
    if (index == text.len) return true;
    if (text[index] == 'Z' or text[index] == 'z') return index + 1 == text.len;
    if (text[index] == '+' or text[index] == '-') {
        index += 1;
        if (!digitsAt(text, index, 2)) return false;
        index += 2;
        if (index >= text.len or text[index] != ':') return false;
        index += 1;
        if (!digitsAt(text, index, 2)) return false;
        return index + 2 == text.len;
    }
    return false;
}

fn isDateTime(text: []const u8) bool {
    if (isDate(text)) return true;
    if (text.len > 11 and isDate(text[0..10]) and (text[10] == 'T' or text[10] == 't')) {
        return isTime(text[11..]);
    }
    return false;
}

const Multiline = enum { none, basic, literal };

const ScanResult = struct {
    depth: usize,
    multiline: Multiline = .none,
    first_equals: ?usize = null,
};

/// Rewrites indentation, the spacing around the key/value separator, and trailing
/// whitespace, while preserving every other byte of the document.
fn reindent(allocator: Allocator, input: []const u8) Allocator.Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var depth: usize = 0;
    var multiline: Multiline = .none;
    var first_line = true;

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw_line| {
        const line = if (std.mem.endsWith(u8, raw_line, "\r"))
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;
        if (first_line) {
            first_line = false;
        } else {
            try output.append(allocator, '\n');
        }

        if (multiline != .none) {
            // Content of a multiline string is kept exactly as written.
            try output.appendSlice(allocator, line);
            const marker: []const u8 = if (multiline == .basic) "\"\"\"" else "'''";
            if (findClosing(line, 0, marker, multiline == .basic)) |after| {
                multiline = .none;
                const rest = scanCode(line, after, depth, false);
                depth = rest.depth;
                multiline = rest.multiline;
            }
            continue;
        }

        var start: usize = 0;
        while (start < line.len and (line[start] == ' ' or line[start] == '\t')) start += 1;
        const content = line[start..];

        // A line is indented by the array nesting depth, except that leading
        // closing brackets line up with the line that opened the array.
        var display_depth = depth;
        var probe: usize = 0;
        while (probe < content.len and content[probe] == ']') : (probe += 1) {
            display_depth -|= 1;
        }

        const start_depth = depth;
        const scan = scanCode(content, 0, depth, true);
        depth = scan.depth;
        multiline = scan.multiline;

        if (content.len > 0) {
            try indent_module.pushSpaces(&output, allocator, display_depth * STEP);
        }

        var text = content;
        if (scan.first_equals) |equals| {
            if (start_depth == 0 and display_depth == 0 and !std.mem.startsWith(u8, content, "[")) {
                try output.appendSlice(allocator, std.mem.trimEnd(u8, content[0..equals], " \t"));
                try output.appendSlice(allocator, " = ");
                text = std.mem.trimStart(u8, content[equals + 1 ..], " \t");
            }
        }
        if (scan.multiline != .none) {
            try output.appendSlice(allocator, text);
        } else {
            try output.appendSlice(allocator, std.mem.trimEnd(u8, text, " \t"));
        }
    }
    return try output.toOwnedSlice(allocator);
}

fn findClosing(line: []const u8, start: usize, marker: []const u8, escapes: bool) ?usize {
    var index = start;
    while (index + marker.len <= line.len) {
        if (escapes and line[index] == '\\') {
            index += 2;
            continue;
        }
        if (std.mem.eql(u8, line[index .. index + marker.len], marker)) {
            index += marker.len;
            var extra: usize = 0;
            while (extra < 2 and index < line.len and line[index] == marker[0]) : (extra += 1) {
                index += 1;
            }
            return index;
        }
        index += 1;
    }
    return null;
}

/// Scans one line of TOML code (strings and comments included) and reports the
/// array depth after it, whether it ends inside a multiline string, and where the
/// first key/value separator sits.
fn scanCode(line: []const u8, start: usize, start_depth: usize, track_equals: bool) ScanResult {
    var result = ScanResult{ .depth = start_depth };
    var index = start;
    while (index < line.len) {
        const byte = line[index];
        switch (byte) {
            '#' => return result,
            '[' => {
                result.depth += 1;
                index += 1;
            },
            ']' => {
                result.depth -|= 1;
                index += 1;
            },
            '=' => {
                if (track_equals and result.first_equals == null) result.first_equals = index;
                index += 1;
            },
            '"', '\'' => {
                if (index + 2 < line.len and line[index + 1] == byte and line[index + 2] == byte) {
                    const marker: []const u8 = if (byte == '"') "\"\"\"" else "'''";
                    if (findClosing(line, index + 3, marker, byte == '"')) |after| {
                        index = after;
                        continue;
                    }
                    result.multiline = if (byte == '"') .basic else .literal;
                    return result;
                }
                index += 1;
                while (index < line.len) {
                    if (byte == '"' and line[index] == '\\') {
                        index += 2;
                        continue;
                    }
                    if (line[index] == byte) {
                        index += 1;
                        break;
                    }
                    index += 1;
                }
            },
            else => index += 1,
        }
    }
    return result;
}

fn formatText(input: []const u8) ![]u8 {
    var diag = diagnostic.Diagnostic.init(std.testing.allocator);
    defer diag.deinit();
    return format(std.testing.allocator, input, &diag) catch |err| switch (err) {
        error.Invalid => {
            std.debug.print("unexpected rejection of {s}: {s}\n", .{ input, diag.message });
            return error.UnexpectedRejection;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn rejectionMessage(input: []const u8) ![]u8 {
    var diag = diagnostic.Diagnostic.init(std.testing.allocator);
    defer diag.deinit();
    if (format(std.testing.allocator, input, &diag)) |text| {
        std.testing.allocator.free(text);
        return error.ExpectedRejection;
    } else |err| switch (err) {
        error.Invalid => return try std.testing.allocator.dupe(u8, diag.message),
        error.OutOfMemory => return error.OutOfMemory,
    }
}

fn expectFormat(input: []const u8, expected: []const u8) !void {
    const once = try formatText(input);
    defer std.testing.allocator.free(once);
    try std.testing.expectEqualStrings(expected, once);

    const twice = try formatText(once);
    defer std.testing.allocator.free(twice);
    try std.testing.expectEqualStrings(once, twice);
}

test "normalises separators and array indentation" {
    try expectFormat(
        "# Example\ntitle=\"Formatter\"\nports = [\n  8000,\n  8001,\n]\n",
        "# Example\ntitle = \"Formatter\"\nports = [\n    8000,\n    8001,\n]\n",
    );
    try expectFormat(
        "matrix = [\n [1, 2],\n [3, 4],\n]\n",
        "matrix = [\n    [1, 2],\n    [3, 4],\n]\n",
    );
    try expectFormat(
        "points = [\n  { x = 1, y = 2 },\n  { x = 3, y = 4 }, # pair\n]\n",
        "points = [\n    { x = 1, y = 2 },\n    { x = 3, y = 4 }, # pair\n]\n",
    );
}

test "normalises table headers and keys" {
    try expectFormat(
        "  [server]\n\thost=\"127.0.0.1\"\n  port=8000\n",
        "[server]\nhost = \"127.0.0.1\"\nport = 8000\n",
    );
    try expectFormat(
        "[[products]]\nname=\"a\"\n[[products]]\nname=\"b\"\n",
        "[[products]]\nname = \"a\"\n[[products]]\nname = \"b\"\n",
    );
    try expectFormat(
        "owner={ name=\"team\" }\n",
        "owner = { name=\"team\" }\n",
    );
}

test "keeps multiline string content exactly" {
    try expectFormat(
        "message=\"\"\"\n  keep  \n  lines\"\"\"\nnext=1\n",
        "message = \"\"\"\n  keep  \n  lines\"\"\"\nnext = 1\n",
    );
    try expectFormat(
        "path='''\nC:\\data\\records.json\n'''\n",
        "path = '''\nC:\\data\\records.json\n'''\n",
    );
}

test "accepts toml scalar forms" {
    try expectFormat(
        "when=1979-05-27 07:32:00Z\nclock=07:32:00.999\nhex=0xdead_beef\nratio=1_000.5e-2\nvalue=+inf\nflag=true\nlocal=2024-02-29\n",
        "when = 1979-05-27 07:32:00Z\nclock = 07:32:00.999\nhex = 0xdead_beef\nratio = 1_000.5e-2\nvalue = +inf\nflag = true\nlocal = 2024-02-29\n",
    );
}

test "rejects malformed toml" {
    for ([_][]const u8{
        "key = ",
        "key value",
        "key = \"unterminated",
        "[table",
        "key = [1,",
        "key = {a = 1,}",
        "key = 1 2",
        "key = @",
        "key = 01",
        "key = 1__0",
        "key = 2020-13-01",
        "key = \"bad \\q escape\"",
    }) |input| {
        const message = try rejectionMessage(input);
        defer std.testing.allocator.free(message);
        try std.testing.expect(message.len > 0);
    }
}

test "detects assignment lines for auto-detection" {
    try std.testing.expect(looksLikeToml("a = 1"));
    try std.testing.expect(looksLikeToml("[table]\nkey = \"x\""));
    try std.testing.expect(!looksLikeToml("name: test"));
    try std.testing.expect(!looksLikeToml("hello"));
    try std.testing.expect(!looksLikeToml("a = "));
    try std.testing.expect(!looksLikeToml("# only a comment"));
}
