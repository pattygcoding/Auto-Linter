const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { before, test } = require("node:test");

const formatter = require("../formatter.js");

before(async () => {
    await formatter.init(fs.readFileSync(path.join(__dirname, "..", "formatter.wasm")));
    assert.equal(typeof globalThis.formatInput, "function");
});

for (const [file, format, invalid] of [
    ["json/valid.json", "json", false],
    ["json/invalid.json", "json", true],
    ["yaml/valid.yaml", "yaml", false],
    ["yaml/invalid.yaml", "yaml", true],
    ["yaml/duplicate-keys.yaml", "yaml", true],
    ["yaml/list.yaml", "yaml", false],
    ["yaml/multiple-documents.yaml", "yaml", false],
    ["xml/valid.xml", "xml", false],
    ["xml/invalid.xml", "xml", true],
    ["html/valid.html", "html", false],
    ["html/invalid.html", "html", true],
    ["toml/valid.toml", "toml", false],
    ["toml/invalid.toml", "toml", true],
    ["csv/valid.csv", "csv", false],
    ["csv/invalid.csv", "csv", true],
    ["csv/valid.tsv", "tsv", false],
]) {
    test(`WASM fixture: ${file}`, () => {
        const input = fs.readFileSync(path.join(__dirname, file), "utf8");
        // CSV/TSV are explicit-only, auto-detection only picks TOML when it
        // parses, and markup that is not well-formed XML is read as HTML, so
        // those invalid fixtures are checked with their explicit mode.
        const modes = format === "csv" || format === "tsv" || ((format === "toml" || format === "xml") && invalid)
            ? [format]
            : ["auto", format];
        for (const mode of modes) {
            const output = globalThis.formatInput(input, mode);
            if (invalid) {
                assert.match(output, new RegExp(`^invalid ${format.toUpperCase()}:`));
            } else {
                assert.doesNotMatch(output, /^invalid /);
                assert.equal(globalThis.formatInput(output, mode), output);
                if (format === "json") {
                    assert.match(output, /\n {4}"name":/);
                    assert.match(output, /9007199254740993/);
                }
            }
        }
    });
}

test("WASM bridge modes and legacy API", () => {
    assert.equal(globalThis.formatJSON, globalThis.formatInput);
    assert.equal(globalThis.AutoLinter, globalThis.FormatterWasm);
    assert.equal(typeof globalThis.AutoLinter.init, "function");
    assert.equal(globalThis.formatInput(), "No input provided.");
    assert.equal(globalThis.formatInput(null), "No input provided.");
    assert.equal(globalThis.formatInput("  "), "no input provided");
    assert.match(globalThis.formatInput("name: test", "json"), /^invalid JSON:/);
    assert.equal(globalThis.formatInput("///force:yaml///\n- one\n- two"), "- one\n- two");
    assert.equal(globalThis.formatInput("///force:json///{\"value\":1}"), "{\n    \"value\": 1\n}");
});

test("WASM bridge supports the added formats", () => {
    assert.equal(globalThis.formatInput("<a><b>1</b></a>", "xml"), "<a>\n    <b>1</b>\n</a>");
    assert.equal(globalThis.formatInput("<div><br></div>", "auto"), "<div>\n    <br>\n</div>");
    assert.equal(globalThis.formatInput("<div><br><p>x</p></div>", "html"), "<div>\n    <br>\n    <p>x</p>\n</div>");
    assert.equal(globalThis.formatInput("a=1\nlist=[\n 1,\n 2,\n]", "toml"), "a = 1\nlist = [\n    1,\n    2,\n]");
    assert.equal(globalThis.formatInput("a,b\nc,d", "csv"), "a,b\nc,d\n");
    assert.equal(globalThis.formatInput("a\tb\nc\td", "tsv"), "a\tb\nc\td\n");
    assert.equal(globalThis.formatInput("///force:xml///<a><b>1</b></a>"), "<a>\n    <b>1</b>\n</a>");
    assert.equal(globalThis.formatInput("///force:html///<div><br></div>"), "<div>\n    <br>\n</div>");
    assert.equal(globalThis.formatInput("///force:toml///a=1"), "a = 1");
    assert.equal(globalThis.formatInput("///force:csv///\"a,b\",c"), "\"a,b\",c\n");
    assert.equal(globalThis.formatInput("///force:tsv///a\tb"), "a\tb\n");
    assert.match(globalThis.formatInput("<a><b></a>", "auto"), /^invalid HTML:/);
});
