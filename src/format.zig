//! Format selection: detect the input, dispatch to the right formatter, and wrap
//! failures in the same messages the JavaScript layer reports to users.

const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const csv = @import("csv.zig");
const html = @import("html.zig");
const json = @import("json.zig");
const toml = @import("toml.zig");
const xml = @import("xml.zig");
const yaml = @import("yaml.zig");

const Allocator = std.mem.Allocator;

/// The format a document was treated as.
pub const Format = enum {
    json,
    yaml,
    xml,
    html,
    toml,
    csv,
    tsv,

    /// Name used by the bridge and by the regression tests.
    pub fn asText(self: Format) []const u8 {
        return switch (self) {
            .json => "json",
            .yaml => "yaml",
            .xml => "xml",
            .html => "html",
            .toml => "toml",
            .csv => "csv",
            .tsv => "tsv",
        };
    }

    /// Upper-case name used in error messages.
    fn upperName(self: Format) []const u8 {
        return switch (self) {
            .json => "JSON",
            .yaml => "YAML",
            .xml => "XML",
            .html => "HTML",
            .toml => "TOML",
            .csv => "CSV",
            .tsv => "TSV",
        };
    }
};

/// A successfully formatted document.
pub const Formatted = struct {
    text: []u8,
    format: Format,
};

/// Either the formatted document or an owned rejection message.
pub const Outcome = union(enum) {
    formatted: Formatted,
    rejected: []u8,

    /// Releases whichever buffer this outcome owns.
    pub fn deinit(self: Outcome, allocator: Allocator) void {
        switch (self) {
            .formatted => |value| allocator.free(value.text),
            .rejected => |message| allocator.free(message),
        }
    }
};

/// Formats `input` using `mode`, which is `"auto"`, `"json"`, `"yaml"`, `"xml"`,
/// `"html"`, `"toml"`, `"csv"` or `"tsv"`.
///
/// Blank input is rejected with `no input provided`, an unrecognised mode with
/// `unknown format "x"`, and a document that does not parse with an
/// `invalid <FORMAT>: …` message.
pub fn format(allocator: Allocator, input: []const u8, mode: []const u8) Allocator.Error!Outcome {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) {
        return .{ .rejected = try allocator.dupe(u8, "no input provided") };
    }
    const selection = try selectFormat(allocator, trimmed, mode);
    switch (selection) {
        .format => |chosen| return formatAs(allocator, trimmed, chosen),
        .rejected => |message| return .{ .rejected = message },
    }
}

const Selection = union(enum) {
    format: Format,
    rejected: []u8,
};

fn selectFormat(allocator: Allocator, input: []const u8, mode: []const u8) Allocator.Error!Selection {
    if (mode.len == 0 or std.mem.eql(u8, mode, "auto")) {
        // JSON first: a valid JSON document is never ambiguous with the others.
        const valid_json = try json.isValid(allocator, input);
        if (valid_json or looksLikeJson(input)) return .{ .format = .json };
        // Markup-looking input is XML when it is well-formed, and HTML
        // otherwise: HTML accepts void elements, optional end tags and raw-text
        // elements, which XML does not.
        if (input.len > 0 and input[0] == '<') {
            if (try xml.isValid(allocator, input)) return .{ .format = .xml };
            return .{ .format = .html };
        }
        // TOML is only chosen when it parses and has an assignment line, so a
        // YAML plain scalar such as `hello` stays YAML.
        if (toml.looksLikeToml(input)) return .{ .format = .toml };
        // CSV and TSV overlap too much with YAML to be auto-detected safely, so
        // they are selected explicitly.
        return .{ .format = .yaml };
    }
    if (std.mem.eql(u8, mode, "json")) return .{ .format = .json };
    if (std.mem.eql(u8, mode, "yaml")) return .{ .format = .yaml };
    if (std.mem.eql(u8, mode, "xml")) return .{ .format = .xml };
    if (std.mem.eql(u8, mode, "html")) return .{ .format = .html };
    if (std.mem.eql(u8, mode, "toml")) return .{ .format = .toml };
    if (std.mem.eql(u8, mode, "csv")) return .{ .format = .csv };
    if (std.mem.eql(u8, mode, "tsv")) return .{ .format = .tsv };
    return .{ .rejected = try std.fmt.allocPrint(allocator, "unknown format \"{s}\"", .{mode}) };
}

