-module(livery_s3_uri_tests).

-include_lib("eunit/include/eunit.hrl").
-include("livery_s3.hrl").

encode_unreserved_test() ->
    ?assertEqual(<<"AZaz09-._~">>, livery_s3_uri:encode(<<"AZaz09-._~">>)).

encode_space_test() ->
    ?assertEqual(<<"a%20b">>, livery_s3_uri:encode(<<"a b">>)).

encode_slash_test() ->
    ?assertEqual(<<"a%2Fb">>, livery_s3_uri:encode(<<"a/b">>)).

encode_path_keeps_slash_test() ->
    ?assertEqual(<<"a/b%20c">>, livery_s3_uri:encode_path(<<"a/b c">>)).

encode_utf8_test() ->
    %% "é" is C3 A9 in UTF-8.
    ?assertEqual(<<"%C3%A9">>, livery_s3_uri:encode(<<"é"/utf8>>)).

encode_reserved_test() ->
    ?assertEqual(<<"%3D%26%2B%24%2C">>, livery_s3_uri:encode(<<"=&+$,">>)).

canonical_query_sorts_and_encodes_test() ->
    Q = [{<<"prefix">>, <<"a b">>}, {<<"list-type">>, <<"2">>}, {<<"delimiter">>, <<"/">>}],
    ?assertEqual(<<"delimiter=%2F&list-type=2&prefix=a%20b">>, livery_s3_uri:canonical_query(Q)).

canonical_query_empty_test() ->
    ?assertEqual(<<>>, livery_s3_uri:canonical_query([])).

parse_endpoint_test() ->
    ?assertEqual(
        #{scheme => <<"http">>, host => <<"127.0.0.1">>, port => 3900},
        livery_s3_uri:parse_endpoint(<<"http://127.0.0.1:3900">>)
    ),
    ?assertEqual(
        #{scheme => <<"https">>, host => <<"s3.amazonaws.com">>, port => undefined},
        livery_s3_uri:parse_endpoint(<<"https://s3.amazonaws.com">>)
    ),
    ?assertEqual(
        #{scheme => <<"https">>, host => <<"s3.example.com">>, port => undefined},
        livery_s3_uri:parse_endpoint(<<"s3.example.com">>)
    ).

request_target_path_style_test() ->
    Cfg = cfg(path, <<"example.com">>, undefined),
    ?assertEqual(
        {<<"https://example.com/bucket/key/with%20space">>, <<"example.com">>},
        livery_s3_uri:request_target(Cfg, <<"bucket">>, <<"key/with space">>, [])
    ).

request_target_path_with_port_test() ->
    Cfg = cfg(path, <<"127.0.0.1">>, 3900),
    {Url, Authority} = livery_s3_uri:request_target(Cfg, <<"b">>, <<"k">>, []),
    ?assertEqual(<<"https://127.0.0.1:3900/b/k">>, Url),
    ?assertEqual(<<"127.0.0.1:3900">>, Authority).

request_target_virtual_style_test() ->
    Cfg = cfg(virtual, <<"s3.amazonaws.com">>, undefined),
    ?assertEqual(
        {<<"https://bucket.s3.amazonaws.com/key">>, <<"bucket.s3.amazonaws.com">>},
        livery_s3_uri:request_target(Cfg, <<"bucket">>, <<"key">>, [])
    ).

request_target_service_level_test() ->
    Cfg = cfg(path, <<"example.com">>, undefined),
    ?assertEqual(
        {<<"https://example.com/">>, <<"example.com">>},
        livery_s3_uri:request_target(Cfg, undefined, undefined, [])
    ).

request_target_with_query_test() ->
    Cfg = cfg(path, <<"example.com">>, undefined),
    {Url, _} = livery_s3_uri:request_target(Cfg, <<"b">>, undefined, [{<<"versioning">>, <<>>}]),
    ?assertEqual(<<"https://example.com/b?versioning=">>, Url).

parse_endpoint_ipv6_test() ->
    ?assertEqual(
        #{scheme => <<"http">>, host => <<"[::1]">>, port => 3900},
        livery_s3_uri:parse_endpoint(<<"http://[::1]:3900">>)
    ),
    ?assertEqual(
        #{scheme => <<"https">>, host => <<"[2001:db8::1]">>, port => undefined},
        livery_s3_uri:parse_endpoint(<<"https://[2001:db8::1]">>)
    ).

request_target_virtual_bucket_level_test() ->
    Cfg = cfg(virtual, <<"s3.example.com">>, undefined),
    ?assertEqual(
        {<<"https://bucket.s3.example.com/">>, <<"bucket.s3.example.com">>},
        livery_s3_uri:request_target(Cfg, <<"bucket">>, undefined, [])
    ).

url_parts_authority_only_test() ->
    ?assertEqual(
        #{authority => <<"host">>, path => <<"/">>, query => <<>>},
        livery_s3_uri:url_parts(<<"https://host">>)
    ).

url_parts_test() ->
    ?assertEqual(
        #{authority => <<"h">>, path => <<"/b/k">>, query => <<"x=1&y=2">>},
        livery_s3_uri:url_parts(<<"https://h/b/k?x=1&y=2">>)
    ),
    ?assertEqual(
        #{authority => <<"h:3900">>, path => <<"/">>, query => <<>>},
        livery_s3_uri:url_parts(<<"http://h:3900/">>)
    ).

cfg(Addressing, Host, Port) ->
    #s3_config{
        scheme = <<"https">>,
        host = Host,
        port = Port,
        region = <<"us-east-1">>,
        access_key_id = <<"AK">>,
        secret_access_key = <<"SK">>,
        session_token = undefined,
        addressing = Addressing
    }.
