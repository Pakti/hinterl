%% SPDX-License-Identifier: GPL-3.0-or-later
-module(person).
-export([birthday/1, choose/1, identity/1]).
-record(person, {name :: binary(), age = 0 :: non_neg_integer()}).

-spec birthday(#person{}) -> #person{}.
birthday(P) ->
    P#person{age = P#person.age + 1}.

%% Purely positional: Hinterl does not check the semantic correspondence.
-spec choose(integer()) -> atom();
            (atom()) -> integer().
choose(1) -> one;
choose(one) -> 1.

-spec identity(A) -> A when A :: term().
identity(X) -> X.
