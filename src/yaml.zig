//! YAML validation and four-space indentation.
//!
//! Validation checks the structure the formatter depends on: balanced flow
//! collections and quotes, indentation without tabs, aliases that resolve to an
//! anchor in the same document, and duplicate keys in a block mapping. Malformed
//! documents, duplicate mapping keys and unknown anchors are therefore reported
//! instead of silently accepted.
//!
//! The document is never re-serialised after that: every line keeps its own text
//! and only its leading indentation is recomputed. That is what lets comments,
//! anchors, aliases, tags, quoting style, block scalars and flow collections
//! survive formatting exactly as written, including scalar text that no printer
//! would reproduce byte-for-byte (for example `9007199254740993`).
//!
//! The indentation model matches what the Go version produced and what `libyaml`
//! does: one value block is indented one step (four columns) past its parent, and
//! the members of a mapping that starts on a `- ` line are aligned two columns
//! past the dash.

const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const indent_module = @import("indent.zig");

const Allocator = std.mem.Allocator;
const Error = diagnostic.Error;

/// Width of one indentation step.
const STEP = indent_module.INDENT.len;

/// Validates `input` and returns it re-indented with four spaces per level.
///
/// Returns the parser's message for malformed YAML (unknown anchors included), a
/// duplicate-key error when a mapping key repeats — `duplicated key in mapping` —
/// and `no YAML document provided` for a document that holds nothing but
/// comments.
pub fn format(allocator: Allocator, input: []const u8, diag: ?*diagnostic.Diagnostic) Error![]u8 {
    var validator = Validator.init(allocator, diag);
    defer validator.deinit();
    try validator.run(input);
    return reindent(allocator, input);
}

const Kind = enum { map, seq };

/// One nesting level of the document being re-indented.
const Frame = struct {
    kind: Kind,
    /// Original indentation of this level's own lines (key column or dash column).
    orig: usize,
    /// Indentation this level's lines are written with.
    new: usize,
    /// Original indentation of the collection that owns this level. A block
    /// scalar's content is indented one step past it.
    block_orig: usize,
    /// Indentation of the collection that owns this level. Value blocks are
    /// indented one step past it, which is what keeps nested sequences inside a
    /// `- ` mapping aligned the way the Go version aligned them.
    block_new: usize,
    /// Set when this level's most recent line was `key:` with no value after it,
    /// which is how a `- ` at the same indentation is recognised as its sequence.
    pending_value: bool,
};

/// State carried across the lines of a multi-line quoted scalar or flow collection.
const Continuation = struct {
    /// Indentation of the line that opened the scalar or collection.
    indent: usize,
    depth: usize,
    quote: ?u8,
};

/// A block scalar whose content lines are being re-indented.
const BlockScalar = struct {
    /// Original indentation of the content; discovered from the first content
    /// line unless the header carried an explicit indicator.
    base_orig: ?usize,
    /// Indentation the content is written with.
    base_new: usize,
};

/// Everything the re-indenter needs to know about one line's structure.
const LineScan = struct {
    /// Number of leading spaces.
    indent: usize = 0,
    /// The line is a comment (or blank, which reports `indent == line.len`).
    comment_only: bool = false,
    /// The line starts with a `%` directive.
    directive: bool = false,
    /// The line is a `---` or `...` document marker.
    document_marker: bool = false,
    /// The line starts a block sequence entry (`- ` or a bare `-`).
    seq_item: bool = false,
    /// Column where the text after `- ` starts.
    item_start: usize = 0,
    /// The entry's content starts a mapping on this line (`- key: value`).
    item_mapping: bool = false,
    /// The line ends with `key:` and nothing else (optionally a comment).
    bare_key: bool = false,
    /// The line is a `|` or `>` block scalar header.
    block_scalar: bool = false,
    /// Explicit indentation indicator (`|2`), when the header carries one.
    block_indent: ?usize = null,
    /// Flow brackets left open at the end of the line.
    flow_depth: usize = 0,
    /// Net flow bracket change on the line; negative when it closes more than it
    /// opens, which is how a multi-line flow collection is followed to its end.
    flow_delta: isize = 0,
    /// Quote left open at the end of the line.
    quote: ?u8 = null,
    /// Column of the `:` separating a block key from its value, if any.
    key_colon: ?usize = null,
    /// The key separator is followed by a tab.
    tab_after_colon: bool = false,
};

