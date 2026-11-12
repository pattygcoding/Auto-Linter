//! XML validation and formatting.
//!
//! The document is checked for well-formedness — balanced and correctly nested
//! elements, quoted attributes without duplicates, valid entity references,
//! terminated comments/CDATA/processing instructions — and then re-indented with
//! four spaces per level. Elements that contain text are emitted with their
//! original content untouched, so mixed content such as
//! `<p>Hello <b>world</b>!</p>` is never reflowed.

const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const indent_module = @import("indent.zig");

const Allocator = std.mem.Allocator;
const Error = diagnostic.Error;

/// Validates `input` and returns it re-indented with four spaces per level.
pub fn format(allocator: Allocator, input: []const u8, diag: ?*diagnostic.Diagnostic) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = Parser{
        .allocator = arena.allocator(),
        .input = input,
        .diagnostic = diag,
    };
    const document = try parser.parseDocument();
    return render(allocator, document, std.mem.endsWith(u8, input, "\n"));
}

/// Reports whether `input` is one well-formed XML document.
pub fn isValid(allocator: Allocator, input: []const u8) Allocator.Error!bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = Parser{ .allocator = arena.allocator(), .input = input };
    _ = parser.parseDocument() catch |err| switch (err) {
        error.Invalid => return false,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return true;
}

const Element = struct {
    name: []const u8,
    start_tag: []const u8,
    end_tag: []const u8 = "",
    /// Original bytes between the start and end tags, used for mixed content.
    inner: []const u8 = "",
    inner_start: usize = 0,
    children: std.ArrayList(Node) = .empty,
    /// A direct text child or a CDATA section means the content is preserved.
    has_text: bool = false,
    self_closing: bool = false,
    is_root: bool = false,
};

const Node = union(enum) {
    element: *Element,
    comment: []const u8,
    pi: []const u8,
    doctype: []const u8,
};

