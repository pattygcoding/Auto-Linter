//! HTML validation and formatting.
//!
//! HTML is more forgiving than XML, so this formatter implements the parts of
//! HTML's tree construction that affect indentation: void elements that never
//! take an end tag, the optional end tags of `li`, `p`, `td`, `tr` and friends,
//! boolean and unquoted attributes, case-insensitive tag matching, and raw-text
//! elements (`script`, `style`, `pre`, `textarea`, …) whose content is preserved
//! byte for byte.
//!
//! Formatting re-indents element-only content with four spaces per level.
//! Elements that contain text are emitted with their original content, so mixed
//! content such as `<p>Hello <b>world</b>!</p>` is never reflowed.

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

const Element = struct {
    name: []const u8,
    start_tag: []const u8,
    /// `null` when the end tag was omitted, as HTML allows for optional tags.
    end_tag: ?[]const u8 = null,
    /// Original bytes between the tags, used when the content is preserved.
    inner: []const u8 = "",
    inner_start: usize = 0,
    children: std.ArrayList(Node) = .empty,
    /// A direct text child means the content is preserved rather than reflowed.
    has_text: bool = false,
    void: bool = false,
    /// Content is raw text and is never parsed or re-indented.
    raw: bool = false,
    self_closing: bool = false,
    is_root: bool = false,
};

const Node = union(enum) {
    element: *Element,
    comment: []const u8,
    doctype: []const u8,
    /// `<?…>`, `<![CDATA[…]]>` and similar declarations HTML treats as comments.
    bogus: []const u8,
};