/// Scans one line's structure without interpreting its text.
///
/// `initial_quote` continues a quoted scalar that started on an earlier line, in
/// which case the structural fields stay empty: everything on such a line is
/// scalar content.
fn scanLine(line: []const u8, initial_quote: ?u8) LineScan {
    const bytes = line;
    var scan = LineScan{ .quote = initial_quote };
    var start: usize = 0;
    while (start < bytes.len and bytes[start] == ' ') start += 1;
    scan.indent = start;
    if (start >= bytes.len) {
        scan.comment_only = true;
        return scan;
    }

    if (initial_quote == null) {
        const text = line[start..];
        if (text[0] == '#') {
            scan.comment_only = true;
            return scan;
        }
        if (text[0] == '%') {
            scan.directive = true;
            return scan;
        }
        if (isDocumentMarker(text)) {
            scan.document_marker = true;
            return scan;
        }
        if (text[0] == '-' and (text.len == 1 or text[1] == ' ')) {
            scan.seq_item = true;
            var content = start + 1;
            while (content < bytes.len and bytes[content] == ' ') content += 1;
            scan.item_start = content;
        }
    }

    // Walk the line once, tracking quotes, flow depth and key separators. Only a
    // `:` outside quotes and flow collections separates a key from its value.
    var depth: isize = 0;
    var quote = initial_quote;
    var position = start;
    var key_colon: ?usize = null;
    scan_loop: while (position < bytes.len) {
        const byte = bytes[position];
        if (quote) |active| {
            if (active == '"') {
                if (byte == '\\') {
                    position += 2;
                    continue;
                }
                if (byte == '"') quote = null;
            } else if (byte == '\'') {
                if (position + 1 < bytes.len and bytes[position + 1] == '\'') {
                    position += 2;
                    continue;
                }
                quote = null;
            }
            position += 1;
            continue;
        }
        switch (byte) {
            '#' => {
                if (position == start or
                    (position > 0 and (bytes[position - 1] == ' ' or bytes[position - 1] == '\t'))) break :scan_loop;
                position += 1;
            },
            '"', '\'' => {
                quote = byte;
                position += 1;
            },
            '[', '{' => {
                depth += 1;
                position += 1;
            },
            ']', '}' => {
                depth -= 1;
                position += 1;
            },
            ':' => {
                if (depth == 0) {
                    const next: ?u8 = if (position + 1 < bytes.len) bytes[position + 1] else null;
                    const separator = if (next) |value|
                        value == ' ' or value == '\t' or value == '#'
                    else
                        true;
                    if (separator and key_colon == null) {
                        key_colon = position;
                        scan.tab_after_colon = if (next) |value| value == '\t' else false;
                    }
                }
                position += 1;
            },
            else => position += 1,
        }
    }
    scan.flow_depth = if (depth > 0) @intCast(depth) else 0;
    scan.flow_delta = depth;
    scan.quote = quote;
    scan.key_colon = key_colon;
    if (initial_quote != null) return scan;

    scan.item_mapping = scan.seq_item and key_colon != null and key_colon.? >= scan.item_start;
    scan.bare_key = if (key_colon) |colon| blk: {
        const remainder = std.mem.trimStart(u8, line[colon + 1 ..], " \t");
        break :blk remainder.len == 0 or remainder[0] == '#';
    } else false;

    // A block scalar is introduced either by a key on this line (`key: |`) or by
    // the entry itself (`- |`).
    const header: ?[]const u8 = if (key_colon) |colon|
        line[colon + 1 ..]
    else if (scan.seq_item)
        line[scan.item_start..]
    else
        null;
    if (header) |value| {
        if (parseBlockHeader(value)) |info| {
            scan.block_scalar = true;
            scan.block_indent = info.explicit_indent;
        }
    }
    return scan;
}

const BlockHeader = struct {
    /// Explicit indentation indicator, when the header carries one.
    explicit_indent: ?usize = null,
};

