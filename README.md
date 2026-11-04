# Hinterl

Spec-derived inlay hints for ordinary Erlang, starting with Emacs on Linux.
It displays decorations without inserting annotations into source, changing saved
files, or hiding specs.

```erlang
-spec birthday(#person{}) -> #person{}.
birthday(P) ->
    P#person{}.
```

With Hinterl enabled, the clause head appears as:

```erlang
birthday(P :: #person{}) :: #person{} ->
```

The types use `hinterl-type-face`.

## Linux setup

Requirements:

- Erlang/OTP **27 or later** (uses the standard-library `json` module), including
  the compiler, tools, and EUnit for tests.
- Emacs **27.1 or later**, built with native JSON support, and ordinary
  `erlang-mode` (the `erlang` Emacs Lisp package shipped with OTP).
- GNU Make. No Hex, npm, or third-party Erlang dependencies.

On Debian versions shipping OTP 27+, the relevant packages are `erlang-base`,
`erlang-dev`, `erlang-eunit`, `erlang-tools`, `erlang-mode`, `emacs-nox`, and `make`.
Check `erl` on your PATH is OTP 27+; older distributions need a newer OTP release.

```sh
cd /path/to/hinterl
make
make test
```

`make test` discovers OTP's `tools/emacs` directory for ordinary `erlang-mode`.
For a separately installed mode, use
`make test ERLANG_EMACS_DIR=/path/to/erlang-mode`.
`ERL`, `ERLC`, and `EMACS` can also be overridden.

Add this to your Emacs configuration (adapt the checkout path):

```elisp
;; If erlang-mode is not already on load-path:
;; (add-to-list 'load-path "/path/to/otp/lib/tools-VERSION/emacs")
(require 'erlang)
(add-to-list 'load-path "/path/to/hinterl/emacs")
(require 'hinterl)
(add-hook 'erlang-mode-hook #'hinterl-mode)
```

Open an `.erl` buffer, or run `M-x hinterl-mode` in an existing `erlang-mode`
buffer. `examples/person.erl` is a small example. The default backend command
is `bin/hinterl` in this checkout and requires `erl` on Emacs's `exec-path`.
Customize `hinterl-backend-command` if you install the backend elsewhere.

Useful commands:

- `hinterl-refresh`: analyze immediately, restarting a stopped backend if needed.
- `hinterl-jump-to-spec`: navigate from a clause to its authoritative spec.
- `hinterl-status`: show parsing/protocol/backend status.
- `hinterl-copy-with-hints`: copy the active region as plain text including
  current inlay hints and collapsed record reads. Fails if no region is active.
- `hinterl-copy-buffer-with-hints`: explicitly copy the entire buffer, including
  text outside narrowing, with current inlay hints and collapsed record reads. Uses the kill ring and normal Emacs clipboard integration.
  Source is unchanged. Partial selections of collapsed syntax copy the selected
  source characters; in an error state, retained decorations may be stale.
- `customize-group` → `hinterl`: set faces, backend command, and idle delay
  (default 0.3 seconds).

Type hints have no hover tooltips. Specs remain visible and authoritative,
including constraints; use `hinterl-jump-to-spec` to navigate to them.

## Optional spec dimming

Set `hinterl-dim-specs` to `t` and run `M-x hinterl-refresh` to dim specs using
`hinterl-spec-face` (inherits `shadow` by default). Customize the face independently
of type hints. Dimming is off by default; specs remain visible, editable, and
unchanged in the source. Multiline and overloaded specs are dimmed in full.

## Mapping rules

Spec hints use **no inference or semantic clause/signature matching**:

1. A single signature supplies types to every implementation clause.
2. Multiple alternatives map to clauses in source order only when counts match.
3. Otherwise type hints are suppressed; the spec remains visible.

For example, alternative 1 may not semantically describe clause 1. Type variables, nested types, fun types, and
constraints are retained. Inline types come from Erlang's type pretty printer;
constraints remain in the visible spec rather than being repeated inline.
Functions without specs receive no type hints.

## Local record hints

`hinterl-record-hints` (enabled by default) independently controls record hints at
simple local variable bindings. Change it with Customize and run
`M-x hinterl-refresh` to update the buffer.

For example, the following source:

```erlang
new() ->
    P = #person{name = "Ada", age = 41},
    Alias = P,
    Older = birthday(Alias),
    42 = Older#person.age,
    Older.
```

displays `Alias :: #person{} = P` and
`Older :: #person{} = birthday(Alias)`. The constructor already identifies `P`,
so it gets no redundant hint. Hints are overlays, just like spec hints.

