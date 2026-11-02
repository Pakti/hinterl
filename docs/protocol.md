# Hinterl protocol v1

## Transport and lifecycle

Launch `bin/hinterl` after `make`. Keep the process alive across analyses. It reads
one UTF-8 JSON object per line from stdin and writes one JSON object per line to
stdout, with no banners. Source newlines are JSON escapes, not frame boundaries.
EOF shuts down the process. Clients must buffer partial lines and handle multiple
lines in one read. Stderr is diagnostic output and must not be parsed as JSON.

Requests are independent full-buffer snapshots. No file access, editor identity,
or project root is required. V1 supports only `analyze`; it is not
JSON-RPC or LSP. Unknown fields may be ignored; new incompatible behavior requires
a new protocol version. Never evaluate returned display text as editor code.

## Request

```json
{"protocol":1,"id":7,"version":42,"method":"analyze","source":"-export([f/1]).\n-spec f(integer()) -> atom().\nf(X) -> ok.\n"}
```

`id` is a client-assigned integer, unique and increasing within a process.
`version` is an integer identifying the exact analyzed buffer snapshot. The server
echoes both; it does not interpret or assign document versions. It processes
requests serially. One process per buffer is the Emacs implementation's policy;
a future client can multiplex documents if it maintains its own request routing.

A client must apply a response only if its ID is the latest requested ID for that
document, its version is still current, and the response belongs to the current
process/session. Reusing a version after edits or accepting output from an old
process can produce stale hints. Remove old decorations immediately on an edit.

## Successful response

The request above produces this shape (whitespace shown for readability):

```json
{
  "protocol": 1,
  "id": 7,
  "version": 42,
  "status": "ok",
  "specs": [{
    "name": "f", "arity": 1,
    "location": {"line": 1, "character": 1},
    "text": "- spec f ( integer ( ) ) -> atom ( ) .\n",
    "alternatives": [{"arguments": ["integer()"], "return": "atom()", "constraints": []}]
  }],
  "functions": [{
    "name": "f", "arity": 1, "mapping": "shared",
    "clauses": [{
      "range": {"start": {"line": 2, "character": 0}, "end": {"line": 2, "character": 10}},
      "name_range": {"start": {"line": 2, "character": 0}, "end": {"line": 2, "character": 1}},
      "arguments": [{"start": {"line": 2, "character": 2}, "end": {"line": 2, "character": 3}}],
      "head_end": {"line": 2, "character": 4},
      "alternative": {"arguments": ["integer()"], "return": "atom()", "constraints": []}
    }]
  }]
}
```

- Names are decoded Erlang atoms as JSON strings, without source quotes. Identify
  functions by `(name, arity)`; use `name_range` to decorate actual source spelling.
- `functions` and `clauses` are in source order. `range` covers the clause from
  its name through its final body token, excluding the separating semicolon/dot.
  Argument ranges cover full patterns, including nested structures. `head_end`
  is immediately after `)`, before any guard. For zero arity, `arguments` is empty.
- `mapping` is `shared`, `positional`, or `suppressed`. A clause's `alternative`
  is either its selected signature or `null`. It is `null` with no spec, ambiguous
  duplicate specs, or a count mismatch.
- Each signature has argument display strings, a return display string, and a
  list of constraint strings such as `A :: integer()`. Variables stay named;
  types are rendered by `erl_pp`, possibly with line breaks. Clients may flatten
  layout newlines for inlays. Specs also retain token spelling as `text` with
  normalized inter-token whitespace, suitable for hover. The source spec remains
  the authority. A qualified spec additionally has `module` and is not mapped
  to local functions by v1.
- Display clients should expose this limitation on hover/documentation:
  **One spec applies to every clause; multiple alternatives map by position only
  when counts match. This is a display convention, not semantic validation or
  inference. Specs remain authoritative.**

## Coordinates

All positions are **zero-based lines and zero-based Unicode scalar columns**,
with exclusive range ends. Columns count characters, not UTF-8 bytes, screen
cells, grapheme clusters, or UTF-16 code units. Tabs count as one character.
Positions refer to the exact `source` string; clients must not normalize it after
assigning a version. This matches Emacs character offsets after line traversal.

For a VS Code adapter, convert a scalar column to a UTF-16 column before creating
a `Position`, for example in TypeScript:

```ts
const utf16Column = Array.from(lineText).slice(0, scalarColumn).join("").length;
```

The reverse conversion is needed only if the client sends positions in a future
protocol; v1 sends whole snapshots. Non-BMP characters such as emoji are one
protocol character and two UTF-16 units. Line feeds start a new line.

## Invalid source and errors

A valid `analyze` request with incomplete or unsupported buffer syntax returns the
same `protocol`, `id`, and `version`, `status: "invalid"`, a human-readable
`message`, and empty `functions` and `specs` arrays. Conditional
compilation is also invalid for buffer-only analysis. Discard all decorations for
that version. Do not use the last successful result. New successful snapshots
recover without restarting the backend.

Malformed JSON or an unsupported request produces `status: "error"` and a
`message`. These protocol errors may lack routing metadata; log them, clear
associated decorations, and surface an error rather than applying data. A
malformed request does not terminate the server. EOF and transport failure should
remove decorations; a new process starts a new session.

V1 does not expand macros, open includes, execute Erlang, infer types, resolve
project settings, or choose active conditional branches. Error messages are for
people, not stable machine-readable error codes.