/// Recognises a `|`, `>`, `|2`, `|-`, `>2+` style header. Returns `null` when the
/// header is not a block scalar at all.
fn parseBlockHeader(header: []const u8) ?BlockHeader {
    var rest = std.mem.trimStart(u8, header, " \t");
    if (rest.len == 0) return null;
    const kind = rest[0];
    if (kind != '|' and kind != '>') return null;
    rest = rest[1..];

    var indicator: ?usize = null;
    if (rest.len > 0 and rest[0] >= '1' and rest[0] <= '9') {
        indicator = rest[0] - '0';
        rest = rest[1..];
    }
    var chomp: usize = 0;
    while (chomp < 2 and rest.len > 0 and (rest[0] == '+' or rest[0] == '-')) : (chomp += 1) {
        rest = rest[1..];
    }

    const tail = std.mem.trimStart(u8, rest, " \t");
    if (tail.len == 0 or tail[0] == '#') return .{ .explicit_indent = indicator };
    return null;
}

fn isDocumentMarker(text: []const u8) bool {
    return std.mem.eql(u8, text, "---") or std.mem.startsWith(u8, text, "--- ") or
        std.mem.eql(u8, text, "...") or std.mem.startsWith(u8, text, "... ");
}

fn leadingSpaces(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') count += 1;
    return count;
}

/// Flow bracket and quote state for validation.
const FlowScan = struct {
    depth: usize = 0,
    delta: isize = 0,
    quote: ?u8 = null,
};

/// One mapping whose keys are being checked for duplicates.
const MappingFrame = struct {
    /// Column where this mapping's keys begin.
    column: usize,
    keys: std.ArrayList([]const u8) = .empty,
};

