%% SPDX-License-Identifier: GPL-3.0-or-later
-module(hinterl_backend).
-export([main/0, analyze/1, request/1]).

main() ->
    io:setopts(standard_io, [{encoding, unicode}]),
    loop().

loop() ->
    case io:get_line(standard_io, "") of
        eof -> halt(0);
        {error, _} -> halt(1);
        Line ->
            Reply = try request(json:decode(unicode:characters_to_binary(Line)))
                    catch _:_ -> #{<<"status">> => <<"error">>,
                                   <<"message">> => <<"Invalid request">>} end,
            io:put_chars([json:encode(Reply), $\n]),
            loop()
    end.

request(#{<<"protocol">> := 1, <<"id">> := Id, <<"version">> := Version,
          <<"method">> := <<"analyze">>, <<"source">> := Source})
  when is_binary(Source), is_integer(Version), is_integer(Id) ->
    (analyze(Source))#{<<"protocol">> => 1, <<"id">> => Id, <<"version">> => Version};
request(_) -> #{<<"status">> => <<"error">>, <<"message">> => <<"Unsupported request">>}.

analyze(Source) when is_binary(Source) ->
    try
        Chars = unicode:characters_to_list(Source),
        true = is_list(Chars),
        case erl_scan:string(Chars, {1, 1}, [text]) of
            {ok, Tokens, _} -> analyze_tokens(Tokens);
            {error, _, _} -> invalid(<<"Scanning failed; decorations cleared">>)
        end
    catch _:_ -> invalid(<<"Analysis failed; decorations cleared">>) end.

invalid(Message) ->
    #{<<"status">> => <<"invalid">>, <<"message">> => Message,
      <<"functions">> => [], <<"specs">> => [], <<"record_hints">> => [], <<"record_accesses">> => []}.

analyze_tokens(Tokens) ->
    Forms = split_forms(Tokens, [], []),
    %% Preprocessor conditionals cannot be evaluated from a buffer. In particular,
    %% do not merge mutually exclusive specs/functions.
    case lists:any(fun conditional/1, Forms) of
        true -> invalid(<<"Conditional compilation is unresolved; decorations cleared">>);
        false ->
            case parse_forms(Forms, []) of
                error -> invalid(<<"Parsing failed (possibly unresolved macros); decorations cleared">>);
                {ok, Parsed} -> result(Parsed)
            end
    end.

split_forms([], [], Acc) -> lists:reverse(Acc);
split_forms([], Current, Acc) -> lists:reverse([lists:reverse(Current) | Acc]);
split_forms([T | Rest], Current, Acc) ->
    case element(1, T) of
        dot -> split_forms(Rest, [], [lists:reverse([T | Current]) | Acc]);
        _ -> split_forms(Rest, [T | Current], Acc)
    end.

conditional([{'-', _}, {atom, _, Name} | _]) ->
    lists:member(Name, [ifdef, ifndef, 'else', elif, endif]);
conditional(_) -> false.

parse_forms([], Acc) -> {ok, lists:reverse(Acc)};
parse_forms([[{'-', _}, {atom, _, define}, {'(', _} | _] = Tokens | Rest], Acc) ->
    %% Macro bodies are preprocessor token sequences, not Erlang forms. Ignore
    %% complete definitions without expanding them or changing source positions.
    case complete_define(lists:nthtail(2, Tokens), []) of
        true -> parse_forms(Rest, Acc);
        false -> error
    end;
parse_forms([Tokens | Rest], Acc) ->
    case erl_parse:parse_form(Tokens) of
        {ok, Form} -> parse_forms(Rest, [{Form, Tokens} | Acc]);
        _ -> error
    end.

complete_define([{dot, _}], []) -> true;
complete_define([T | Rest], Stack) ->
    case element(1, T) of
        '(' -> complete_define(Rest, [')' | Stack]);
        '[' -> complete_define(Rest, [']' | Stack]);
        '{' -> complete_define(Rest, ['}' | Stack]);
        '<<' -> complete_define(Rest, ['>>' | Stack]);
        K when K =:= ')'; K =:= ']'; K =:= '}'; K =:= '>>' ->
            case Stack of [K | Tail] -> complete_define(Rest, Tail); _ -> false end;
        dot -> false;
        _ -> complete_define(Rest, Stack)
    end;
