ERLC ?= erlc
ERL ?= erl
EMACS ?= emacs
ERLANG_EMACS_DIR ?= $(shell $(ERL) +S 2:2 -noshell -eval 'io:format("~s/emacs", [code:lib_dir(tools)]), halt().')

.PHONY: all test test-backend test-emacs clean
all: _build/hinterl_backend.beam _build/hinterl_records.beam

_build/%.beam: src/%.erl
	mkdir -p _build
	$(ERLC) -Werror +debug_info -o _build $<

test: test-backend test-emacs

test-backend: all
	$(ERLC) -Werror -o _build test/hinterl_backend_tests.erl
	$(ERL) +S 2:2 -noshell -pa _build -eval 'case eunit:test(hinterl_backend_tests, [verbose]) of ok -> halt(0); _ -> halt(1) end.'

test-emacs: all
	$(EMACS) -Q --batch -L "$(ERLANG_EMACS_DIR)" -L emacs -l test/hinterl-tests.el -f ert-run-tests-batch-and-exit

clean:
	rm -rf _build