const Validator = struct {
    allocator: Allocator,
    diagnostic: ?*diagnostic.Diagnostic,
    line_number: usize = 0,
    flow_depth: usize = 0,
    quote: ?u8 = null,
    continuation: ?Continuation = null,
    block_parent: ?usize = null,
    anchors: std.ArrayList([]const u8) = .empty,
    mappings: std.ArrayList(MappingFrame) = .empty,
    saw_document: bool = false,

    fn init(allocator: Allocator, diag: ?*diagnostic.Diagnostic) Validator {
        return .{ .allocator = allocator, .diagnostic = diag };
    }

    fn deinit(self: *Validator) void {
        self.anchors.deinit(self.allocator);
        for (self.mappings.items) |*frame| frame.keys.deinit(self.allocator);
        self.mappings.deinit(self.allocator);
    }

    fn fail(self: *Validator, comptime format_string: []const u8, args: anytype) Error {
        return diagnostic.fail(self.diagnostic, format_string, args);
    }

    fn run(self: *Validator, input: []const u8) Error!void {
        var lines = std.mem.splitScalar(u8, input, '\n');
        while (lines.next()) |raw_line| {
            self.line_number += 1;
            const line = if (std.mem.endsWith(u8, raw_line, "\r"))
                raw_line[0 .. raw_line.len - 1]
            else
                raw_line;

            const indent = leadingSpaces(line);
            // Tabs may not be used for indentation.
            if (indent < line.len and line[indent] == '\t') {
                return self.fail("tab character used for indentation at line {d}", .{self.line_number});
            }

            // 1. Content of a block scalar: never interpreted.
            if (self.block_parent) |parent| {
                const blank = std.mem.trim(u8, line, " \t").len == 0;
                if (blank or indent > parent) continue;
                self.block_parent = null;
            }

            // 2. Continuation of a multi-line quoted scalar or flow collection.
            if (self.continuation) |active| {
                const flow = scanFlow(line, active.quote);
                if (indent < line.len) try self.scanAnchors(line, active.quote);
                const adjusted = @as(isize, @intCast(active.depth)) + flow.delta;
                const depth: usize = if (adjusted > 0) @intCast(adjusted) else 0;
                self.flow_depth = depth;
                self.quote = flow.quote;
                self.continuation = if (depth == 0 and flow.quote == null)
                    null
                else
                    .{ .indent = active.indent, .depth = depth, .quote = flow.quote };
                continue;
            }

            const scan = scanLine(line, null);
            if (scan.indent >= line.len) continue;
            if (scan.comment_only) continue;
            if (scan.directive) continue;

            if (scan.document_marker) {
                try self.finishDocument();
                self.saw_document = true;
                continue;
            }

            self.saw_document = true;

            if (scan.tab_after_colon) {
                return self.fail("tab character used as a key separator at line {d}", .{self.line_number});
            }

            const flow = scanFlow(line, null);
            try self.scanAnchors(line, null);
            try self.trackMapping(line, scan);

            self.flow_depth = flow.depth;
            self.quote = flow.quote;
            self.continuation = if (flow.quote != null or flow.depth > 0)
                .{ .indent = scan.indent, .depth = flow.depth, .quote = flow.quote }
            else
                null;
            if (scan.block_scalar) self.block_parent = scan.indent;
        }

        try self.finishDocument();
        if (!self.saw_document) return self.fail("no YAML document provided", .{});
    }

    fn finishDocument(self: *Validator) Error!void {
        if (self.flow_depth != 0) {
            return self.fail("unterminated flow collection at line {d}", .{self.line_number});
        }
        if (self.quote != null) {
            return self.fail("unterminated quoted scalar at line {d}", .{self.line_number});
        }
        self.flow_depth = 0;
        self.quote = null;
        self.continuation = null;
        self.block_parent = null;
        self.anchors.clearRetainingCapacity();
        for (self.mappings.items) |*frame| frame.keys.deinit(self.allocator);
        self.mappings.clearRetainingCapacity();
    }

    /// Finds `&anchor` definitions and `*alias` uses outside quotes and comments.
    fn scanAnchors(self: *Validator, line: []const u8, initial_quote: ?u8) Error!void {
        var quote = initial_quote;
        var position: usize = 0;
        var previous_non_space: u8 = 0;
        while (position < line.len) {
            const byte = line[position];
            if (quote) |active| {
                if (active == '"') {
                    if (byte == '\\') {
                        position += 2;
                        continue;
                    }
                    if (byte == '"') {
                        quote = null;
                        previous_non_space = '"';
                    }
                } else if (byte == '\'') {
                    if (position + 1 < line.len and line[position + 1] == '\'') {
                        position += 2;
                        continue;
                    }
                    quote = null;
                    previous_non_space = '\'';
                }
                position += 1;
                continue;
            }
            switch (byte) {
                '#' => {
                    if (position == 0 or line[position - 1] == ' ' or line[position - 1] == '\t') return;
                    previous_non_space = byte;
                    position += 1;
                },
                '"', '\'' => {
                    if (startsNode(previous_non_space)) quote = byte;
                    previous_non_space = byte;
                    position += 1;
                },
                '&', '*' => {
                    if (startsNode(previous_non_space)) {
                        const name = anchorName(line, position + 1);
                        if (name.len > 0) {
                            if (byte == '&') {
                                try self.defineAnchor(name);
                            } else {
                                try self.useAlias(name);
                            }
                            position += 1 + name.len;
                            previous_non_space = name[name.len - 1];
                            continue;
                        }
                    }
                    previous_non_space = byte;
                    position += 1;
                },
                ' ', '\t' => position += 1,
                else => {
                    previous_non_space = byte;
                    position += 1;
                },
            }
        }
    }

    fn defineAnchor(self: *Validator, name: []const u8) Error!void {
        for (self.anchors.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }
        try self.anchors.append(self.allocator, name);
    }

    fn useAlias(self: *Validator, name: []const u8) Error!void {
        for (self.anchors.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }
        return self.fail("unknown anchor '{s}' referenced by alias at line {d}", .{
            name,
            self.line_number,
        });
    }

    /// Registers the key on the line so a repeated key in the same mapping is
    /// reported. Flow mappings are validated for balance but their keys are not
    /// compared, because they are not parsed into mappings here.
    fn trackMapping(self: *Validator, line: []const u8, scan: LineScan) Error!void {
        const colon = scan.key_colon orelse return;
        if (scan.seq_item) {
            if (colon < scan.item_start) return;
            self.popMappingsBelow(scan.indent);
            const key = std.mem.trimEnd(u8, line[scan.item_start..colon], " \t");
            if (key.len == 0) return;
            return self.registerKey(scan.item_start, key);
        }
        self.popMappingsBelow(scan.indent);
        const key = std.mem.trimEnd(u8, line[scan.indent..colon], " \t");
        if (key.len == 0) return;
        return self.registerKey(scan.indent, key);
    }

    fn popMappingsBelow(self: *Validator, column: usize) void {
        while (self.mappings.items.len > 0 and
            self.mappings.items[self.mappings.items.len - 1].column > column)
        {
            var frame = self.mappings.pop().?;
            frame.keys.deinit(self.allocator);
        }
    }

    fn registerKey(self: *Validator, column: usize, key: []const u8) Error!void {
        if (self.mappings.items.len > 0 and
            self.mappings.items[self.mappings.items.len - 1].column == column)
        {
            const frame = &self.mappings.items[self.mappings.items.len - 1];
            for (frame.keys.items) |existing| {
                if (std.mem.eql(u8, existing, key)) {
                    return self.fail("duplicated key in mapping: {s}", .{key});
                }
            }
            try frame.keys.append(self.allocator, key);
            return;
        }
        var frame = MappingFrame{ .column = column };
        try frame.keys.append(self.allocator, key);
        try self.mappings.append(self.allocator, frame);
    }
};