const Parser = struct {
    allocator: Allocator,
    input: []const u8,
    position: usize = 0,
    diagnostic: ?*diagnostic.Diagnostic = null,
    stack: std.ArrayList(*Element) = .empty,
    seen_doctype: bool = false,
    seen_top_element: bool = false,

    fn fail(self: *Parser, comptime format_string: []const u8, args: anytype) Error {
        return diagnostic.fail(self.diagnostic, format_string, args);
    }

    fn atEnd(self: *Parser) bool {
        return self.position >= self.input.len;
    }

    fn peek(self: *Parser) u8 {
        return self.input[self.position];
    }

    fn parseDocument(self: *Parser) Error!*Element {
        const root = try self.allocator.create(Element);
        root.* = .{ .name = "", .start_tag = "", .is_root = true };
        try self.stack.append(self.allocator, root);

        while (!self.atEnd()) {
            if (self.peek() != '<') {
                try self.parseText();
                continue;
            }
            const rest = self.input[self.position..];
            if (std.mem.startsWith(u8, rest, "<!--")) {
                try self.parseComment();
            } else if (rest.len > 1 and rest[1] == '!') {
                if (isDoctypeStart(rest)) {
                    try self.parseDoctype();
                } else {
                    try self.parseBogusComment();
                }
            } else if (rest.len > 1 and rest[1] == '?') {
                try self.parseBogusComment();
            } else if (rest.len > 1 and rest[1] == '/') {
                try self.parseEndTag();
            } else if (rest.len > 1 and std.ascii.isAlphabetic(rest[1])) {
                try self.parseStartTag();
            } else {
                // A `<` that cannot start markup is text in HTML.
                self.position += 1;
                try self.noteText("<");
            }
        }

        while (self.stack.items.len > 1) {
            const top = self.stack.items[self.stack.items.len - 1];
            if (!mayOmitEndTag(top.name) and !top.raw) {
                return self.fail("unclosed element '<{s}>' at offset {d}", .{ top.name, top.inner_start });
            }
            self.finishImplicit(top, self.input.len);
            _ = self.stack.pop();
        }
        return root;
    }

    fn appendNode(self: *Parser, node: Node) Error!void {
        const top = self.stack.items[self.stack.items.len - 1];
        try top.children.append(self.allocator, node);
    }

    /// Records text at the current level. Only whitespace is allowed outside an
    /// element; anything else marks the enclosing element as text content.
    fn noteText(self: *Parser, text: []const u8) Error!void {
        if (isWhitespace(text)) return;
        const top = self.stack.items[self.stack.items.len - 1];
        if (top.is_root) return self.fail("text outside an element at offset {d}", .{self.position});
        top.has_text = true;
    }

    fn parseText(self: *Parser) Error!void {
        const start = self.position;
        while (!self.atEnd() and self.peek() != '<') self.position += 1;
        try self.noteText(self.input[start..self.position]);
    }

    fn finishImplicit(self: *Parser, element: *Element, end: usize) void {
        const raw_inner = self.input[element.inner_start..end];
        element.inner = if (element.raw) raw_inner else std.mem.trimEnd(u8, raw_inner, " \t\r\n");
        element.end_tag = null;
    }

    fn parseComment(self: *Parser) Error!void {
        const start = self.position;
        const end = std.mem.indexOfPos(u8, self.input, start + 4, "-->") orelse {
            return self.fail("unterminated comment at offset {d}", .{start});
        };
        self.position = end + 3;
        try self.appendNode(.{ .comment = self.input[start..self.position] });
    }

    fn parseBogusComment(self: *Parser) Error!void {
        const start = self.position;
        const end = std.mem.indexOfScalarPos(u8, self.input, start + 2, '>');
        if (end) |index| {
            self.position = index + 1;
        } else {
            self.position = self.input.len;
        }
        try self.appendNode(.{ .bogus = self.input[start..self.position] });
    }

    fn parseDoctype(self: *Parser) Error!void {
        const start = self.position;
        const top = self.stack.items[self.stack.items.len - 1];
        if (!top.is_root or self.seen_doctype or self.seen_top_element) {
            return self.fail("unexpected DOCTYPE at offset {d}", .{start});
        }

        var index = start + 2;
        var quote: ?u8 = null;
        while (index < self.input.len) : (index += 1) {
            const byte = self.input[index];
            if (quote) |active| {
                if (byte == active) quote = null;
                continue;
            }
            if (byte == '"' or byte == '\'') {
                quote = byte;
                continue;
            }
            if (byte == '>') {
                index += 1;
                self.position = index;
                self.seen_doctype = true;
                try self.appendNode(.{ .doctype = self.input[start..index] });
                return;
            }
        }
        // HTML closes an unterminated declaration at end of input.
        self.position = self.input.len;
        self.seen_doctype = true;
        try self.appendNode(.{ .doctype = self.input[start..] });
    }

    fn skipWhitespace(self: *Parser) bool {
        const start = self.position;
        while (!self.atEnd() and isWhitespaceByte(self.peek())) self.position += 1;
        return self.position > start;
    }

    fn parseTagName(self: *Parser) []const u8 {
        const start = self.position;
        if (!self.atEnd() and std.ascii.isAlphabetic(self.peek())) {
            self.position += 1;
            while (!self.atEnd() and isTagNameChar(self.peek())) self.position += 1;
        }
        return self.input[start..self.position];
    }

    fn closeForStart(self: *Parser, new_name: []const u8, tag_start: usize) void {
        while (self.stack.items.len > 1) {
            const top = self.stack.items[self.stack.items.len - 1];
            if (!closesOnStart(top.name, new_name)) break;
            self.finishImplicit(top, tag_start);
            _ = self.stack.pop();
        }
    }

    fn parseEndTag(self: *Parser) Error!void {
        const start = self.position;
        self.position += 2;
        const name = self.parseTagName();
        if (name.len == 0) {
            return self.fail("expected a closing tag name at offset {d}", .{self.position});
        }
        _ = self.skipWhitespace();
        if (self.atEnd() or self.peek() != '>') {
            return self.fail("unterminated closing tag at offset {d}", .{start});
        }
        self.position += 1;
        const end_tag = self.input[start..self.position];

        if (self.stack.items.len <= 1) {
            return self.fail("unexpected closing tag '</{s}>' at offset {d}", .{ name, start });
        }

        var match: ?usize = null;
        var index = self.stack.items.len;
        while (index > 1) {
            index -= 1;
            if (std.ascii.eqlIgnoreCase(self.stack.items[index].name, name)) {
                match = index;
                break;
            }
        }
        const match_index = match orelse {
            return self.fail("unexpected closing tag '</{s}>' at offset {d}", .{ name, start });
        };

        while (self.stack.items.len - 1 > match_index) {
            const top = self.stack.items[self.stack.items.len - 1];
            if (!mayOmitEndTag(top.name) and !top.raw) {
                return self.fail("mismatched closing tag '</{s}>' at offset {d}; '<{s}>' is still open", .{
                    name,
                    start,
                    top.name,
                });
            }
            self.finishImplicit(top, start);
            _ = self.stack.pop();
        }

        const matched = self.stack.items[self.stack.items.len - 1];
        matched.inner = self.input[matched.inner_start..start];
        matched.end_tag = end_tag;
        _ = self.stack.pop();
    }
    fn parseStartTag(self: *Parser) Error!void {
        const start = self.position;
        self.position += 1;
        const name = self.parseTagName();
        if (name.len == 0) return self.fail("expected a tag name at offset {d}", .{start});

        var self_closing = false;
        while (true) {
            const had_space = self.skipWhitespace();
            if (self.atEnd()) {
                return self.fail("unterminated start tag '<{s}>' at offset {d}", .{ name, start });
            }
            if (self.peek() == '>') {
                self.position += 1;
                break;
            }
            if (self.peek() == '/' and self.position + 1 < self.input.len and self.input[self.position + 1] == '>') {
                self.position += 2;
                self_closing = true;
                break;
            }
            if (!had_space) {
                return self.fail("attributes must be separated by whitespace at offset {d}", .{self.position});
            }

            const attribute_start = self.position;
            while (!self.atEnd() and isAttributeNameChar(self.peek())) self.position += 1;
            if (self.position == attribute_start) {
                return self.fail("expected an attribute name or '>' at offset {d}", .{self.position});
            }
            _ = self.skipWhitespace();
            if (!self.atEnd() and self.peek() == '=') {
                self.position += 1;
                _ = self.skipWhitespace();
                if (self.atEnd()) {
                    return self.fail("unterminated attribute value at offset {d}", .{self.position});
                }
                const quote = self.peek();
                if (quote == '"' or quote == '\'') {
                    self.position += 1;
                    const value_start = self.position;
                    while (!self.atEnd() and self.peek() != quote) self.position += 1;
                    if (self.atEnd()) {
                        return self.fail("unterminated attribute value at offset {d}", .{value_start});
                    }
                    self.position += 1;
                } else {
                    const value_start = self.position;
                    while (!self.atEnd() and !isWhitespaceByte(self.peek()) and self.peek() != '>') {
                        self.position += 1;
                    }
                    if (self.position == value_start) {
                        return self.fail("expected an attribute value at offset {d}", .{self.position});
                    }
                }
            }
        }

        self.closeForStart(name, start);

        const element = try self.allocator.create(Element);
        element.* = .{
            .name = name,
            .start_tag = self.input[start..self.position],
            .inner_start = self.position,
            .void = isVoidElement(name),
            .raw = isRawElement(name),
            .self_closing = self_closing,
        };
        try self.appendNode(.{ .element = element });
        if (self.stack.items.len == 1) self.seen_top_element = true;

        if (element.void or self_closing) return;
        try self.stack.append(self.allocator, element);
        if (element.raw) self.skipRawContent(name);
    }

    fn skipRawContent(self: *Parser, name: []const u8) void {
        if (std.ascii.eqlIgnoreCase(name, "plaintext")) {
            self.position = self.input.len;
            return;
        }
        if (findRawClose(self.input, self.position, name)) |close_start| {
            self.position = close_start;
        } else {
            self.position = self.input.len;
        }
    }
};

