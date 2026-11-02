%% SPDX-License-Identifier: GPL-3.0-or-later
%% Deliberately bounded record associations, not general type inference.
-module(hinterl_records).
-export([analyze/1]).

analyze(Forms) ->
    Returns = returns(Forms),
    lists:append([clause(C, Returns) || {function, _, _, _, Cs} <- Forms, C <- Cs]).

returns(Forms) ->
    Defined = [{N, A} || {function, _, N, A, _} <- Forms],
    Specs = [{Key, As} || {attribute, _, spec, {Key, As}} <- Forms,
                          lists:member(Key, Defined)],
    maps:from_list([{Key, R} || {Key, As} <- Specs,
                              length([K || {K, _} <- Specs, K =:= Key]) =:= 1,
                              {record, R} <- [common_return(As)]]).

common_return(As) ->
    case lists:usort([return_record(A) || A <- As]) of
        [R] when R =/= unknown -> R;
        _ -> unknown
    end.
return_record({type, _, bounded_fun, [F, _]}) -> return_record(F);
return_record({type, _, 'fun', [_, R]}) -> record_type(R).
record_type({ann_type, _, [_, T]}) -> record_type(T);
record_type({type, _, record, [{atom, _, R} | _]}) -> {record, R};
record_type(_) -> unknown.

clause({clause, _, Args, Guards, Body}, Returns) ->
    %% Skipping the whole clause avoids guessing about shadowed fun variables,
    %% branch joins, comprehensions, or conditionally bound variables.
    case ambiguous(Body) of
        true -> [];
        false ->
            {Edges, Evidence} = collect([Args, Guards, Body], Returns, {[], []}),
            {Bindings, _} = bindings(Body, variables(Args), []),
            lists:filtermap(fun({N, A, Obvious}) ->
                Component = connected([N], Edges),
                Es = [E || {V, _, _} = E <- Evidence, lists:member(V, Component)],
                case {Obvious, lists:usort([R || {_, R, _} <- Es])} of
                    {false, [R]} ->
                        Type = unicode:characters_to_binary(io_lib:format("#~tp{}", [R])),
                        {true, #{<<"variable">> => atom_to_binary(N),
                                 <<"position">> => end_pos(A), <<"type">> => Type,
                                 <<"evidence">> => lists:usort([E || {_, _, E} <- Es])}};
                    _ -> false
                end
            end, Bindings)
    end.

ambiguous(T) when is_list(T) -> lists:any(fun ambiguous/1, T);
ambiguous(T) when is_tuple(T) ->
    lists:member(element(1, T), ['case', 'if', 'receive', 'try', 'fun', named_fun,
                                lc, bc, mc, 'maybe', maybe_match]) orelse
    ambiguous(tuple_to_list(T));
ambiguous(_) -> false.

variables({var, _, '_'}) -> [];
variables({var, _, N}) -> [N];
variables(T) when is_tuple(T) -> variables(tuple_to_list(T));
variables(T) when is_list(T) -> lists:usort(lists:append([variables(X) || X <- T]));
variables(_) -> [].

bindings([], Seen, Acc) -> {lists:reverse(Acc), Seen};
bindings([Expr | Rest], Seen, Acc) ->
    New = case Expr of
        {match, _, {var, A, N}, RHS} when N =/= '_' ->
            case lists:member(N, Seen) of
                true -> Acc;
                false -> [{N, A, obvious(RHS)} | Acc]
            end;
        _ -> Acc
    end,
    bindings(Rest, lists:usort(Seen ++ variables(Expr)), New).

obvious({record, _, _, _}) -> true;
obvious({record, _, _, _, _}) -> true;
obvious(_) -> false.

collect(T, Returns, State) when is_list(T) ->
    lists:foldl(fun(X, S) -> collect(X, Returns, S) end, State, T);
collect(T, Returns, State) when is_tuple(T) ->
    S = case T of
        {match, _, {var, _, X}, {var, _, Y}} -> edge(X, Y, State);
        {match, A, {var, _, X}, RHS} -> association(X, RHS, A, Returns, State);
        {match, A, Pattern, {var, _, X}} -> association(X, Pattern, A, Returns, State);
        {record_field, A, {var, _, X}, R, _} -> evidence(X, R, <<"record access">>, A, State);
        {record, A, {var, _, X}, R, _} -> evidence(X, R, <<"record update">>, A, State);
        _ -> State
    end,
    collect(tuple_to_list(T), Returns, S);
collect(_, _, State) -> State.

association(X, {record, _, R, _}, A, _, S) -> evidence(X, R, <<"record construction or pattern">>, A, S);
association(X, {record, _, _, R, _}, A, _, S) -> evidence(X, R, <<"record update result">>, A, S);
association(X, {call, _, {atom, _, F}, Args}, A, Returns, S) ->
    case maps:find({F, length(Args)}, Returns) of
        {ok, R} -> evidence(X, R, <<"same-buffer return spec">>, A, S);
        error -> S
    end;
association(_, _, _, _, S) -> S.

edge('_', _, S) -> S;
edge(_, '_', S) -> S;
edge(X, Y, {Edges, Es}) -> {[{X, Y} | Edges], Es}.

evidence('_', _, _, _, S) -> S;
evidence(X, R, Kind, A, {Edges, Es}) ->
    {Edges, [{X, R, #{<<"kind">> => Kind, <<"location">> => pos(A)}} | Es]}.

connected(Ns, Edges) ->
    More = lists:usort(Ns ++ [Y || {X, Y} <- Edges, lists:member(X, Ns)] ++
                            [X || {X, Y} <- Edges, lists:member(Y, Ns)]),
    case More =:= lists:usort(Ns) of true -> More; false -> connected(More, Edges) end.

pos(A) ->
    {L, C} = erl_anno:location(A),
    #{<<"line">> => L - 1, <<"character">> => C - 1}.
end_pos(A) ->
    P = pos(A),
    P#{<<"character">> := maps:get(<<"character">>, P) + length(erl_anno:text(A))}.
