//! Regression tests over the committed fixtures, mirroring the Go test suite that
//! this project used before the move to Zig.

const std = @import("std");
const formatter = @import("formatter");

const BIG_INTEGER = "9007199254740993";

const Fixture = struct {
    path: []const u8,
    expected: formatter.Format,
    invalid: bool,
};

const fixtures = [_]Fixture{
    .{ .path = "test/json/valid.json", .expected = .json, .invalid = false },
    .{ .path = "test/json/invalid.json", .expected = .json, .invalid = true },
    .{ .path = "test/yaml/valid.yaml", .expected = .yaml, .invalid = false },
    .{ .path = "test/yaml/invalid.yaml", .expected = .yaml, .invalid = true },
    .{ .path = "test/yaml/duplicate-keys.yaml", .expected = .yaml, .invalid = true },
    .{ .path = "test/yaml/multiple-documents.yaml", .expected = .yaml, .invalid = false },
    .{ .path = "test/yaml/list.yaml", .expected = .yaml, .invalid = false },
    .{ .path = "test/xml/valid.xml", .expected = .xml, .invalid = false },
    .{ .path = "test/xml/invalid.xml", .expected = .xml, .invalid = true },
    .{ .path = "test/html/valid.html", .expected = .html, .invalid = false },
    .{ .path = "test/html/invalid.html", .expected = .html, .invalid = true },
    .{ .path = "test/toml/valid.toml", .expected = .toml, .invalid = false },
    .{ .path = "test/toml/invalid.toml", .expected = .toml, .invalid = true },
    .{ .path = "test/csv/valid.csv", .expected = .csv, .invalid = false },
    .{ .path = "test/csv/invalid.csv", .expected = .csv, .invalid = true },
    .{ .path = "test/csv/valid.tsv", .expected = .tsv, .invalid = false },
};

fn readFixture(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .unlimited);
}

fn rejectionPrefix(expected: formatter.Format) []const u8 {
    return switch (expected) {
        .json => "invalid JSON:",
        .yaml => "invalid YAML:",
        .xml => "invalid XML:",
        .html => "invalid HTML:",
        .toml => "invalid TOML:",
        .csv => "invalid CSV:",
        .tsv => "invalid TSV:",
    };
}

test "fixtures format or report errors" {
    const allocator = std.testing.allocator;
    for (&fixtures) |fixture| {
        const input = try readFixture(allocator, fixture.path);
        defer allocator.free(input);

        const modes = [_][]const u8{ "auto", fixture.expected.asText() };
        for (modes, 0..) |mode, index| {
            // CSV and TSV are selected explicitly, auto-detection only chooses
            // TOML when it parses, and markup that is not well-formed XML is read
            // as HTML, so those fixtures use their explicit mode.
            if (index == 0 and (fixture.expected == .csv or fixture.expected == .tsv or
                ((fixture.expected == .toml or fixture.expected == .xml) and fixture.invalid))) continue;
            const outcome = try formatter.format(allocator, input, mode);
            defer outcome.deinit(allocator);

            switch (outcome) {
                .formatted => |result| {
                    try std.testing.expect(!fixture.invalid);
                    try std.testing.expectEqual(fixture.expected, result.format);

                    const repeated = try formatter.format(allocator, result.text, mode);
                    defer repeated.deinit(allocator);
                    switch (repeated) {
                        .formatted => |again| try std.testing.expectEqualStrings(result.text, again.text),
                        .rejected => |message| {
                            std.debug.print("{s} [{s}] is no longer valid: {s}\n", .{ fixture.path, mode, message });
                            return error.NotStable;
                        },
                    }
                },
                .rejected => |message| {
                    try std.testing.expect(fixture.invalid);
                    const prefix = rejectionPrefix(fixture.expected);
                    if (!std.mem.startsWith(u8, message, prefix)) {
                        std.debug.print("{s} [{s}] reported '{s}', expected a '{s}' error\n", .{
                            fixture.path,
                            mode,
                            message,
                            prefix,
                        });
                        return error.WrongErrorPrefix;
                    }
                },
            }
        }
    }
}

test "stress fixtures are formatted stably" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var directory = try std.Io.Dir.cwd().openDir(io, "test/stress", .{ .iterate = true });
    defer directory.close(io);

    var count: usize = 0;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        const is_json = std.mem.endsWith(u8, entry.name, ".json");
        const is_yaml = std.mem.endsWith(u8, entry.name, ".yaml");
        if (!is_json and !is_yaml) continue;
        count += 1;

        const name = try allocator.dupe(u8, entry.name);
        defer allocator.free(name);
        const path = try std.fmt.allocPrint(allocator, "test/stress/{s}", .{name});
        defer allocator.free(path);
        const input = try readFixture(allocator, path);
        defer allocator.free(input);

        const expected: formatter.Format = if (is_json) .json else .yaml;
        const invalid = std.mem.indexOf(u8, name, "-invalid.") != null;

        for ([_][]const u8{ "auto", expected.asText() }) |mode| {
            const outcome = try formatter.format(allocator, input, mode);
            defer outcome.deinit(allocator);
            switch (outcome) {
                .formatted => |result| {
                    try std.testing.expect(!invalid);
                    try std.testing.expectEqual(expected, result.format);
                    try std.testing.expect(std.mem.indexOf(u8, result.text, BIG_INTEGER) != null);

                    const repeated = try formatter.format(allocator, result.text, mode);
                    defer repeated.deinit(allocator);
                    switch (repeated) {
                        .formatted => |again| try std.testing.expectEqualStrings(result.text, again.text),
                        .rejected => |message| {
                            std.debug.print("{s} [{s}] is no longer valid: {s}\n", .{ name, mode, message });
                            return error.NotStable;
                        },
                    }
                },
                .rejected => |message| {
                    try std.testing.expect(invalid);
                    try std.testing.expect(std.mem.startsWith(u8, message, rejectionPrefix(expected)));
                },
            }
        }
    }

    try std.testing.expectEqual(@as(usize, 6), count);
}