const Parser = struct {
    allocator: Allocator,
    input: []const u8,
    position: usize = 0,
    diagnostic: ?*diagnostic.Diagnostic = null,
    stack: std.ArrayList(*Element) = .empty,
    seen_root_element: bool = false,
    seen_doctype: bool = false,

    fn fail(self: *Parser, comptime format_string: []const u8, args: anytype) Error {
        return diagnostic.fail(self.diagnostic, format_string, args);
    }

    fn parseDocument(self: *Parser) Error!*Element {
        const root = try self.allocator.create(Element);
        root.* = .{ .name = "", .start_tag = "", .is_root = true };
        try self.stack.append(self.allocator, root);

        while (self.position < self.input.len) {
            if (self.input[self.position] != '<') {
                try self.parseText();
                continue;
            }
            const rest = self.input[self.position..];
            if (std.mem.startsWith(u8, rest, "<!--")) {
                try self.parseComment();
            } else if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
                try self.parseCdata();
            } else if (std.mem.startsWith(u8, rest, "<!DOCTYPE")) {
                try self.parseDoctype();
            } else if (std.mem.startsWith(u8, rest, "<?")) {
                try self.parseProcessingInstruction();
            } else if (std.mem.startsWith(u8, rest, "</")) {
                try self.parseEndTag();
            } else {
                try self.parseStartTag();
            }
        }

        if (self.stack.items.len > 1) {
            const open = self.stack.items[self.stack.items.len - 1];
            return self.fail("unclosed element '<{s}>' at offset {d}", .{ open.name, open.inner_start });
        }
        if (!self.seen_root_element) return self.fail("missing root element", .{});
        return root;
    }

    fn appendNode(self: *Parser, node: Node) Error!void {
        const top = self.stack.items[self.stack.items.len - 1];
        try top.children.append(self.allocator, node);
    }

    fn parseText(self: *Parser) Error!void {
        const start = self.position;
        while (self.position < self.input.len and self.input[self.position] != '<') self.position += 1;
        const text = self.input[start..self.position];
        if (std.mem.indexOf(u8, text, "]]>") != null) {
            return self.fail("']]>' is not allowed in text at offset {d}", .{start});
        }
        try self.validateEntities(text, start);

        const top = self.stack.items[self.stack.items.len - 1];
        if (top.is_root) {
            if (!isWhitespace(text)) {
                return self.fail("text outside the root element at offset {d}", .{start});
            }
        } else if (!isWhitespace(text)) {
            top.has_text = true;
        }
    }

    fn validateEntities(self: *Parser, text: []const u8, offset: usize) Error!void {
        var index: usize = 0;
        while (index < text.len) {
            if (text[index] != '&') {
                index += 1;
                continue;
            }
            const end = std.mem.indexOfScalarPos(u8, text, index + 1, ';') orelse {
                return self.fail("unterminated entity reference at offset {d}", .{offset + index});
            };
            const name = text[index + 1 .. end];
            if (!isValidEntityName(name)) {
                return self.fail("invalid entity reference '&{s};' at offset {d}", .{ name, offset + index });
            }
            index = end + 1;
        }
    }

    fn parseComment(self: *Parser) Error!void {
        const start = self.position;
        const body_start = start + 4;
        const end = std.mem.indexOfPos(u8, self.input, body_start, "-->") orelse {
            return self.fail("unterminated comment at offset {d}", .{start});
        };
        const body = self.input[body_start..end];
        if (std.mem.indexOf(u8, body, "--") != null) {
            return self.fail("'--' is not allowed in a comment at offset {d}", .{start});
        }
        if (body.len > 0 and body[body.len - 1] == '-') {
            return self.fail("a comment may not end with '-' at offset {d}", .{start});
        }
        self.position = end + 3;
        try self.appendNode(.{ .comment = self.input[start..self.position] });
    }

    fn parseCdata(self: *Parser) Error!void {
        const start = self.position;
        const top = self.stack.items[self.stack.items.len - 1];
        if (top.is_root) return self.fail("CDATA outside the root element at offset {d}", .{start});
        const body_start = start + 9;
        const end = std.mem.indexOfPos(u8, self.input, body_start, "]]>") orelse {
            return self.fail("unterminated CDATA section at offset {d}", .{start});
        };
        self.position = end + 3;
        top.has_text = true;
    }

    fn parseProcessingInstruction(self: *Parser) Error!void {
        const start = self.position;
        const body_start = start + 2;
        const end = std.mem.indexOfPos(u8, self.input, body_start, "?>") orelse {
            return self.fail("unterminated processing instruction at offset {d}", .{start});
        };
        const body = self.input[body_start..end];
        if (body.len == 0 or !isNameStart(body[0])) {
            return self.fail("invalid processing instruction at offset {d}", .{start});
        }
        self.position = end + 2;
        try self.appendNode(.{ .pi = self.input[start..self.position] });
    }

    fn parseDoctype(self: *Parser) Error!void {
        const start = self.position;
        const top = self.stack.items[self.stack.items.len - 1];
        if (!top.is_root or self.seen_root_element or self.seen_doctype) {
            return self.fail("unexpected DOCTYPE at offset {d}", .{start});
        }

        var index = start + "<!DOCTYPE".len;
        var depth: usize = 0;
        while (index < self.input.len) {
            const byte = self.input[index];
            if (byte == '"' or byte == '\'') {
                const quote = byte;
                index += 1;
                while (index < self.input.len and self.input[index] != quote) index += 1;
                if (index >= self.input.len) return self.fail("unterminated DOCTYPE at offset {d}", .{start});
                index += 1;
                continue;
            }
            if (std.mem.startsWith(u8, self.input[index..], "<!--")) {
                const comment_end = std.mem.indexOfPos(u8, self.input, index + 4, "-->") orelse {
                    return self.fail("unterminated comment in DOCTYPE at offset {d}", .{start});
                };
                index = comment_end + 3;
                continue;
            }
            switch (byte) {
                '[' => depth += 1,
                ']' => {
                    if (depth > 0) depth -= 1;
                },
                '>' => {
                    if (depth == 0) {
                        index += 1;
                        self.position = index;
                        self.seen_doctype = true;
                        try self.appendNode(.{ .doctype = self.input[start..index] });
                        return;
                    }
                },
                else => {},
            }
            index += 1;
        }
        return self.fail("unterminated DOCTYPE at offset {d}", .{start});
    }

    fn skipWhitespace(self: *Parser) bool {
        const start = self.position;
        while (self.position < self.input.len) {
            switch (self.input[self.position]) {
                ' ', '\t', '\r', '\n' => self.position += 1,
                else => break,
            }
        }
        return self.position > start;
    }

    fn parseName(self: *Parser) []const u8 {
        const start = self.position;
        if (self.position < self.input.len and isNameStart(self.input[self.position])) {
            self.position += 1;
            while (self.position < self.input.len and isNameChar(self.input[self.position])) {
                self.position += 1;
            }
        }
        return self.input[start..self.position];
    }

    fn markRoot(self: *Parser) Error!void {
        const top = self.stack.items[self.stack.items.len - 1];
        if (!top.is_root) return;
        if (self.seen_root_element) return self.fail("multiple root elements", .{});
        self.seen_root_element = true;
    }

    fn parseEndTag(self: *Parser) Error!void {
        const start = self.position;
        self.position += 2;
        const name = self.parseName();
        if (name.len == 0) {
            return self.fail("expected a closing tag name at offset {d}", .{self.position});
        }
        _ = self.skipWhitespace();
        if (self.position >= self.input.len or self.input[self.position] != '>') {
            return self.fail("unterminated closing tag at offset {d}", .{start});
        }
        self.position += 1;

        if (self.stack.items.len <= 1) {
            return self.fail("unexpected closing tag '</{s}>' at offset {d}", .{ name, start });
        }
        const top = self.stack.items[self.stack.items.len - 1];
        if (!std.mem.eql(u8, top.name, name)) {
            return self.fail("mismatched closing tag '</{s}>' at offset {d}; expected '</{s}>'", .{
                name,
                start,
                top.name,
            });
        }
        top.end_tag = self.input[start..self.position];
        top.inner = self.input[top.inner_start..start];
        _ = self.stack.pop();
    }

    fn parseStartTag(self: *Parser) Error!void {
        const start = self.position;
        self.position += 1;
        const name = self.parseName();
        if (name.len == 0) return self.fail("expected an element name at offset {d}", .{start});

        var attributes = std.ArrayList([]const u8).empty;
        var self_closing = false;
        while (true) {
            const had_space = self.skipWhitespace();
            if (self.position >= self.input.len) {
                return self.fail("unterminated start tag '<{s}>' at offset {d}", .{ name, start });
            }
            if (self.input[self.position] == '>') {
                self.position += 1;
                break;
            }
            if (self.input[self.position] == '/' and self.position + 1 < self.input.len and
                self.input[self.position + 1] == '>')
            {
                self.position += 2;
                self_closing = true;
                break;
            }
            if (!had_space) {
                return self.fail("attributes must be separated by whitespace at offset {d}", .{self.position});
            }

            const attribute_name = self.parseName();
            if (attribute_name.len == 0) {
                return self.fail("expected an attribute name or '>' at offset {d}", .{self.position});
            }
            for (attributes.items) |existing| {
                if (std.mem.eql(u8, existing, attribute_name)) {
                    return self.fail("duplicate attribute '{s}' at offset {d}", .{ attribute_name, self.position });
                }
            }
            try attributes.append(self.allocator, attribute_name);

            _ = self.skipWhitespace();
            if (self.position >= self.input.len or self.input[self.position] != '=') {
                return self.fail("expected '=' after attribute '{s}' at offset {d}", .{
                    attribute_name,
                    self.position,
                });
            }
            self.position += 1;
            _ = self.skipWhitespace();
            if (self.position >= self.input.len) {
                return self.fail("unterminated attribute value at offset {d}", .{self.position});
            }
            const quote = self.input[self.position];
            if (quote != '"' and quote != '\'') {
                return self.fail("attribute value must be quoted at offset {d}", .{self.position});
            }
            self.position += 1;
            const value_start = self.position;
            while (self.position < self.input.len and self.input[self.position] != quote) {
                const byte = self.input[self.position];
                if (byte == '<') {
                    return self.fail("'<' is not allowed in an attribute value at offset {d}", .{self.position});
                }
                if (byte == '&') {
                    const end = std.mem.indexOfScalarPos(u8, self.input, self.position + 1, ';') orelse {
                        return self.fail("unterminated entity reference at offset {d}", .{self.position});
                    };
                    if (!isValidEntityName(self.input[self.position + 1 .. end])) {
                        return self.fail("invalid entity reference at offset {d}", .{self.position});
                    }
                    self.position = end + 1;
                    continue;
                }
                self.position += 1;
            }
            if (self.position >= self.input.len) {
                return self.fail("unterminated attribute value at offset {d}", .{value_start});
            }
            self.position += 1;
        }

        const element = try self.allocator.create(Element);
        element.* = .{
            .name = name,
            .start_tag = self.input[start..self.position],
            .self_closing = self_closing,
            .inner_start = self.position,
        };
        try self.appendNode(.{ .element = element });
        try self.markRoot();
        if (!self_closing) try self.stack.append(self.allocator, element);
    }
};