fn isWhitespace(text: []const u8) bool {
    for (text) |byte| {
        if (!isWhitespaceByte(byte)) return false;
    }
    return true;
}

fn isWhitespaceByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

fn isTagNameChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == ':' or byte == '.';
}

fn isAttributeNameChar(byte: u8) bool {
    return !isWhitespaceByte(byte) and byte != '=' and byte != '>' and byte != '/' and
        byte != '"' and byte != '\'' and byte != '<';
}

fn isDoctypeStart(text: []const u8) bool {
    if (text.len < 9) return false;
    if (!std.ascii.eqlIgnoreCase(text[0..9], "<!DOCTYPE")) return false;
    return text.len == 9 or isWhitespaceByte(text[9]) or text[9] == '>';
}

fn inList(name: []const u8, comptime names: []const []const u8) bool {
    for (names) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

fn isVoidElement(name: []const u8) bool {
    return inList(name, &.{
        "area",  "base", "basefont", "bgsound", "br",   "col",  "embed", "frame",
        "hr",    "img",  "input",    "keygen",  "link", "meta", "param", "source",
        "track", "wbr",
    });
}

fn isRawElement(name: []const u8) bool {
    return inList(name, &.{
        "script", "style",  "pre",     "textarea", "title",
        "xmp",    "iframe", "noembed", "noframes", "plaintext",
    });
}

fn mayOmitEndTag(name: []const u8) bool {
    return inList(name, &.{
        "html",     "head",     "body",      "p",  "li",    "dt",    "dd",    "option",
        "optgroup", "tr",       "td",        "th", "thead", "tbody", "tfoot", "rt",
        "rp",       "colgroup", "plaintext",
    });
}

fn isCell(name: []const u8) bool {
    return inList(name, &.{ "td", "th" });
}

fn isSection(name: []const u8) bool {
    return inList(name, &.{ "thead", "tbody", "tfoot" });
}

fn closesParagraph(name: []const u8) bool {
    return inList(name, &.{
        "address", "article", "aside", "blockquote", "details",  "dialog",
        "div",     "dl",      "dt",    "dd",         "fieldset", "figcaption",
        "figure",  "footer",  "form",  "h1",         "h2",       "h3",
        "h4",      "h5",      "h6",    "header",     "hgroup",   "hr",
        "li",      "main",    "menu",  "nav",        "ol",       "p",
        "pre",     "section", "table", "ul",
    });
}

/// Whether a new start tag implicitly closes the currently open element.
fn closesOnStart(open_name: []const u8, new_name: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(open_name, "p")) return closesParagraph(new_name);
    if (std.ascii.eqlIgnoreCase(open_name, "li")) return std.ascii.eqlIgnoreCase(new_name, "li");
    if (std.ascii.eqlIgnoreCase(open_name, "dt") or std.ascii.eqlIgnoreCase(open_name, "dd")) {
        return std.ascii.eqlIgnoreCase(new_name, "dt") or std.ascii.eqlIgnoreCase(new_name, "dd");
    }
    if (std.ascii.eqlIgnoreCase(open_name, "option")) {
        return std.ascii.eqlIgnoreCase(new_name, "option") or std.ascii.eqlIgnoreCase(new_name, "optgroup");
    }
    if (std.ascii.eqlIgnoreCase(open_name, "optgroup")) return std.ascii.eqlIgnoreCase(new_name, "optgroup");
    if (std.ascii.eqlIgnoreCase(open_name, "head")) {
        return std.ascii.eqlIgnoreCase(new_name, "body") or std.ascii.eqlIgnoreCase(new_name, "frameset");
    }
    if (std.ascii.eqlIgnoreCase(open_name, "colgroup")) {
        return isSection(new_name) or std.ascii.eqlIgnoreCase(new_name, "tr");
    }
    if (std.ascii.eqlIgnoreCase(open_name, "tr")) {
        return std.ascii.eqlIgnoreCase(new_name, "tr") or isSection(new_name);
    }
    if (isCell(open_name)) {
        return isCell(new_name) or std.ascii.eqlIgnoreCase(new_name, "tr") or isSection(new_name);
    }
    if (isSection(open_name)) return isSection(new_name);
    if (std.ascii.eqlIgnoreCase(open_name, "rt") or std.ascii.eqlIgnoreCase(open_name, "rp")) {
        return std.ascii.eqlIgnoreCase(new_name, "rt") or std.ascii.eqlIgnoreCase(new_name, "rp");
    }
    return false;
}

