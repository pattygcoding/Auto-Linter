//! Browser-based JSON and YAML formatter, compiled to WebAssembly with Zig.
//!
//! The formatting rules are deliberately conservative: input is validated with a
//! real parser, then re-indented with four spaces per level. Everything else about
//! the document — key order, comments, anchors, quoting, numeric precision — is
//! preserved exactly as the author wrote it.
//!
//! * [`format`] is the mode-aware entry point used by the WebAssembly bridge and
//!   by the tests.
//! * [`json`] validates and indents JSON.
//! * [`yaml`] validates YAML and normalises indentation without re-serialising.

const indent = @import("indent.zig");
const format_module = @import("format.zig");

pub const diagnostic = @import("diagnostic.zig");
pub const csv = @import("csv.zig");
pub const html = @import("html.zig");
pub const json = @import("json.zig");
pub const toml = @import("toml.zig");
pub const xml = @import("xml.zig");
pub const yaml = @import("yaml.zig");

/// One indentation level used for both JSON and YAML output.
pub const INDENT = indent.INDENT;

/// The format a document was treated as.
pub const Format = format_module.Format;

/// A successfully formatted document.
pub const Formatted = format_module.Formatted;

/// The result of formatting: either the formatted text or a rejection message.
pub const Outcome = format_module.Outcome;

/// Formats `input` using `mode`, which is `"auto"`, `"json"` or `"yaml"`.
pub const format = format_module.format;

test {
    _ = @import("csv.zig");
    _ = @import("format.zig");
    _ = @import("html.zig");
    _ = @import("json.zig");
    _ = @import("toml.zig");
    _ = @import("xml.zig");
    _ = @import("yaml.zig");
}
