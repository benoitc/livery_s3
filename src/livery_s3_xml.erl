%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(livery_s3_xml).
-moduledoc """
Minimal XML parsing for S3 responses.

S3 returns XML for bucket/object listings, versioning, multipart, batch delete,
and error bodies. Rather than pull in the `xmerl` record headers, this parses
into a light `{Tag, Attrs, Children}` tree via `xmerl_sax_parser` and offers a
few navigation helpers (`child/2`, `children/2`, `text/2`). Tags are local
names as binaries; namespaces are dropped (S3 uses a single default namespace).
""".

-export([parse/1]).
-export([child/2, children/2, text/2, node_text/1]).

-export_type([tree/0, node_/0]).

-type tree() :: {binary(), [{binary(), binary()}], [node_()]}.
-type node_() :: tree() | {text, binary()}.

%%====================================================================
%% Parsing
%%====================================================================

-doc "Parse an XML binary into the root element tree.".
-spec parse(binary()) -> {ok, tree()} | {error, term()}.
parse(Bin) when is_binary(Bin) ->
    Opts = [{event_fun, fun event/3}, {event_state, {[], undefined}}],
    try xmerl_sax_parser:stream(Bin, Opts) of
        {ok, {[], Root}, _Rest} when Root =/= undefined -> {ok, Root};
        {ok, {_, undefined}, _Rest} -> {error, empty_document};
        Other -> {error, {xml_parse, Other}}
    catch
        Class:Reason -> {error, {xml_parse, Class, Reason}}
    end.

%% Event state is {Stack, Root}: Stack holds open elements (children reversed),
%% Root is the completed top element once the document closes.
-spec event(term(), term(), State) -> State when State :: {[tree()], undefined | tree()}.
event({startElement, _Uri, Local, _QName, Attrs}, _Loc, {Stack, Root}) ->
    {[{to_bin(Local), conv_attrs(Attrs), []} | Stack], Root};
event({characters, Chars}, _Loc, {[{T, A, Ch} | Rest], Root}) ->
    {[{T, A, [{text, to_bin(Chars)} | Ch]} | Rest], Root};
event({endElement, _Uri, _Local, _QName}, _Loc, {[{T, A, Ch} | Rest], Root}) ->
    Node = {T, A, lists:reverse(Ch)},
    case Rest of
        [] -> {[], Node};
        [{Pt, Pa, Pch} | More] -> {[{Pt, Pa, [Node | Pch]} | More], Root}
    end;
event(_Event, _Loc, State) ->
    State.

-spec conv_attrs(list()) -> [{binary(), binary()}].
conv_attrs(Attrs) ->
    [{to_bin(Name), to_bin(Value)} || {_Uri, _Prefix, Name, Value} <- Attrs].

-spec to_bin(binary() | list()) -> binary().
to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L).

%%====================================================================
%% Navigation
%%====================================================================

-doc "First child element named `Name`, or `undefined`.".
-spec child(tree(), binary()) -> tree() | undefined.
child(Tree, Name) ->
    case [C || {T, _, _} = C <- element_children(Tree), T =:= Name] of
        [First | _] -> First;
        [] -> undefined
    end.

-doc "All child elements named `Name`.".
-spec children(tree(), binary()) -> [tree()].
children(Tree, Name) ->
    [C || {T, _, _} = C <- element_children(Tree), T =:= Name].

-doc "Text content of the first child named `Name`, or `undefined`.".
-spec text(tree(), binary()) -> binary() | undefined.
text(Tree, Name) ->
    case child(Tree, Name) of
        undefined -> undefined;
        Node -> node_text(Node)
    end.

-doc "Concatenated direct text content of an element.".
-spec node_text(tree()) -> binary().
node_text({_, _, Ch}) ->
    iolist_to_binary([B || {text, B} <- Ch]).

-spec element_children(tree()) -> [tree()].
element_children({_, _, Ch}) ->
    [C || C <- Ch, is_tuple(C), tuple_size(C) =:= 3].