/// Tracks flow brackets and quoted scalars across lines.
///
/// Unlike the structural scan, a quote only opens a scalar at the start of a node,
/// so an apostrophe inside a plain scalar (`it's fine`) is not treated as a quote.
fn scanFlow(line: []const u8, initial_quote: ?u8) FlowScan {
    var flow = FlowScan{ .quote = initial_quote };
    var depth: isize = 0;
    var quote = initial_quote;
    var position: usize = 0;
    var previous_non_space: u8 = 0;
    while (position < line.len) {
        const byte = line[position];
        if (quote) |active| {
            if (active == '"') {
                if (byte == '\\') {
                    position += 2;
                    continue;
                }
                if (byte == '"') {
                    quote = null;
                    previous_non_space = '"';
                }
            } else if (byte == '\'') {
                if (position + 1 < line.len and line[position + 1] == '\'') {
                    position += 2;
                    continue;
                }
                quote = null;
                previous_non_space = '\'';
            }
            position += 1;
            continue;
        }
        switch (byte) {
            '#' => {
                if (position == 0 or line[position - 1] == ' ' or line[position - 1] == '\t') {
                    flow.depth = if (depth > 0) @intCast(depth) else 0;
                    flow.delta = depth;
                    flow.quote = quote;
                    return flow;
                }
                previous_non_space = byte;
                position += 1;
            },
            '"', '\'' => {
                if (startsNode(previous_non_space)) {
                    quote = byte;
                } else {
                    previous_non_space = byte;
                }
                position += 1;
            },
            '[', '{' => {
                depth += 1;
                previous_non_space = byte;
                position += 1;
            },
            ']', '}' => {
                depth -= 1;
                previous_non_space = byte;
                position += 1;
            },
            ' ', '\t' => position += 1,
            else => {
                previous_non_space = byte;
                position += 1;
            },
        }
    }
    flow.depth = if (depth > 0) @intCast(depth) else 0;
    flow.delta = depth;
    flow.quote = quote;
    return flow;
}

/// Whether `previous_non_space` indicates the start of a YAML node.
fn startsNode(previous_non_space: u8) bool {
    return switch (previous_non_space) {
        0, ':', '-', '[', '{', ',', '?' => true,
        else => false,
    };
}

fn anchorName(line: []const u8, start: usize) []const u8 {
    var end = start;
    while (end < line.len) : (end += 1) {
        switch (line[end]) {
            ' ', '\t', '[', ']', '{', '}', ',' => break,
            else => {},
        }
    }
    return line[start..end];
}