fn isWhitespace(text: []const u8) bool {
    for (text) |byte| {
        if (byte != ' ' and byte != '\t' and byte != '\r' and byte != '\n') return false;
    }
    return true;
}

fn isNameStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == ':' or byte >= 0x80;
}

fn isNameChar(byte: u8) bool {
    return isNameStart(byte) or std.ascii.isDigit(byte) or byte == '-' or byte == '.';
}

fn isValidEntityName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == '#') {
        if (name.len < 2) return false;
        const body = name[1..];
        if (body[0] == 'x' or body[0] == 'X') {
            if (body.len < 2) return false;
            for (body[1..]) |byte| {
                if (!std.ascii.isHex(byte)) return false;
            }
            return true;
        }
        for (body) |byte| {
            if (!std.ascii.isDigit(byte)) return false;
        }
        return true;
    }
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and
            byte != ':' and byte != '.') return false;
    }
    return true;
}

fn render(allocator: Allocator, document: *Element, trailing_newline: bool) Allocator.Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var first = true;
    for (document.children.items) |node| {
        if (first) {
            first = false;
        } else {
            try output.append(allocator, '\n');
        }
        try renderNode(&output, allocator, node, 0);
    }
    if (trailing_newline and output.items.len > 0) try output.append(allocator, '\n');
    return try output.toOwnedSlice(allocator);
}

