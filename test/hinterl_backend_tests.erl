%% SPDX-License-Identifier: GPL-3.0-or-later
-module(hinterl_backend_tests).
-include_lib("eunit/include/eunit.hrl").

a(Source) ->
    R = hinterl_backend:analyze(unicode:characters_to_binary(Source)),
    ?assertEqual(<<"ok">>, maps:get(<<"status">>, R)),
    R.
functions(Source) -> maps:get(<<"functions">>, a(Source)).
clauses(F) -> maps:get(<<"clauses">>, F).
alt(C) -> maps:get(<<"alternative">>, C).

shared_spec_test() ->
    [F] = functions("-spec f(integer()) -> atom().\nf(1) -> a; f(2) -> b."),
    ?assertEqual(<<"shared">>, maps:get(<<"mapping">>, F)),
    ?assertEqual(2, length(clauses(F))),
    lists:foreach(fun(C) -> ?assertEqual([<<"integer()">>], maps:get(<<"arguments">>, alt(C))) end,
                  clauses(F)).

overload_test() ->
    [F] = functions("-spec f(integer()) -> atom(); (atom()) -> integer().\nf(1) -> a; f(a) -> 1."),
    ?assertEqual(<<"positional">>, maps:get(<<"mapping">>, F)),
    [C1, C2] = clauses(F),
    ?assertEqual(<<"atom()">>, maps:get(<<"return">>, alt(C1))),
    ?assertEqual(<<"integer()">>, maps:get(<<"return">>, alt(C2))).

mismatch_test() ->
    [F] = functions("-spec f(integer()) -> atom(); (atom()) -> integer().\nf(X) -> X."),
    ?assertEqual(<<"suppressed">>, maps:get(<<"mapping">>, F)),
    ?assertEqual(null, alt(hd(clauses(F)))).

nested_types_and_constraints_test() ->
    [F] = functions("-spec f(#{atom() => [fun((integer(), binary()) -> {ok, A})]}, B) -> {A, B} when A :: atom(), B :: module:t().\nf(#{a := [F]}, B) -> {F(1, <<>>), B}."),
    A = alt(hd(clauses(F))),
    ?assertEqual([<<"#{atom() => [fun((integer(), binary()) -> {ok, A})]}">>, <<"B">>],
                 maps:get(<<"arguments">>, A)),
    ?assertEqual([<<"A :: atom()">>, <<"B :: module:t()">>], maps:get(<<"constraints">>, A)),
    ?assertEqual(<<"{A, B}">>, maps:get(<<"return">>, A)).

record_and_annotated_type_test() ->
    [F] = functions("-spec birthday(P :: #person{}) -> #person{}.\nbirthday(P) -> P#person{}."),
    ?assertEqual([<<"P :: #person{}">>], maps:get(<<"arguments">>, alt(hd(clauses(F))))).

name_arity_and_quotes_test() ->
    Fs = functions("-export(['a b'/1, f/0]).\n'a b'(X) -> X; 'a b'(Y) -> Y.\nf() -> ok.\nf(X) -> X."),
    ?assertEqual([1, 0, 1], [maps:get(<<"arity">>, F) || F <- Fs]),
    [Quoted | _] = Fs,
    ?assertEqual(<<"a b">>, maps:get(<<"name">>, Quoted)),
    [C | _] = clauses(Quoted),
    ?assertEqual(#{<<"start">> => #{<<"line">> => 1, <<"character">> => 0},
                   <<"end">> => #{<<"line">> => 1, <<"character">> => 5}},
                 maps:get(<<"name_range">>, C)).