The backend associates variables with records using construction, record patterns,
access, updates, and simple aliases. Evidence can occur later than the binding.
An association is not a verified type: record access can fail at runtime.
The protocol retains evidence kinds and source locations, but type hints have no
hover tooltips.

Local calls can also supply evidence from a **same-buffer spec** if the function
is defined there and every spec alternative returns the same direct record type.
Calls are matched by name and arity. Remote calls, unions, type aliases, and type
variable substitution are not resolved. No tag tables or external analyzer are
required.

Conflicting record evidence suppresses the hint, including contradictions between
a return spec and usage. Each function clause is independent. Initially, a clause
containing branches, funs, comprehensions, or other ambiguous control flow receives
no local record hints. Only first, simple variable bindings in the top-level body
are decorated; constructors, updates, head parameters, repeated matches, and `_`
are not. This is a bounded heuristic, not general type inference or checking.

## Compact record field access

`hinterl-collapse-record-access` (enabled by default) displays `Older#person.age`
as `Older.age`. Customize `hinterl-record-access-face` to style the collapsed dot
(default: inherits `default`). This is an overlay: saving, copying, and compiling still use the
original Erlang text. Hover the dot to see the full expression, e.g. `Older#person.age`.
Moving point into the collapsed region temporarily reveals the full syntax for
editing; moving out collapses it again. Disable the option and run
`M-x hinterl-refresh` to retain ordinary record reads.

Only parsed record field reads are collapsed, including chained reads and reads
on expressions. Constructors, record updates, field-index expressions such as
`#person.age`, strings, and comments remain unchanged. Reads whose `#record.`
spelling contains intervening whitespace/comments or spans lines remain explicit.
This option is independent of local record hints and requires no inferred type.

## Backend and editing

Each enabled buffer owns one persistent Erlang process. Emacs sends the whole
**unsaved buffer**, including when narrowed, over UTF-8 JSON lines on stdio.
The backend uses `erl_scan` and `erl_parse`; there is no Erlang parser in Lisp.
It returns function identities, clause/argument ranges, spec alternatives, type
text. Emacs owns overlays, faces, scheduling, and navigation.
See [the editor-independent protocol](docs/protocol.md) for a future VS Code client.

Edits retain existing overlays while scheduling idle analysis. Replies
must match both the latest request ID and the exact buffer modification tick.
Partial JSON lines are buffered. Killing the buffer, changing major mode, or
disabling Hinterl removes overlays and stops its process. After a backend exit,
use `hinterl-refresh`, or make an edit, to start a fresh process.

When parsing, rendering, or the backend fails, the last decorations remain and may
be stale. The `Hinterl` mode-line indicator uses `hinterl-mode-line-error-face`
(inherits `error`); hover it to see the same message as `hinterl-status`. In the error state, the tooltip additionally
says "Click to switch to the backend log"; mouse-1 opens
`*Hinterl backend errors*` via `hinterl-show-backend-log`. Healthy indicators have
no custom mouse binding. A successful
analysis replaces the decorations and restores the normal indicator. Navigation
from cached analysis is disabled after edits until fresh analysis succeeds.

This is **buffer parsing, not project preprocessing**. No code is compiled or run
by analysis; includes are not read, macros are not expanded, and conditional
branches are not selected. The initial conservative policy is:

- An incomplete form or other scan/parse error retains previous decorations and
  marks the mode-line indicator as failed until analysis succeeds.
- Complete `-define` forms are skipped without macro expansion, so unused macro
  definitions do not prevent hints elsewhere. Complete forms with unresolved
  macro usages are omitted in full (including every clause of an affected
  function); independently parsed functions retain hints. Incomplete definitions
  and incomplete forms still fail analysis, retaining previous decorations.
- Conditional compilation fails analysis, even if both branches parse.
- An include keeps locally parsed type hints; included files are not analyzed.
- Module-qualified spec declarations are returned as data, but are not guessed
  to describe local functions.

Project-aware include paths, macro definitions, preprocessing, optional spec
hiding/dimming, and a VS Code frontend are future work. This version has no project
index, compiler type checking, or semantic guarantee beyond Erlang buffer parsing.

## Development

`make test` runs EUnit and real Emacs/backend integration tests. Coverage includes
nested/fun/record types, variables and constraints, overload mapping, multiple
clauses, quoted names, arity distinctions, nested head ranges, Unicode and tabs, unsaved changes, incomplete syntax, stale responses, fragmented protocol
frames, multiple buffers, and process cleanup.

The backend is `src/hinterl_backend.erl`; presentation is `emacs/hinterl.el`.
Build output stays in `_build/`. `bin/hinterl` writes protocol responses only to
stdout; Emacs captures backend stderr in `*Hinterl backend errors*`.

GPL-3.0-or-later; see [LICENSE](LICENSE).