fn findRawClose(input: []const u8, start: usize, name: []const u8) ?usize {
    var index = start;
    while (index + 2 + name.len <= input.len) : (index += 1) {
        if (input[index] != '<' or input[index + 1] != '/') continue;
        const candidate = input[index + 2 .. index + 2 + name.len];
        if (!std.ascii.eqlIgnoreCase(candidate, name)) continue;
        const after = index + 2 + name.len;
        if (after >= input.len or input[after] == '>' or isWhitespaceByte(input[after])) return index;
    }
    return null;
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
        .comment, .doctype, .bogus => |text| {
            try pushIndent(output, allocator, depth);
            try output.appendSlice(allocator, text);
        },
        .element => |element| {
            try pushIndent(output, allocator, depth);
            try output.appendSlice(allocator, element.start_tag);
            if (element.void or element.self_closing) return;

            if (element.has_text or element.raw) {
                try output.appendSlice(allocator, element.inner);
                if (element.end_tag) |end_tag| try output.appendSlice(allocator, end_tag);
                return;
            }
            if (element.children.items.len == 0) {
                if (element.end_tag) |end_tag| try output.appendSlice(allocator, end_tag);
                return;
            }
            for (element.children.items) |child| {
                try output.append(allocator, '\n');
                try renderNode(output, allocator, child, depth + 1);
            }
            if (element.end_tag) |end_tag| {
                try output.append(allocator, '\n');
                try pushIndent(output, allocator, depth);
                try output.appendSlice(allocator, end_tag);
            }
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

test "indents an html document" {
    try expectFormat(
        "<!DOCTYPE html>\n<html>\n<head>\n<title>Page</title>\n<link rel=\"stylesheet\" href=\"style.css\">\n</head>\n<body>\n<h1>Hello</h1>\n<p>Some <em>text</em>.</p>\n</body>\n</html>\n",
        "<!DOCTYPE html>\n<html>\n    <head>\n        <title>Page</title>\n        <link rel=\"stylesheet\" href=\"style.css\">\n    </head>\n    <body>\n        <h1>Hello</h1>\n        <p>Some <em>text</em>.</p>\n    </body>\n</html>\n",
    );
}

test "handles optional end tags" {
    try expectFormat(
        "<ul><li>one<li>two</ul>\n",
        "<ul>\n    <li>one\n    <li>two\n</ul>\n",
    );
    try expectFormat(
        "<table><tr><td>a<td>b<tr><td>c</table>",
        "<table>\n    <tr>\n        <td>a\n        <td>b\n    <tr>\n        <td>c\n</table>",
    );
    try expectFormat(
        "<p>one<div>two</div>",
        "<p>one\n<div>two</div>",
    );
    try expectFormat(
        "<head><title>x</title><body><p>y</body>",
        "<head>\n    <title>x</title>\n<body>\n    <p>y\n</body>",
    );
}

test "keeps void elements and attribute syntax" {
    try expectFormat(
        "<div class=box hidden><br><img src=a.png alt='x'><input type=checkbox checked></div>",
        "<div class=box hidden>\n    <br>\n    <img src=a.png alt='x'>\n    <input type=checkbox checked>\n</div>",
    );
    try expectFormat(
        "<DIV><BR /></DIV>",
        "<DIV>\n    <BR />\n</DIV>",
    );
}

test "preserves raw text elements" {
    const raw = "<script>if (a < b) { c(\"</div>\"); }</script>\n<pre>\n  keep   this\n    exactly\n</pre>\n";
    try expectFormat(raw, raw);
    try expectFormat("<SCRIPT>alert(1 < 2)</SCRIPT>", "<SCRIPT>alert(1 < 2)</SCRIPT>");
}

test "preserves mixed content exactly" {
    try expectFormat("<p>Hello <b>world</b>!</p>", "<p>Hello <b>world</b>!</p>");
    try expectFormat("<DIV>Text <SPAN>here</SPAN>.</DIV>", "<DIV>Text <SPAN>here</SPAN>.</DIV>");
    try expectFormat("<a href=\"/x\">link</a>", "<a href=\"/x\">link</a>");
}

test "keeps comments declarations and bogus comments" {
    try expectFormat(
        "<!DOCTYPE html>\n<!-- note -->\n<?xml version=\"1.0\"?>\n<div></div>\n",
        "<!DOCTYPE html>\n<!-- note -->\n<?xml version=\"1.0\"?>\n<div></div>\n",
    );
}

test "rejects malformed html" {
    for ([_][]const u8{
        "<div><span></div>",
        "</div>",
        "<div>",
        "<div><p>x",
        "<div attr=\"x>",
        "<div attr=>",
        "<!-- open",
        "<div a=\"1\"b=\"2\">",
        "<br></br>",
        "<div",
    }) |input| {
        const message = try rejectionMessage(input);
        defer std.testing.allocator.free(message);
        try std.testing.expect(message.len > 0);
    }
}