fn formatAs(allocator: Allocator, input: []const u8, chosen: Format) Allocator.Error!Outcome {
    var diag = diagnostic.Diagnostic.init(allocator);
    defer diag.deinit();

    const text = switch (chosen) {
        .json => json.indent(allocator, input, &diag),
        .yaml => yaml.format(allocator, input, &diag),
        .xml => xml.format(allocator, input, &diag),
        .html => html.format(allocator, input, &diag),
        .toml => toml.format(allocator, input, &diag),
        .csv => csv.format(allocator, input, &diag, .comma),
        .tsv => csv.format(allocator, input, &diag, .tab),
    } catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return .{ .rejected = try std.fmt.allocPrint(
            allocator,
            "invalid {s}: {s}",
            .{ chosen.upperName(), diag.message },
        ) },
    };
    return .{ .formatted = .{ .text = text, .format = chosen } };
}

/// Mirrors the historical detection heuristic used when input is not valid JSON.
///
/// Some JSON-like collections are already valid YAML, so they would otherwise be
/// interpreted as YAML and errors would be silently accepted. In auto-detect, an
/// input that starts like a JSON collection but does not validate as JSON keeps
/// going down the JSON path and reports a JSON error, which is what users expect
/// from "format this JSON". Selecting YAML explicitly still interprets it as YAML.
fn looksLikeJson(input: []const u8) bool {
    var remaining = input;
    var stripped_brackets = false;
    while (remaining.len > 0 and remaining[0] == '[') {
        remaining = std.mem.trimStart(u8, remaining[1..], " \t\r\n");
        stripped_brackets = true;
    }

    if (remaining.len > 0 and remaining[0] == '{') {
        const rest = std.mem.trimStart(u8, remaining[1..], " \t\r\n");
        return rest.len == 0 or rest[0] == '"' or rest[0] == '}';
    }

    if (!stripped_brackets) return false;
    if (remaining.len == 0) return true;
    switch (remaining[0]) {
        '"', '-', '0'...'9', ']' => return true,
        else => {},
    }
    for ([_][]const u8{ "true", "false", "null" }) |literal| {
        if (std.mem.eql(u8, remaining, literal)) return true;
        if (remaining.len > literal.len and std.mem.startsWith(u8, remaining, literal)) {
            switch (remaining[literal.len]) {
                ',', ']', ' ' => return true,
                else => {},
            }
        }
    }
    return false;
}

fn formatText(input: []const u8, mode: []const u8) ![]u8 {
    const outcome = try format(std.testing.allocator, input, mode);
    switch (outcome) {
        .formatted => |result| return result.text,
        .rejected => |message| {
            defer std.testing.allocator.free(message);
            std.debug.print("unexpected rejection of {s}: {s}\n", .{ input, message });
            return error.UnexpectedRejection;
        },
    }
}

fn rejection(input: []const u8, mode: []const u8) ![]u8 {
    const outcome = try format(std.testing.allocator, input, mode);
    switch (outcome) {
        .formatted => |result| {
            std.testing.allocator.free(result.text);
            std.debug.print("expected {s} to be rejected\n", .{input});
            return error.ExpectedRejection;
        },
        .rejected => |message| return message,
    }
}

test "detects json and yaml" {
    const cases = [_]struct { input: []const u8, expected: Format }{
        .{ .input = "\"https://example.com\"", .expected = .json },
        .{ .input = "[{\"name\":\"test\"}]", .expected = .json },
        .{ .input = "[1,2,3]", .expected = .json },
        .{ .input = "true", .expected = .json },
        .{ .input = "null", .expected = .json },
        .{ .input = "42", .expected = .json },
        .{ .input = "hello", .expected = .yaml },
        .{ .input = "\"name\": test", .expected = .yaml },
        .{ .input = "{name: test, items: [one, two]}", .expected = .yaml },
        .{ .input = "[one, two]", .expected = .yaml },
        .{ .input = "- one\n- two", .expected = .yaml },
        .{ .input = "---\nname: test", .expected = .yaml },
    };
    for (&cases) |case| {
        const outcome = try format(std.testing.allocator, case.input, "auto");
        defer outcome.deinit(std.testing.allocator);
        switch (outcome) {
            .formatted => |result| try std.testing.expectEqual(case.expected, result.format),
            .rejected => |message| {
                std.debug.print("unexpected rejection of {s}: {s}\n", .{ case.input, message });
                return error.UnexpectedRejection;
            },
        }
    }
}

