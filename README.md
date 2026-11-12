# Auto-Linter

Auto-Linter is a browser-based linter and formatter for JSON, YAML, XML, HTML,
TOML, CSV and TSV, powered by Zig WebAssembly. Formatting runs locally in the
browser, with four-space indentation for the structured formats.

The project began as a Go implementation, kept at
[JSON-YAML-Auto-Formatter-Legacy-Go](https://github.com/pattygcoding/JSON-YAML-Auto-Formatter-Legacy-Go).
It was then ported to Rust, whose snapshot is kept at
[Auto-Linter-Legacy-Rust](https://github.com/pattygcoding/Auto-Linter-Legacy-Rust).
The WebAssembly interface and JavaScript bridge are unchanged across those ports;
this repository now holds the Zig implementation.

## Build

Requires Zig 0.16 or newer, plus PowerShell. From the repository root:

```powershell
.\scripts\build.ps1
```

The script runs `zig build -Doptimize=ReleaseSmall` and copies
`zig-out/bin/formatter.wasm` to `formatter.wasm`. The module is a
`wasm32-freestanding` reactor with plain exports — `alloc`, `dealloc` and
`format_input` — and an exported `memory`, so there is no `wasm-bindgen` or
`wasm-pack` step and no generated JavaScript to keep in sync.
`formatter.js` is the small hand-written bridge between the module and the page.

Building without the script also works:

```powershell
zig build -Doptimize=ReleaseSmall
Copy-Item zig-out\bin\formatter.wasm formatter.wasm
```

## Run

Serve the repository over HTTP; opening `index.html` directly cannot load WASM.
For example, with Python installed:

```powershell
python -m http.server 8000 --bind 127.0.0.1
```

Open <http://127.0.0.1:8000>, paste input, choose Auto-detect, JSON, YAML, XML,
HTML, TOML, CSV or TSV, and select Format.

## Detection and Formatting

- Valid JSON is detected first, including arrays, strings, numbers, and literals.
- JSON objects and arrays are indented with four spaces per level. Key order,
  numeric precision, and existing string escapes are preserved: the JSON path
  validates and re-indents the original text rather than re-encoding it.
- Remaining input is parsed as YAML. Comments, anchors, aliases, tags, quoting
  style, block scalars and flow collections are retained: YAML is validated and
  then re-indented line by line, so only leading indentation changes. One value
  block is indented four columns past its parent, and the members of a mapping
  that starts on a `- ` line stay aligned two columns past the dash.
- JSON and YAML overlap. In Auto-detect, JSON-looking collections (such as objects
  with double-quoted keys or arrays starting with JSON values) are validated as
  strict JSON, so malformed JSON is not silently accepted as YAML. Select YAML
  explicitly to interpret these ambiguous inputs as YAML.
- Markup is read as XML when it is well-formed XML. Elements are indented four
  spaces per level. Declarations, doctypes, comments, CDATA and attributes keep
  their original text, and an element with text content keeps that content
  verbatim, so mixed content is never reflowed.
- HTML is used for markup that is not well-formed XML. It understands void
  elements (`br`, `img`, `input`, …), optional end tags (`li`, `p`, `td`, `tr`,
  …), boolean and unquoted attributes, case-insensitive tag matching, and
  raw-text elements (`script`, `style`, `pre`, `textarea`, …) whose content is
  preserved byte for byte. Select XML explicitly to apply XML rules instead.
- TOML is detected when the input parses and contains at least one `key = value`
  line. Formatting normalises leading indentation, the spacing around the first
  `=`, trailing whitespace, and the indentation of multi-line arrays; multiline
  strings are preserved byte for byte.
- CSV and TSV are chosen explicitly, because auto-detect cannot tell tabular text
  apart from YAML reliably. Records are parsed with RFC 4180 quoting and
  re-emitted with normalised quoting, LF line endings and a trailing newline.
- Empty input, malformed documents, duplicate YAML mapping keys and unknown
  anchors report errors. All YAML documents are validated; later documents are not
  silently discarded.

YAML validation is structural rather than a complete YAML 1.2 parser. It checks
balanced flow collections and quoted scalars, indentation that does not use tabs,
aliases that resolve to an anchor in the same document, and duplicate keys in
block mappings. Duplicate keys inside flow mappings, and semantic errors outside
those rules, are not detected.

XML validation covers well-formedness: balanced and correctly nested elements,
quoted attributes without duplicates, terminated comments, CDATA sections,
processing instructions and DOCTYPE declarations, and valid entity references.

HTML validation covers tag nesting, void elements, raw-text elements, attribute
syntax and optional end tags. Duplicate attributes are not reported, and the full
HTML tree-construction algorithm (implied `html`/`head`/`body` elements, foster
parenting, …) is not reproduced.

TOML validation covers table headers, dotted keys, strings, arrays, inline tables
and scalar syntax. Duplicate keys and tables are not compared.

CSV validation covers field quoting and record structure. Column counts are not
enforced, so ragged rows are preserved.

Failures come back as `invalid JSON: …`, `invalid YAML: …`, `invalid XML: …`,
`invalid HTML: …`, `invalid TOML: …`, `invalid CSV: …` or `invalid TSV: …`
messages that name the offset or line the parser stopped at.

## Bridge

`formatter.js` loads the module and exposes:

- `FormatterWasm.init(source)` — `source` may be a URL, `ArrayBuffer`, typed array
  or compiled `WebAssembly.Module`; resolves once the module is ready.
  `AutoLinter` is an alias for the same API, so new code can use the product name.
- `FormatterWasm.format(input, mode)` — returns the formatted text, or the error
  message when the input was rejected.
- `formatInput(input, mode)` and the legacy alias `formatJSON` — installed on the
  global object by `init`, which is what `index.html` and the tests call. A leading
  `///force:json///`, `///force:yaml///`, `///force:xml///`, `///force:html///`,
  `///force:toml///`, `///force:csv///` or `///force:tsv///` marker overrides
  `mode`, which is how the site's embedded formatter forces a format.

## Tests

```powershell
zig build test
.\scripts\build.ps1
node --test test/wasm.test.cjs
node --test test/stress.test.cjs
```

`zig build test` runs the unit tests — detection, JSON cases captured from Go's
`encoding/json`, YAML re-indentation, XML and HTML mixed content, TOML scalars and
CSV quoting, plus idempotence — and fixture tests over everything under `test/`.
The stress fixtures are generated rather than hand written:

```powershell
zig build generate-stress
```

Node.js 18 or newer is needed only for the WASM integration tests.

## Differences from the Go version

The Go implementation re-serialised YAML through `yaml.v3`, which moved sequence
items, reflowed multi-line scalars, dropped blank lines and rewrote block scalar
chomping indicators. This version never rewrites the text of a document: it
validates and re-indents, so a document keeps its own quoting, comments, blank
lines and `---` markers. YAML 1.2 directives such as `%YAML 1.2` are accepted, and
a tab used as indentation or as a key separator is rejected.

## Layout

```text
build.zig                       Build graph: WASM module, tests, fixture generator
src/root.zig                    Library root and public API
src/format.zig                  Detection, dispatch and error messages
src/json.zig                    Strict JSON validation and indentation
src/yaml.zig                    YAML validation and indentation
src/xml.zig                     XML validation and indentation
src/html.zig                    HTML validation and indentation
src/toml.zig                    TOML validation and formatting
src/csv.zig                     CSV and TSV validation and formatting
src/wasm.zig                    WebAssembly exports: alloc, dealloc, format_input
src/diagnostic.zig              Shared rejection messages
src/indent.zig                  The four-space indent constant
tools/generate_stress.zig       Generates the fixtures in test/stress
tests/fixtures_test.zig         Regression tests over the committed fixtures
formatter.js                    JavaScript half of the bridge
index.html                      Browser interface
test/json/, test/yaml/          Valid and invalid JSON and YAML fixtures
test/xml/, test/toml/           Valid and invalid XML and TOML fixtures
test/html/                      Valid and invalid HTML fixtures
test/csv/                       Valid and invalid CSV and TSV fixtures
test/stress/                    Generated stress fixtures
test/wasm.test.cjs              Tests against the compiled WASM bridge
test/stress.test.cjs            Stress tests against the compiled WASM bridge
scripts/build.ps1               Builds formatter.wasm
formatter.wasm                  Generated WebAssembly module
```