complete_define([], _) -> false.

result(Parsed) ->
    Specs = [spec(S, Ts) || {S = {attribute, _, spec, _}, Ts} <- Parsed],
    Functions = [function(F, Ts, Specs)
                 || {F = {function, _, _, _, _}, Ts} <- Parsed],
    #{<<"status">> => <<"ok">>, <<"functions">> => Functions,
      <<"specs">> => Specs,
      <<"record_hints">> => hinterl_records:analyze([F || {F, _} <- Parsed]),
      <<"record_accesses">> => lists:append([record_accesses(F, Ts) || {F, Ts} <- Parsed])}.

identity(Name, Arity) -> #{<<"name">> => atom_to_binary(Name), <<"arity">> => Arity}.

spec({attribute, Anno, spec, {{Name, Arity}, Alternatives}}, Tokens) ->
    (identity(Name, Arity))#{<<"location">> => pos(Anno),
      <<"text">> => token_text(Tokens),
      <<"range">> => spec_range(Tokens),
      <<"alternatives">> => [alternative(A) || A <- Alternatives]};
spec({attribute, Anno, spec, {{Module, Name, Arity}, Alternatives}}, Tokens) ->
    (spec({attribute, Anno, spec, {{Name, Arity}, Alternatives}}, Tokens))#{
      <<"module">> => atom_to_binary(Module)}.

alternative({type, _, bounded_fun, [Fun, Constraints]}) ->
    (alternative(Fun))#{<<"constraints">> => [constraint_text(C) || C <- Constraints]};
alternative({type, _, 'fun', [{type, _, product, Args}, Return]}) ->
    #{<<"arguments">> => [type_text(A) || A <- Args],
      <<"return">> => type_text(Return), <<"constraints">> => []}.

%% erl_pp handles every type AST accepted by erl_parse, including nested funs,
%% record types, variables, remote types, annotations, and constraints.
type_text(Type) ->
    Form = {attribute, 0, type, {hinterl_type, Type, []}},
    Printed = unicode:characters_to_binary(erl_pp:attribute(Form)),
    [_, Body] = binary:split(Printed, <<"::">>),
    %% Remove the final period/newline, not periods inside the type.
    Trimmed = string:trim(Body),
    binary:part(Trimmed, 0, byte_size(Trimmed) - 1).

constraint_text({type, _, constraint, [{atom, _, is_subtype}, [Var, Type]]}) ->
    <<(type_text(Var))/binary, " :: ", (type_text(Type))/binary>>.

function({function, _, Name, Arity, Clauses}, Tokens, Specs) ->
    Matching = [S || S = #{<<"name">> := N, <<"arity">> := A} <- Specs,
                     N =:= atom_to_binary(Name), A =:= Arity, not maps:is_key(<<"module">>, S)],
    Alternatives = case Matching of
        [#{<<"alternatives">> := As}] -> As;
        _ -> []
    end,
    Count = length(Clauses),
    Mapping = case length(Alternatives) of
        1 -> <<"shared">>;
        Count when Count > 0 -> <<"positional">>;
        _ -> <<"suppressed">>
    end,
    (identity(Name, Arity))#{<<"mapping">> => Mapping,
      <<"clauses">> => [clause(C, Next, Tokens, mapped(I, Mapping, Alternatives))
                         || {C, Next, I} <- lists:zip3(Clauses, tl(Clauses) ++ [last],
                                                       lists:seq(1, Count))]}.

mapped(_, <<"shared">>, [A]) -> A;
mapped(I, <<"positional">>, As) -> lists:nth(I, As);
mapped(_, _, _) -> null.

clause({clause, Anno, _, _, _}, Next, Tokens, Alternative) ->
    Location = erl_anno:location(Anno),
    Head = lists:dropwhile(fun(T) -> erl_anno:location(element(2, T)) < Location end, Tokens),
    [NameToken, {'(', _} | Rest] = Head,
    {Args, Close} = arguments(Rest, [], [], []),
    ClauseTokens = case Next of
        last -> Head;
        {clause, NextAnno, _, _, _} ->
            lists:takewhile(fun(T) -> erl_anno:location(element(2, T)) <
                                      erl_anno:location(NextAnno) end, Head)
    end,
    %% Exclude the terminating semicolon or dot (whose text can include newline).
    LastToken = lists:nth(length(ClauseTokens) - 1, ClauseTokens),
    #{<<"range">> => range(NameToken, LastToken),
      <<"name_range">> => range(NameToken, NameToken),
      <<"arguments">> => Args, <<"head_end">> => end_pos(Close),
      <<"alternative">> => Alternative}.