/// Rewrites the indentation of every line.
///
/// Output is produced line by line: the text of a line (minus its leading spaces)
/// is copied verbatim, so nothing except indentation and insignificant trailing
/// whitespace can change.
fn reindent(allocator: Allocator, input: []const u8) Allocator.Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, input.len + input.len / 8);

    var frames = std.ArrayList(Frame).empty;
    defer frames.deinit(allocator);
    var continuation: ?Continuation = null;
    var block: ?BlockScalar = null;
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

        const incoming_quote = if (continuation) |state| state.quote else null;
        const scan = scanLine(line, incoming_quote);

        // 1. Content of a block scalar: only the leading indentation moves, and
        //    trailing whitespace is kept because it belongs to the value.
        if (block) |active| {
            if (scan.indent >= line.len) continue;
            var base_orig = active.base_orig;
            if (base_orig == null) {
                base_orig = scan.indent;
                block = .{ .base_orig = scan.indent, .base_new = active.base_new };
            }
            if (scan.indent >= base_orig.?) {
                try indent_module.pushSpaces(&output, allocator, active.base_new + (scan.indent - base_orig.?));
                try output.appendSlice(allocator, line[scan.indent..]);
                continue;
            }
            block = null;
        }

        // 2. Continuation of a multi-line quoted scalar or flow collection: the
        //    text is kept as written, indented one step past the opening line.
        if (continuation) |active| {
            if (scan.indent < line.len) {
                try indent_module.pushSpaces(&output, allocator, active.indent + STEP);
                try output.appendSlice(allocator, line[scan.indent..]);
            }
            const adjusted = @as(isize, @intCast(active.depth)) + scan.flow_delta;
            const depth: usize = if (adjusted > 0) @intCast(adjusted) else 0;
            continuation = if (depth == 0 and scan.quote == null)
                null
            else
                .{ .indent = active.indent, .depth = depth, .quote = scan.quote };
            continue;
        }

        // 3. Blank, comment, directive and document marker lines.
        if (scan.indent >= line.len) continue;
        if (scan.comment_only) {
            const level = if (frames.items.len > 0) frames.items[frames.items.len - 1].new else 0;
            try indent_module.pushSpaces(&output, allocator, level);
            try output.appendSlice(allocator, std.mem.trimEnd(u8, line[scan.indent..], " \t"));
            continue;
        }
        if (scan.directive) {
            try output.appendSlice(allocator, std.mem.trimEnd(u8, line[scan.indent..], " \t"));
            continue;
        }
        if (scan.document_marker) {
            frames.clearRetainingCapacity();
            block = null;
            try output.appendSlice(allocator, std.mem.trimEnd(u8, line[scan.indent..], " \t"));
            continue;
        }

        // 4. A structural line: first drop the levels it is no longer inside.
        while (frames.items.len > 0) {
            const top = frames.items[frames.items.len - 1];
            const closes = scan.indent < top.orig or
                (!scan.seq_item and top.kind == .seq and scan.indent <= top.orig);
            if (!closes) break;
            _ = frames.pop();
        }

        if (frames.items.len == 0) {
            try frames.append(allocator, .{
                .kind = if (scan.seq_item) .seq else .map,
                .orig = scan.indent,
                .new = 0,
                .block_orig = scan.indent,
                .block_new = 0,
                .pending_value = scan.bare_key,
            });
        } else {
            const top = frames.items[frames.items.len - 1];
            if (scan.indent > top.orig or (scan.seq_item and top.kind != .seq and top.pending_value)) {
                // A value block one step in, or a `- ` belonging to the bare
                // `key:` above it even though it sits at the same indentation.
                const new_indent = top.block_new + STEP;
                try frames.append(allocator, .{
                    .kind = if (scan.seq_item) .seq else .map,
                    .orig = scan.indent,
                    .new = new_indent,
                    .block_orig = scan.indent,
                    .block_new = new_indent,
                    .pending_value = scan.bare_key,
                });
            } else {
                frames.items[frames.items.len - 1].pending_value = scan.bare_key;
            }
        }

        const level = if (frames.items.len > 0) frames.items[frames.items.len - 1].new else 0;

        // A `- key: value` line continues as a mapping aligned two columns past the
        // dash, which is the shape the Go version produced and the shape `libyaml`
        // uses.
        if (scan.seq_item and scan.item_mapping) {
            const offset = scan.item_start - scan.indent;
            try frames.append(allocator, .{
                .kind = .map,
                .orig = scan.item_start,
                .new = level + offset,
                .block_orig = scan.indent,
                .block_new = level,
                .pending_value = scan.bare_key,
            });
        }

        try indent_module.pushSpaces(&output, allocator, level);
        const text = line[scan.indent..];
        if (scan.quote != null or scan.flow_depth > 0) {
            // The line continues inside a scalar: keep it exactly as written.
            try output.appendSlice(allocator, text);
        } else {
            try output.appendSlice(allocator, std.mem.trimEnd(u8, text, " \t"));
        }

        if (scan.block_scalar) {
            const block_orig = if (frames.items.len > 0)
                frames.items[frames.items.len - 1].block_orig
            else
                scan.indent;
            const block_new = if (frames.items.len > 0)
                frames.items[frames.items.len - 1].block_new
            else
                level;
            block = .{
                .base_orig = if (scan.block_indent) |indicator| block_orig + indicator else null,
                .base_new = if (scan.block_indent) |indicator| block_new + indicator else block_new + STEP,
            };
        } else if (scan.flow_depth > 0 or scan.quote != null) {
            continuation = .{ .indent = level, .depth = scan.flow_depth, .quote = scan.quote };
        }
    }

    return try output.toOwnedSlice(allocator);
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

