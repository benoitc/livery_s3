-module(livery_s3_stream_upload_tests).

-include_lib("eunit/include/eunit.hrl").

-import(livery_s3_test_util, [run/2, run_seq/3, resp/3, header/2]).

stream_with_length_sends_content_length_test() ->
    {Req, Result} = run(resp(200, [{<<"ETag">>, <<"\"e\"">>}], <<>>), fun(C) ->
        livery_s3:put_object(C, <<"b">>, <<"k">>, stream([<<"hel">>, <<"lo">>]), #{
            content_length => 5
        })
    end),
    H = maps:get(headers, Req),
    ?assertEqual(<<"5">>, header(<<"content-length">>, H)),
    ?assertEqual(<<"UNSIGNED-PAYLOAD">>, header(<<"x-amz-content-sha256">>, H)),
    ?assertMatch({stream, _}, maps:get(body, Req)),
    ?assertMatch({ok, #{etag := <<"e">>}}, Result).

stream_without_length_is_refused_test() ->
    {Reqs, Result} = run_seq([resp(200, [], <<>>)], #{}, fun(C) ->
        livery_s3:put_object(C, <<"b">>, <<"k">>, stream([<<"x">>]))
    end),
    ?assertEqual([], Reqs),
    ?assertEqual({error, content_length_required}, Result).

invalid_length_is_refused_test() ->
    {Reqs, Result} = run_seq([resp(200, [], <<>>)], #{}, fun(C) ->
        livery_s3:put_object(C, <<"b">>, <<"k">>, stream([<<"x">>]), #{content_length => -1})
    end),
    ?assertEqual([], Reqs),
    ?assertEqual({error, {invalid_content_length, -1}}, Result).

full_body_sets_no_explicit_length_test() ->
    %% The transport computes it; content_length is ignored for a full body.
    {Req, _} = run(resp(200, [], <<>>), fun(C) ->
        livery_s3:put_object(C, <<"b">>, <<"k">>, <<"abc">>, #{content_length => 99})
    end),
    ?assertEqual(undefined, header(<<"content-length">>, maps:get(headers, Req))).

upload_part_stream_needs_length_test() ->
    {Reqs, Result} = run_seq([resp(200, [], <<>>)], #{}, fun(C) ->
        livery_s3:upload_part(C, <<"b">>, <<"k">>, <<"U">>, 1, stream([<<"x">>]))
    end),
    ?assertEqual([], Reqs),
    ?assertEqual({error, content_length_required}, Result),
    {Req, {ok, _}} = run(resp(200, [{<<"ETag">>, <<"\"p\"">>}], <<>>), fun(C) ->
        livery_s3:upload_part(C, <<"b">>, <<"k">>, <<"U">>, 1, stream([<<"x">>]), #{
            content_length => 1
        })
    end),
    ?assertEqual(<<"1">>, header(<<"content-length">>, maps:get(headers, Req))).

stream([]) -> {stream, fun() -> eof end};
stream([H | T]) -> {stream, fun() -> {ok, H, element(2, stream(T))} end}.