unicode_positions_test() ->
    [F] = functions("% 😀\n-spec 'hé😀'(binary(), atom()) -> ok.\n'hé😀'(<<\"😀\"/utf8>>,\t'å') -> ok."),
    [C] = clauses(F),
    ?assertEqual(#{<<"line">> => 2, <<"character">> => 5},
                 maps:get(<<"end">>, maps:get(<<"name_range">>, C))),
    [Arg1, Arg2] = maps:get(<<"arguments">>, C),
    ?assertEqual(#{<<"line">> => 2, <<"character">> => 18}, maps:get(<<"end">>, Arg1)),
    ?assertEqual(#{<<"line">> => 2, <<"character">> => 23}, maps:get(<<"end">>, Arg2)).

argument_boundaries_test() ->
    [F] = functions("-spec f(term(), term(), term()) -> term().\nf({A, [B,C]}, #{key := <<D:8, E/binary>>},\n  [H|T]) when is_atom(A) -> {A,B,C,D,E,H,T}."),
    [C] = clauses(F),
    Args = maps:get(<<"arguments">>, C),
    ?assertEqual(3, length(Args)),
    ?assertEqual(#{<<"line">> => 1, <<"character">> => 12}, maps:get(<<"end">>, hd(Args))),
    ?assertEqual(#{<<"line">> => 2, <<"character">> => 7}, maps:get(<<"end">>, lists:last(Args))),
    ?assertEqual(#{<<"line">> => 2, <<"character">> => 8}, maps:get(<<"head_end">>, C)).

zero_arity_test() ->
    [F] = functions("-spec f() -> fun((...) -> atom()). f() -> fun() -> ok end."),
    [C] = clauses(F),
    ?assertEqual([], maps:get(<<"arguments">>, C)),
    ?assertEqual(<<"fun((...) -> atom())">>, maps:get(<<"return">>, alt(C))).

invalid_and_preprocessing_test_() ->
    [?_test(begin
        R = hinterl_backend:analyze(unicode:characters_to_binary(Source)),
        ?assertEqual(<<"invalid">>, maps:get(<<"status">>, R)),
        ?assertEqual([], maps:get(<<"functions">>, R))
    end) || Source <- ["f(X) ->", "f(X) -> X", "f(\"unfinished) -> ok.",
                        "-export([?F/1]). f(X) -> X.",
                        "-ifdef(TEST). -export([f/0]). -endif. f() -> ok.",
                        "-if(true). f() -> ok. -else. f() -> no. -endif."]].

include_keeps_local_spec_test() ->
    R = a("-include(\"exports.hrl\"). -compile(export_all). -export([f/0]). -spec f() -> ok. f() -> ok."),
    [F] = maps:get(<<"functions">>, R),
    ?assertMatch(#{}, alt(hd(clauses(F)))).

versioned_unsaved_requests_test() ->
    Request = #{<<"protocol">> => 1, <<"id">> => 8, <<"version">> => 19,
                <<"method">> => <<"analyze">>, <<"source">> => <<"unsaved() -> ok.">>},
    R = hinterl_backend:request(Request),
    ?assertEqual(8, maps:get(<<"id">>, R)),
    ?assertEqual(19, maps:get(<<"version">>, R)),
    [F] = maps:get(<<"functions">>, R),
    ?assertEqual(<<"unsaved">>, maps:get(<<"name">>, F)).

clause_ranges_test() ->
    [F] = functions("f(a) -> case a of a -> a; b -> b end;\nf(b) -> b."),
    [C1, C2] = clauses(F),
    ?assertEqual(#{<<"line">> => 0, <<"character">> => 36},
                 maps:get(<<"end">>, maps:get(<<"range">>, C1))),
    ?assertEqual(#{<<"line">> => 1, <<"character">> => 0},
                 maps:get(<<"start">>, maps:get(<<"range">>, C2))),
    ?assertEqual(#{<<"line">> => 1, <<"character">> => 9},
                 maps:get(<<"end">>, maps:get(<<"range">>, C2))).

remote_spec_preserved_test() ->
    R = a("-spec other:f(integer()) -> atom(). f(X) -> X."),
    [S] = maps:get(<<"specs">>, R),
    ?assertEqual(<<"other">>, maps:get(<<"module">>, S)),
    [F] = maps:get(<<"functions">>, R),
    ?assertEqual(null, alt(hd(clauses(F)))).

scanner_and_parser_fidelity_test_() ->
    [?_test(begin
        [F] = functions("-spec f(" ++ Type ++ ") -> " ++ Type ++ ". f(X) -> X."),
        A = alt(hd(clauses(F))),
        ?assert(is_binary(maps:get(<<"return">>, A)))
    end) || Type <- ["-10..10", "<<_:8, _:_*8>>", "{ok, [integer(), ...]} | {error, term()}",
                        "fun()", "fun((...) -> atom())", "'quoted atom'", "#{atom() := [binary()]}"]].