fn renderNode(
    output: *std.ArrayList(u8),
    allocator: Allocator,
    node: Node,
    depth: usize,
) Allocator.Error!void {
    switch (node) {
        .comment => |text| {
            try pushIndent(output, allocator, depth);
            try output.appendSlice(allocator, text);
        },
        .pi => |text| {
            try pushIndent(output, allocator, depth);
            try output.appendSlice(allocator, text);
        },
        .doctype => |text| {
            try pushIndent(output, allocator, depth);
            try output.appendSlice(allocator, text);
        },
        .element => |element| {
            try pushIndent(output, allocator, depth);
            try output.appendSlice(allocator, element.start_tag);
            if (element.self_closing) return;

            if (element.has_text) {
                // Mixed content keeps its original text exactly.
                try output.appendSlice(allocator, element.inner);
                try output.appendSlice(allocator, element.end_tag);
                return;
            }
            if (element.children.items.len == 0) {
                try output.appendSlice(allocator, element.end_tag);
                return;
            }
            for (element.children.items) |child| {
                try output.append(allocator, '\n');
                try renderNode(output, allocator, child, depth + 1);
            }
            try output.append(allocator, '\n');
            try pushIndent(output, allocator, depth);
            try output.appendSlice(allocator, element.end_tag);
        },
    }
}

fn pushIndent(output: *std.ArrayList(u8), allocator: Allocator, depth: usize) Allocator.Error!void {
    var level: usize = 0;
    while (level < depth) : (level += 1) {
        try output.appendSlice(allocator, indent_module.INDENT);
    }
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

test "indents nested elements" {
    try expectFormat(
        "<?xml version=\"1.0\"?>\n<catalog>\n  <book id=\"1\">\n    <title>Formatter</title>\n    <empty/>\n  </book>\n</catalog>\n",
        "<?xml version=\"1.0\"?>\n<catalog>\n    <book id=\"1\">\n        <title>Formatter</title>\n        <empty/>\n    </book>\n</catalog>\n",
    );
}

test "keeps the declaration doctype comments and attributes" {
    try expectFormat(
        "<?xml version=\"1.0\"?>\n<!DOCTYPE note SYSTEM \"note.dtd\">\n<note>\n  <!-- greeting -->\n  <to a=\"1\" b='2'>x</to>\n</note>\n",
        "<?xml version=\"1.0\"?>\n<!DOCTYPE note SYSTEM \"note.dtd\">\n<note>\n    <!-- greeting -->\n    <to a=\"1\" b='2'>x</to>\n</note>\n",
    );
    try expectFormat(
        "<root><item a=\"1\" b='2'/><empty></empty></root>",
        "<root>\n    <item a=\"1\" b='2'/>\n    <empty></empty>\n</root>",
    );
}

test "preserves mixed content exactly" {
    const mixed = "<p>Hello <b>world</b>!</p>\n";
    try expectFormat(mixed, mixed);
    try expectFormat("<notes>Keep <em>inline</em> text.</notes>", "<notes>Keep <em>inline</em> text.</notes>");
    try expectFormat("<a>x &amp; y</a>", "<a>x &amp; y</a>");
    try expectFormat("<a>   </a>", "<a></a>");
}

test "keeps cdata content untouched" {
    try expectFormat(
        "<root><code><![CDATA[if (a < b) { x(); }]]></code></root>",
        "<root>\n    <code><![CDATA[if (a < b) { x(); }]]></code>\n</root>",
    );
}

test "rejects malformed xml" {
    for ([_][]const u8{
        "<a><b></a></b>",
        "<a>",
        "text",
        "<a></a><b></b>",
        "<a b=1/>",
        "<a b=\"1\" b=\"2\"/>",
        "<a b=\"1\"c=\"2\"/>",
        "<!-- open",
        "<a>&nope</a>",
        "<a>&#xZZ;</a>",
        "<a b=\"<\"/>",
        "</a>",
        "<a/>text",
        "<a></A>",
        "<a><![CDATA[x]]>",
    }) |input| {
        const message = try rejectionMessage(input);
        defer std.testing.allocator.free(message);
        try std.testing.expect(message.len > 0);
    }
}
