//! Generates the stress fixtures in `test/stress`.
//!
//! Run from the repository root:
//!
//! ```powershell
//! zig build generate-stress
//! ```
//!
//! The fixtures are deliberately large — a few thousand records, 300 documents and
//! 128 levels of nesting — so the formatter can be exercised on input far bigger
//! than a hand written example, and so its stability can be checked at that size.

const std = @import("std");

const RECORDS: usize = 3000;
const STREAM_DOCUMENTS: usize = 300;
const NESTING_DEPTH: usize = 128;
const BIG_INTEGER: i64 = 9_007_199_254_740_993;
const PATH_VALUE = "C:\\data\\imports\\records.json";
const NOTES = "First line with a colon: value and # hash.\nSecond line with \"quotes\", a tab\tand <html>.";

const Record = struct {
    id: i64,
    name: []const u8,
    enabled: bool,
    region: usize,
    owner: []const u8,
    url: []const u8,
    fourth_sample: f64,

    fn init(allocator: std.mem.Allocator, index: usize) !Record {
        return .{
            .id = BIG_INTEGER + @as(i64, @intCast(index)),
            .name = try std.fmt.allocPrint(allocator, "service-{d:0>4}", .{index}),
            .enabled = index % 3 != 0,
            .region = index % 12,
            .owner = try std.fmt.allocPrint(allocator, "team-{d:0>2}", .{index % 40}),
            .url = try std.fmt.allocPrint(
                allocator,
                "https://example.com/api/items/{d}?active=true&limit=100",
                .{index},
            ),
            .fourth_sample = @as(f64, @floatFromInt(index)) / 8.0,
        };
    }
};

pub fn main(init: std.process.Init) !void {
    // The generator is short lived, so the process arena owns every allocation.
    const allocator = init.arena.allocator();
    const io = init.io;

    try std.Io.Dir.cwd().createDirPath(io, "test/stress");

    const records = try allocator.alloc(Record, RECORDS);
    for (records, 0..) |*record, index| {
        record.* = try Record.init(allocator, index);
    }

    var json = std.ArrayList(u8).empty;
    try json.appendSlice(allocator, "{\"name\":\"large-record-set\",\"records\":");
    try recordsJson(&json, allocator, records);
    try json.append(allocator, '}');
    try write(io, allocator, "large-valid.json", json.items);
    try write(io, allocator, "large-invalid.json", json.items[0 .. json.items.len - 1]);

    const deep = try deepJson(allocator);
    try write(io, allocator, "deep-valid.json", deep);

    var yaml = std.ArrayList(u8).empty;
    try yaml.appendSlice(allocator, "name: large-record-set\nrecords:\n");
    for (records) |record| {
        try recordYamlEntry(&yaml, allocator, record, 4, 4);
    }
    try write(io, allocator, "large-valid.yaml", yaml.items);

    var invalid_yaml = std.ArrayList(u8).empty;
    try invalid_yaml.appendSlice(allocator, yaml.items);
    try invalid_yaml.appendSlice(allocator, "broken: [unterminated\n");
    try write(io, allocator, "large-invalid.yaml", invalid_yaml.items);

    var stream = std.ArrayList(u8).empty;
    for (records[0..STREAM_DOCUMENTS], 0..) |record, index| {
        if (index > 0) try stream.appendSlice(allocator, "---\n");
        try recordYamlBody(&stream, allocator, record, 0, 0, 2, true);
    }
    try write(io, allocator, "stream-valid.yaml", stream.items);
}

fn write(io: std.Io, allocator: std.mem.Allocator, name: []const u8, content: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, "test/stress/{s}", .{name});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
    std.debug.print("{s:<20} {d:>10} bytes\n", .{ name, content.len });
}

fn booleanText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn spaces(allocator: std.mem.Allocator, count: usize) ![]u8 {
    const buffer = try allocator.alloc(u8, count);
    @memset(buffer, ' ');
    return buffer;
}

fn recordsJson(out: *std.ArrayList(u8), allocator: std.mem.Allocator, records: []const Record) !void {
    var escaped_path = std.ArrayList(u8).empty;
    try jsonEscape(&escaped_path, allocator, PATH_VALUE);
    var escaped_notes = std.ArrayList(u8).empty;
    try jsonEscape(&escaped_notes, allocator, NOTES);

    try out.append(allocator, '[');
    for (records, 0..) |record, index| {
        if (index > 0) try out.append(allocator, ',');
        var escaped_url = std.ArrayList(u8).empty;
        try jsonEscape(&escaped_url, allocator, record.url);
        const entry = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":{d},\"name\":\"{s}\",\"enabled\":{s},\"tags\":[\"production\",\"stress-test\",\"region-{d}\"],\"metadata\":{{\"owner\":\"{s}\",\"path\":\"{s}\",\"url\":\"{s}\"}},\"samples\":[0,1.25,-3.5,{d},1000000.125],\"notes\":\"{s}\",\"optional\":null}}",
            .{
                record.id,
                record.name,
                booleanText(record.enabled),
                record.region,
                record.owner,
                escaped_path.items,
                escaped_url.items,
                record.fourth_sample,
                escaped_notes.items,
            },
        );
        try out.appendSlice(allocator, entry);
    }
    try out.append(allocator, ']');
}

