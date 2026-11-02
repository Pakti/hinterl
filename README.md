# Hinterl

Spec-derived inlay hints for ordinary Erlang, starting with Emacs on Linux.
Hinterl is independent of Angler. It displays decorations without inserting
annotations into source, changing saved files, or hiding specs.

```erlang
-spec birthday(#person{}) -> #person{}.
birthday(P) ->
    P#person{}.
```

With Hinterl enabled, the clause head appears as:

```erlang
birthday(P :: #person{}) :: #person{} ->
```

The types use `hinterl-type-face`; exported function names use the dedicated
`erlang-exported-function-face` on every clause head, matched by name **and arity**.
Both explicit `-export` attributes and `-compile(export_all)` are supported.

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
- `customize-group` → `hinterl`: set faces, backend command, and idle delay
  (default 0.3 seconds).

Hover a type hint for its mapping limitation and full token-preserved spec,
including constraints. Specs remain visible and authoritative.

## Mapping rules

Hinterl does **no inference or semantic clause/signature matching**:

1. A single signature supplies types to every implementation clause.
2. Multiple alternatives map to clauses in source order only when counts match.
3. Otherwise type hints are suppressed; the spec and export highlighting remain.

For example, alternative 1 may not semantically describe clause 1. Hint hover text
makes this convention explicit. Type variables, nested types, fun types, and
constraints are retained. Inline types come from Erlang's type pretty printer;
constraints remain in the visible spec and hover rather than being repeated inline.
Functions without specs receive no type hints.

## Backend and editing

Each enabled buffer owns one persistent Erlang process. Emacs sends the whole
**unsaved buffer**, including when narrowed, over UTF-8 JSON lines on stdio.
The backend uses `erl_scan` and `erl_parse`; there is no Erlang parser in Lisp.
It returns function identities, clause/argument ranges, spec alternatives, type
text, and explicit exports. Emacs owns overlays, faces, scheduling, and navigation.
See [the editor-independent protocol](docs/protocol.md) for a future VS Code client.

Every edit immediately removes old overlays, then schedules idle analysis. Replies
must match both the latest request ID and the exact buffer modification tick.
Partial JSON lines are buffered. Killing the buffer, changing major mode, or
disabling Hinterl removes overlays and stops its process. After a backend exit,
use `hinterl-refresh`, or make an edit, to start a fresh process.

This is **buffer parsing, not project preprocessing**. No code is compiled or run
by analysis; includes are not read, macros are not expanded, and conditional
branches are not selected. The initial conservative policy is:

- An incomplete form, scan/parse error, or unresolved macro syntax clears all
  decorations for the buffer. A subsequent successful parse restores them.
- Conditional compilation clears all decorations, even if both branches parse.
- An include keeps locally parsed type hints, but suppresses export highlighting
  because the included file could change export behavior. Explicit declarations
  are still returned as data, with export certainty marked false.
- Module-qualified spec declarations are returned as data, but are not guessed
  to describe local functions.

Project-aware include paths, macro definitions, preprocessing, optional spec
hiding/dimming, and a VS Code frontend are future work. This version has no project
index, compiler type checking, or semantic guarantee beyond Erlang buffer parsing.

## Development

`make test` runs EUnit and real Emacs/backend integration tests. Coverage includes
nested/fun/record types, variables and constraints, overload mapping, every exported
clause, quoted names, arity distinctions, `export_all`, nested head ranges, Unicode
and tabs, unsaved changes, incomplete syntax, stale responses, fragmented protocol
frames, multiple buffers, and process cleanup.

The backend is `src/hinterl_backend.erl`; presentation is `emacs/hinterl.el`.
Build output stays in `_build/`. `bin/hinterl` writes protocol responses only to
stdout; Emacs captures backend stderr in `*Hinterl backend errors*`.

GPL-3.0-or-later; see [LICENSE](LICENSE).
