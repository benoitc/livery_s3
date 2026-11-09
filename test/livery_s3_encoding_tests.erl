-module(livery_s3_encoding_tests).

-include_lib("eunit/include/eunit.hrl").

-import(livery_s3_test_util, [run/2, resp/3]).

%%====================================================================
%% livery_s3_uri:decode/1
%%====================================================================

decode_escapes_test() ->
    ?assertEqual(<<"a/b c\n">>, livery_s3_uri:decode(<<"a%2Fb%20c%0A">>)),
    ?assertEqual(<<"a b">>, livery_s3_uri:decode(<<"a+b">>)),
    ?assertEqual(<<"a+b">>, livery_s3_uri:decode(<<"a%2Bb">>)),
    ?assertEqual(<<"%zz%4">>, livery_s3_uri:decode(<<"%zz%4">>)),
    ?assertEqual(<<"caf", 16#C3, 16#A9>>, livery_s3_uri:decode(<<"caf%c3%A9">>)).

decode_inverts_encode_test() ->
    Keys = [<<"plain">>, <<"dir/sub file+x">>, <<"line\nbreak">>, <<"caf", 16#C3, 16#A9>>, <<"%">>],
    [?assertEqual(K, livery_s3_uri:decode(livery_s3_uri:encode(K))) || K <- Keys],
    [?assertEqual(K, livery_s3_uri:decode(livery_s3_uri:encode_path(K))) || K <- Keys].

%%====================================================================
%% Listings
%%====================================================================

list_objects_decodes_keys_test() ->
    Xml = <<
        "<ListBucketResult><EncodingType>url</EncodingType>"
        "<Contents><Key>dir%2Fline%0Abreak</Key><Size>1</Size></Contents>"
        "<Contents><Key>a+b</Key><Size>2</Size></Contents>"
        "<CommonPrefixes><Prefix>sub%20dir%2F</Prefix></CommonPrefixes>"
        "<IsTruncated>false</IsTruncated></ListBucketResult>"
    >>,
    {Req, {ok, Result}} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:list_objects(C, <<"b">>, #{encoding_type => url})
    end),
    ?assertNotEqual(nomatch, binary:match(maps:get(url, Req), <<"encoding-type=url">>)),
    ?assertEqual([<<"dir/line\nbreak">>, <<"a b">>], [
        maps:get(key, O)
     || O <- maps:get(objects, Result)
    ]),
    ?assertEqual([<<"sub dir/">>], maps:get(common_prefixes, Result)).

list_objects_without_encoding_untouched_test() ->
    Xml = <<"<ListBucketResult><Contents><Key>a+b%20</Key></Contents></ListBucketResult>">>,
    {Req, {ok, Result}} = run(resp(200, [], Xml), fun(C) -> livery_s3:list_objects(C, <<"b">>) end),
    ?assertEqual(nomatch, binary:match(maps:get(url, Req), <<"encoding-type">>)),
    ?assertEqual([<<"a+b%20">>], [maps:get(key, O) || O <- maps:get(objects, Result)]).

list_versions_decodes_test() ->
    Xml = <<
        "<ListVersionsResult>"
        "<Version><Key>v%0A1</Key><VersionId>1</VersionId></Version>"
        "<DeleteMarker><Key>d%20m</Key><VersionId>2</VersionId></DeleteMarker>"
        "<NextKeyMarker>n%2Fk</NextKeyMarker><IsTruncated>true</IsTruncated>"
        "</ListVersionsResult>"
    >>,
    {_, {ok, R}} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:list_object_versions(C, <<"b">>, #{encoding_type => url})
    end),
    ?assertEqual([<<"v\n1">>], [maps:get(key, V) || V <- maps:get(versions, R)]),
    ?assertEqual([<<"d m">>], [maps:get(key, V) || V <- maps:get(delete_markers, R)]),
    ?assertEqual(<<"n/k">>, maps:get(next_key_marker, R)).

list_uploads_decodes_test() ->
    Xml = <<
        "<ListMultipartUploadsResult>"
        "<Upload><Key>u%0Ak</Key><UploadId>U</UploadId></Upload>"
        "</ListMultipartUploadsResult>"
    >>,
    {Req, {ok, R}} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:list_multipart_uploads(C, <<"b">>, #{encoding_type => url})
    end),
    ?assertNotEqual(nomatch, binary:match(maps:get(url, Req), <<"encoding-type=url">>)),
    ?assertEqual([<<"u\nk">>], [maps:get(key, U) || U <- maps:get(uploads, R)]),
    ?assertEqual(undefined, maps:get(next_key_marker, R)).
