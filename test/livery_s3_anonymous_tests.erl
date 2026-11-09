-module(livery_s3_anonymous_tests).

-include_lib("eunit/include/eunit.hrl").

-import(livery_s3_test_util, [run/3, resp/3, header/2, client/2]).

-define(ANON, #{credentials => anonymous}).

anonymous_get_is_unsigned_test() ->
    {Req, Result} = run(resp(200, [], <<"public">>), ?ANON, fun(C) ->
        livery_s3:get_object(C, <<"b">>, <<"k">>)
    end),
    Headers = maps:get(headers, Req),
    ?assertEqual(<<"https://s3.example.com/b/k">>, maps:get(url, Req)),
    ?assertEqual(undefined, header(<<"authorization">>, Headers)),
    ?assertEqual(undefined, header(<<"x-amz-content-sha256">>, Headers)),
    ?assertEqual(undefined, header(<<"x-amz-date">>, Headers)),
    ?assertMatch({ok, #{body := <<"public">>}}, Result).

anonymous_put_keeps_caller_headers_test() ->
    {Req, _} = run(resp(200, [], <<>>), ?ANON, fun(C) ->
        livery_s3:put_object(C, <<"b">>, <<"k">>, <<"x">>, #{content_type => <<"text/plain">>})
    end),
    Headers = maps:get(headers, Req),
    ?assertEqual(<<"text/plain">>, header(<<"content-type">>, Headers)),
    ?assertEqual(undefined, header(<<"authorization">>, Headers)).

anonymous_presign_errors_test() ->
    C = client(resp(200, [], <<>>), ?ANON),
    ?assertEqual(
        {error, {credentials, anonymous}},
        livery_s3:presign(C, get, <<"b">>, <<"k">>, 60)
    ).

anonymous_access_denied_decodes_test() ->
    Xml = <<"<Error><Code>AccessDenied</Code><Message>no</Message></Error>">>,
    {_, Result} = run(resp(403, [], Xml), ?ANON, fun(C) ->
        livery_s3:put_object(C, <<"b">>, <<"k">>, <<"x">>)
    end),
    ?assertMatch({error, {s3, <<"AccessDenied">>, _, #{status := 403}}}, Result).

prepare_anonymous_test() ->
    {ok, H} = livery_s3_credentials:prepare(anonymous),
    ?assertEqual(anonymous, livery_s3_credentials:current(H)).

missing_credentials_still_raises_test() ->
    ?assertError(
        missing_credentials,
        livery_s3:new(#{endpoint => <<"https://s3.example.com">>})
    ).