/// Escapes a string the way Go's `encoding/json` does: short escapes for the
/// control characters that have one, and `\u00xx` for `<`, `>` and `&`, so the
/// fixtures also cover HTML-escape preservation.
fn jsonEscape(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    for (value) |character| {
        switch (character) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            '<' => try out.appendSlice(allocator, "\\u003c"),
            '>' => try out.appendSlice(allocator, "\\u003e"),
            '&' => try out.appendSlice(allocator, "\\u0026"),
            else => {
                if (character < 0x20) {
                    var buffer: [8]u8 = undefined;
                    const escape = try std.fmt.bufPrint(&buffer, "\\u{x:0>4}", .{character});
                    try out.appendSlice(allocator, escape);
                } else {
                    try out.append(allocator, character);
                }
            },
        }
    }
}

fn deepJson(allocator: std.mem.Allocator) ![]u8 {
    var value = try std.fmt.allocPrint(allocator, "{{\"leaf\":\"deepest\",\"number\":{d}}}", .{BIG_INTEGER});
    var level: usize = 0;
    while (level < NESTING_DEPTH) : (level += 1) {
        value = try std.fmt.allocPrint(
            allocator,
            "{{\"children\":[{s}],\"level\":{d},\"padding\":\"nested JSON stress fixture\"}}",
            .{ value, level },
        );
    }
    return value;
}

/// Writes one record as a mapping. Nested content sits `step` columns past the
/// mapping's own block indentation, which is the shape both `libyaml` and this
/// formatter use. `include_id` is false when the caller has already written the id
/// on a sequence entry's dash line.
fn recordYamlBody(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    record: Record,
    key_indent: usize,
    block: usize,
    step: usize,
    include_id: bool,
) !void {
    const keys = try spaces(allocator, key_indent);
    const nested = try spaces(allocator, block + step);
    if (include_id) {
        const line = try std.fmt.allocPrint(allocator, "{s}id: {d}\n", .{ keys, record.id });
        try out.appendSlice(allocator, line);
    }

    const body = try std.fmt.allocPrint(
        allocator,
        "{s}name: {s}\n{s}enabled: {s}\n{s}tags:\n{s}- production\n{s}- stress-test\n{s}- region-{d}\n{s}metadata:\n{s}owner: {s}\n{s}path: {s}\n{s}url: {s}\n{s}samples:\n{s}- 0\n{s}- 1.25\n{s}- -3.5\n{s}- {d}\n{s}- 1000000.125\n",
        .{
            keys,
            record.name,
            keys,
            booleanText(record.enabled),
            keys,
            nested,
            nested,
            nested,
            record.region,
            keys,
            nested,
            record.owner,
            nested,
            PATH_VALUE,
            nested,
            record.url,
            keys,
            nested,
            nested,
            nested,
            nested,
            record.fourth_sample,
            nested,
        },
    );
    try out.appendSlice(allocator, body);

    const notes_header = try std.fmt.allocPrint(allocator, "{s}notes: |\n", .{keys});
    try out.appendSlice(allocator, notes_header);
    var lines = std.mem.splitScalar(u8, NOTES, '\n');
    while (lines.next()) |line| {
        const notes_line = try std.fmt.allocPrint(allocator, "{s}{s}\n", .{ nested, line });
        try out.appendSlice(allocator, notes_line);
    }

    const optional = try std.fmt.allocPrint(allocator, "{s}optional: null\n", .{keys});
    try out.appendSlice(allocator, optional);
}

/// Writes one record as a sequence entry: the id shares the `- ` line and the rest
/// of the mapping is aligned two columns past the dash.
fn recordYamlEntry(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    record: Record,
    item_indent: usize,
    step: usize,
) !void {
    const dash = try spaces(allocator, item_indent);
    const line = try std.fmt.allocPrint(allocator, "{s}- id: {d}\n", .{ dash, record.id });
    try out.appendSlice(allocator, line);
    try recordYamlBody(out, allocator, record, item_indent + 2, item_indent, step, false);
}