%% Only delimit scanner tokens in an already parsed clause head; Erlang's parser
%% validates all language grammar. Delimiter depth locates argument boundaries.
arguments([{')', _} = Close | _], [], [], []) -> {[], Close};
arguments([{')', _} = Close | _], [], Current, Acc) ->
    {lists:reverse([arg_range(Current) | Acc]), Close};
arguments([{',', _} | Rest], [], Current, Acc) ->
    arguments(Rest, [], [], [arg_range(Current) | Acc]);
arguments([T | Rest], Stack, Current, Acc) ->
    Kind = element(1, T),
    NewStack = case Kind of
        '(' -> [')' | Stack]; '[' -> [']' | Stack]; '{' -> ['}' | Stack];
        '<<' -> ['>>' | Stack];
        _ -> case Stack of [Kind | Tail] -> Tail; _ -> Stack end
    end,
    arguments(Rest, NewStack, [T | Current], Acc).

arg_range(Reversed) -> range(lists:last(Reversed), hd(Reversed)).
range(First, Last) -> #{<<"start">> => pos(element(2, First)), <<"end">> => end_pos(Last)}.

pos(Anno) ->
    {Line, Column} = erl_anno:location(Anno),
    #{<<"line">> => Line - 1, <<"character">> => Column - 1}.

end_pos(Token) ->
    Anno = element(2, Token),
    Start = erl_anno:location(Anno),
    Text = erl_anno:text(Anno),
    {Line, Col} = lists:foldl(fun($\n, {L, _}) -> {L + 1, 1};
                               (_, {L, C}) -> {L, C + 1} end, Start, Text),
    #{<<"line">> => Line - 1, <<"character">> => Col - 1}.

token_text(Tokens) ->
    %% Keep exact token spelling (including variables); whitespace between tokens
    %% is normalized for hover. The visible buffer spec remains authoritative.
    unicode:characters_to_binary(lists:join(" ", [erl_anno:text(element(2, T)) || T <- Tokens])).

%% Read nodes carry the scanner annotation of their # token. Constructors,
%% updates and record indices have different AST shapes and are never selected.
record_accesses(Node = {record_field, A, Expr, _, _}, Tokens) ->
    Here = lists:dropwhile(fun(T) -> erl_anno:location(element(2, T)) =/=
                                    erl_anno:location(A) end, Tokens),
    Access = case Here of
        [Hash = {'#', _}, Name = {atom, _, _}, Dot = {'.', _} | _] ->
            %% Do not conceal comments, whitespace, or newlines between tokens.
            case end_pos(Hash) =:= pos(element(2, Name)) andalso
                 end_pos(Name) =:= pos(element(2, Dot)) andalso
                 maps:get(<<"line">>, pos(A)) =:= maps:get(<<"line">>, end_pos(Dot)) of
                true -> [#{<<"range">> => range(Hash, Dot),
                           <<"expression">> => unicode:characters_to_binary(erl_pp:expr(Node)),
                           <<"text">> => unicode:characters_to_binary(
                               [erl_anno:text(element(2, T)) || T <- [Hash, Name, Dot]])}];
                false -> []
            end;
        _ -> []
    end,
    record_accesses(Expr, Tokens) ++ Access;
record_accesses(T, Tokens) when is_tuple(T) -> record_accesses(tuple_to_list(T), Tokens);
record_accesses(T, Tokens) when is_list(T) ->
    lists:append([record_accesses(X, Tokens) || X <- T]);
record_accesses(_, _) -> [].

spec_range(Tokens) ->
    %% The scanner's dot text may contain a trailing newline. Dim the period,
    %% but leave the following whitespace and comments outside the spec range.
    Dot = pos(element(2, lists:last(Tokens))),
    #{<<"start">> => pos(element(2, hd(Tokens))),
      <<"end">> => Dot#{<<"character">> := maps:get(<<"character">>, Dot) + 1}}.
