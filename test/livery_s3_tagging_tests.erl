-module(livery_s3_tagging_tests).

-include_lib("eunit/include/eunit.hrl").

-import(livery_s3_test_util, [run/2, resp/3, header/2]).

put_tagging_test() ->
    {Req, Result} = run(resp(200, [], <<>>), fun(C) ->
        livery_s3:put_object_tagging(C, <<"b">>, <<"k">>, #{
            <<"team">> => <<"a&b">>, <<"env">> => <<"<prod>">>
        })
    end),
    ?assertEqual(ok, Result),
    ?assertEqual(put, maps:get(method, Req)),
    ?assertEqual(<<"https://s3.example.com/b/k?tagging=">>, maps:get(url, Req)),
    {full, Body} = maps:get(body, Req),
    ?assertNotEqual(
        nomatch,
        binary:match(Body, <<"<Tag><Key>env</Key><Value>&lt;prod&gt;</Value></Tag>">>)
    ),
    ?assertNotEqual(nomatch, binary:match(Body, <<"<Value>a&amp;b</Value>">>)),
    ?assertEqual(
        base64:encode(crypto:hash(md5, Body)), header(<<"content-md5">>, maps:get(headers, Req))
    ).

put_tagging_version_test() ->
    {Req, ok} = run(resp(200, [], <<>>), fun(C) ->
        livery_s3:put_object_tagging(C, <<"b">>, <<"k">>, #{}, #{version_id => <<"v1">>})
    end),
    ?assertEqual(<<"https://s3.example.com/b/k?tagging=&versionId=v1">>, maps:get(url, Req)).

get_tagging_test() ->
    Xml = <<
        "<Tagging><TagSet>"
        "<Tag><Key>team</Key><Value>a&amp;b</Value></Tag>"
        "<Tag><Key>empty</Key><Value></Value></Tag>"
        "</TagSet></Tagging>"
    >>,
    {Req, Result} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:get_object_tagging(C, <<"b">>, <<"k">>)
    end),
    ?assertEqual(get, maps:get(method, Req)),
    ?assertEqual({ok, #{<<"team">> => <<"a&b">>, <<"empty">> => <<>>}}, Result).

get_tagging_empty_test() ->
    Xml = <<"<Tagging><TagSet/></Tagging>">>,
    {_, Result} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:get_object_tagging(C, <<"b">>, <<"k">>)
    end),
    ?assertEqual({ok, #{}}, Result).

delete_tagging_test() ->
    {Req, ok} = run(resp(204, [], <<>>), fun(C) ->
        livery_s3:delete_object_tagging(C, <<"b">>, <<"k">>)
    end),
    ?assertEqual(delete, maps:get(method, Req)),
    ?assertEqual(<<"https://s3.example.com/b/k?tagging=">>, maps:get(url, Req)).

tagging_on_put_is_url_encoded_test() ->
    {Req, _} = run(resp(200, [], <<>>), fun(C) ->
        livery_s3:put_object(C, <<"b">>, <<"k">>, <<"x">>, #{
            tagging => #{<<"a b">> => <<"1&2">>, <<"z">> => <<"=">>}
        })
    end),
    ?assertEqual(<<"a%20b=1%262&z=%3D">>, header(<<"x-amz-tagging">>, maps:get(headers, Req))).

copy_with_tagging_replaces_test() ->
    Xml = <<"<CopyObjectResult><ETag>\"c\"</ETag></CopyObjectResult>">>,
    {Req, {ok, _}} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:copy_object(C, <<"b">>, <<"s">>, <<"b">>, <<"d">>, #{
            tagging => #{<<"k">> => <<"v">>}
        })
    end),
    H = maps:get(headers, Req),
    ?assertEqual(<<"REPLACE">>, header(<<"x-amz-tagging-directive">>, H)),
    ?assertEqual(undefined, header(<<"x-amz-metadata-directive">>, H)),
    ?assertEqual(<<"k=v">>, header(<<"x-amz-tagging">>, H)).

copy_without_tagging_keeps_source_test() ->
    Xml = <<"<CopyObjectResult><ETag>\"c\"</ETag></CopyObjectResult>">>,
    {Req, {ok, _}} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:copy_object(C, <<"b">>, <<"s">>, <<"b">>, <<"d">>)
    end),
    ?assertEqual(undefined, header(<<"x-amz-tagging-directive">>, maps:get(headers, Req))).