test "reports blank input and unknown modes" {
    const blank = try rejection("", "auto");
    defer std.testing.allocator.free(blank);
    try std.testing.expectEqualStrings("no input provided", blank);

    const spaces = try rejection("  \n", "yaml");
    defer std.testing.allocator.free(spaces);
    try std.testing.expectEqualStrings("no input provided", spaces);

    const unknown = try rejection("name: test", "ini");
    defer std.testing.allocator.free(unknown);
    try std.testing.expectEqualStrings("unknown format \"ini\"", unknown);
}

test "forced modes do not fall back" {
    const json_error = try rejection("name: test", "json");
    defer std.testing.allocator.free(json_error);
    try std.testing.expect(std.mem.startsWith(u8, json_error, "invalid JSON:"));
    try std.testing.expectEqualStrings(
        "invalid JSON: invalid character 'a' in literal null (expecting 'u') at offset 1",
        json_error,
    );

    const as_yaml = try formatText("{\"name\":\"test\"}", "yaml");
    defer std.testing.allocator.free(as_yaml);
    try std.testing.expectEqualStrings("{\"name\":\"test\"}", as_yaml);
}

test "malformed json reports a json error when detecting" {
    for ([_][]const u8{ "{\"name\":}", "[{\"name\":}]", "[1,2,]", "[true,false,]" }) |input| {
        const message = try rejection(input, "auto");
        defer std.testing.allocator.free(message);
        try std.testing.expect(std.mem.startsWith(u8, message, "invalid JSON:"));
    }
}

test "detects xml and toml and selects csv explicitly" {
    const cases = [_]struct { input: []const u8, mode: []const u8, expected: Format }{
        .{ .input = "<?xml version=\"1.0\"?>\n<root><a>1</a></root>", .mode = "auto", .expected = .xml },
        .{ .input = "<a><b/></a>", .mode = "auto", .expected = .xml },
        .{ .input = "<div><br></div>", .mode = "auto", .expected = .html },
        .{ .input = "<!DOCTYPE html>\n<html><body><p>x</p></body></html>", .mode = "auto", .expected = .xml },
        .{ .input = "title = \"Formatter\"\n[owner]\nname = \"team\"", .mode = "auto", .expected = .toml },
        .{ .input = "a,b\nc,d", .mode = "csv", .expected = .csv },
        .{ .input = "a\tb\nc\td", .mode = "tsv", .expected = .tsv },
    };
    for (&cases) |case| {
        const outcome = try format(std.testing.allocator, case.input, case.mode);
        defer outcome.deinit(std.testing.allocator);
        switch (outcome) {
            .formatted => |result| try std.testing.expectEqual(case.expected, result.format),
            .rejected => |message| {
                std.debug.print("unexpected rejection of {s}: {s}\n", .{ case.input, message });
                return error.UnexpectedRejection;
            },
        }
    }
}

test "formats the added file types" {
    const cases = [_]struct { input: []const u8, mode: []const u8, expected: []const u8 }{
        .{
            .input = "<a><b>1</b></a>",
            .mode = "xml",
            .expected = "<a>\n    <b>1</b>\n</a>",
        },
        .{
            .input = "<div><br><p>x</p></div>",
            .mode = "html",
            .expected = "<div>\n    <br>\n    <p>x</p>\n</div>",
        },
        .{
            .input = "a=1\nlist=[\n 1,\n 2,\n]",
            .mode = "toml",
            .expected = "a = 1\nlist = [\n    1,\n    2,\n]",
        },
        .{
            .input = "\"a,b\",c\n",
            .mode = "csv",
            .expected = "\"a,b\",c\n",
        },
        .{
            .input = "a\t\"x\ty\"\n",
            .mode = "tsv",
            .expected = "a\t\"x\ty\"\n",
        },
    };
    for (&cases) |case| {
        const text = try formatText(case.input, case.mode);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings(case.expected, text);
    }
}

test "malformed markup reports an html error when it is not xml" {
    const message = try rejection("<a><b></a>", "auto");
    defer std.testing.allocator.free(message);
    try std.testing.expect(std.mem.startsWith(u8, message, "invalid HTML:"));
}