/// Formats `input` twice and checks the second pass changes nothing, then returns
/// the result: every case below doubles as an idempotence test.
fn stable(input: []const u8) ![]u8 {
    const once = try formatText(input);
    errdefer std.testing.allocator.free(once);
    const twice = try formatText(once);
    defer std.testing.allocator.free(twice);
    try std.testing.expectEqualStrings(once, twice);
    return once;
}

fn expectStable(input: []const u8, expected: []const u8) !void {
    const text = try stable(input);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

test "converts fixture shaped documents to four spaces" {
    try expectStable(
        "# Formatter settings\nname: formatter\nnested:\n  enabled: true\n  items:\n    - one\n    - two\nmessage: |\n  Keep this text.\n  And this line.",
        "# Formatter settings\nname: formatter\nnested:\n    enabled: true\n    items:\n        - one\n        - two\nmessage: |\n    Keep this text.\n    And this line.",
    );
}

test "keeps comments anchors and documents" {
    try expectStable(
        "# settings\ndefaults: &defaults\n  enabled: true\ncopy: *defaults\nmessage: |\n  first\n  second\n---\nname: second",
        "# settings\ndefaults: &defaults\n    enabled: true\ncopy: *defaults\nmessage: |\n    first\n    second\n---\nname: second",
    );
}

test "indents sequences and compact sequences" {
    try expectStable("- one\n- two", "- one\n- two");
    try expectStable("items:\n- one\n- two", "items:\n    - one\n    - two");
    try expectStable(
        "value:\n  items:\n    - one\n    - two",
        "value:\n    items:\n        - one\n        - two",
    );
    try expectStable("- tags:\n  - one", "- tags:\n    - one");
}

test "aligns mappings inside sequence entries without moving them" {
    const input = "records:\n    - id: 9007199254740993\n      tags:\n        - production\n      metadata:\n        owner: team-00\n      notes: |\n        First line.\n        Second line.\n      optional: null";
    try expectStable(input, input);
}

test "reindents two space sequence entries" {
    try expectStable(
        "records:\n  - id: 1\n    tags:\n      - production\n    metadata:\n      owner: team-00\n    notes: |\n      First line.",
        "records:\n    - id: 1\n      tags:\n        - production\n      metadata:\n        owner: team-00\n      notes: |\n        First line.",
    );
}

test "keeps indented comments with their level" {
    try expectStable(
        "outer:\n  inner: 1\n  # indented comment\n  other: 2",
        "outer:\n    inner: 1\n    # indented comment\n    other: 2",
    );
}

test "keeps trailing comments blank lines and tabs" {
    try expectStable("name: value # trailing comment", "name: value # trailing comment");
    try expectStable("name: value\n\n\nother: 2", "name: value\n\n\nother: 2");
    try expectStable("body: |\n  column\tvalue\nnext: 1", "body: |\n    column\tvalue\nnext: 1");
}

test "keeps scalars that span lines" {
    try expectStable(
        "items: [one,\n  two,\n  three]\nnext: value",
        "items: [one,\n    two,\n    three]\nnext: value",
    );
    try expectStable(
        "key: this is a long\n  plain scalar continued\nnext: value",
        "key: this is a long\n    plain scalar continued\nnext: value",
    );
    try expectStable(
        "key: \"first part\n  second part\"\nnext: value",
        "key: \"first part\n    second part\"\nnext: value",
    );
}

test "keeps block scalar headers trailing whitespace and content" {
    try expectStable("message: >\n  folded text\nnext: value", "message: >\n    folded text\nnext: value");
    try expectStable("message: |2\n   indented body\nnext: value", "message: |2\n   indented body\nnext: value");
    try expectStable("message: |-\n  keep\n  trailing\n", "message: |-\n    keep\n    trailing\n");
    try expectStable("body: |\n  text   \nnext: 1", "body: |\n    text   \nnext: 1");
    try expectStable("key: value   \nother: 2\t", "key: value\nother: 2");
}

test "keeps directives markers and scalars" {
    try expectStable("---\nname: test", "---\nname: test");
    try expectStable("---", "---");
    try expectStable("hello", "hello");
    try expectStable("%YAML 1.2\n---\nname: test", "%YAML 1.2\n---\nname: test");
    try expectStable("{name: test, items: [one, two]}", "{name: test, items: [one, two]}");
}

fn expectRejected(input: []const u8) !void {
    if (rejectionMessage(input)) |message| {
        std.testing.allocator.free(message);
        return;
    } else |err| switch (err) {
        error.ExpectedRejection => {
            std.debug.print("expected {s} to be rejected\n", .{input});
            return error.ExpectedRejection;
        },
        error.OutOfMemory => return error.OutOfMemory,
    }
}

test "rejects malformed yaml duplicate keys and unknown aliases" {
    for ([_][]const u8{
        "name: formatter\nitems: [one, two",
        "name: first\n---\nitems: [broken",
        "name: first\nname: second",
        "name: *missing",
    }) |input| {
        try expectRejected(input);
    }

    const alias_message = try rejectionMessage("name: *missing");
    defer std.testing.allocator.free(alias_message);
    try std.testing.expect(std.mem.indexOf(u8, alias_message, "anchor") != null);

    const duplicate_message = try rejectionMessage("name: first\nname: second");
    defer std.testing.allocator.free(duplicate_message);
    try std.testing.expect(std.mem.indexOf(u8, duplicate_message, "duplicated key") != null);

    const comment_message = try rejectionMessage("# comment only");
    defer std.testing.allocator.free(comment_message);
    try std.testing.expectEqualStrings("no YAML document provided", comment_message);
}

test "resolves anchors defined in the same document" {
    try expectStable("base: &b\n    x: 1\ncopy: *b", "base: &b\n    x: 1\ncopy: *b");
    // Anchors are document scoped, so the alias below has nothing to resolve to.
    const message = try rejectionMessage("a: &b 1\n---\nc: *b");
    defer std.testing.allocator.free(message);
    try std.testing.expect(std.mem.indexOf(u8, message, "anchor") != null);
}

test "ignores asterisks that are not aliases" {
    const input = "glob: '*.txt'\nmath: 2 * 3\n# *not an alias\nend: 1";
    try expectStable(input, input);
}

test "generated stress shaped input stays stable" {
    var input = std.ArrayList(u8).empty;
    defer input.deinit(std.testing.allocator);
    for (0..40) |index| {
        if (index > 0) try input.appendSlice(std.testing.allocator, "\n---\n");
        const document = try std.fmt.allocPrint(
            std.testing.allocator,
            "id: 9007199254740993\nname: service-{d:0>4}\nenabled: false\ntags:\n  - production\n  - region-{d}\nmetadata:\n  owner: team-00\n  url: https://example.com/items/{d}\nnotes: |\n  First line with a colon: value and # hash.\n  Second line with \"quotes\" and <html>.",
            .{ index, index % 12, index },
        );
        defer std.testing.allocator.free(document);
        try input.appendSlice(std.testing.allocator, document);
    }

    const formatted = try stable(input.items);
    defer std.testing.allocator.free(formatted);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "9007199254740993") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "\ntags:\n    - production\n") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        formatted,
        "\nnotes: |\n    First line with a colon: value and # hash.",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "\n---\n") != null);
}
