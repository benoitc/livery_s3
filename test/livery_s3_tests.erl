-module(livery_s3_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Objects
%%====================================================================

put_object_test() ->
    Resp = resp(200, [{<<"ETag">>, <<"\"abc\"">>}, {<<"x-amz-version-id">>, <<"v1">>}], <<>>),
    {Req, Result} = run(Resp, fun(C) ->
        livery_s3:put_object(C, <<"bucket">>, <<"key">>, <<"data">>, #{
            content_type => <<"text/plain">>,
            metadata => #{<<"foo">> => <<"bar">>}
        })
    end),
    ?assertEqual(put, maps:get(method, Req)),
    ?assertEqual(<<"https://s3.example.com/bucket/key">>, maps:get(url, Req)),
    ?assertEqual({full, <<"data">>}, maps:get(body, Req)),
    Headers = maps:get(headers, Req),
    ?assertEqual(<<"text/plain">>, header(<<"content-type">>, Headers)),
    ?assertEqual(<<"bar">>, header(<<"x-amz-meta-foo">>, Headers)),
    ?assertEqual(<<"s3.example.com">>, header(<<"host">>, Headers)),
    ?assertNotEqual(undefined, header(<<"authorization">>, Headers)),
    ?assertNotEqual(undefined, header(<<"x-amz-content-sha256">>, Headers)),
    ?assertEqual({ok, #{etag => <<"abc">>, version_id => <<"v1">>}}, Result).

get_object_with_range_test() ->
    Headers = [
        {<<"Content-Type">>, <<"text/plain">>},
        {<<"Content-Length">>, <<"5">>},
        {<<"ETag">>, <<"\"e\"">>},
        {<<"x-amz-meta-foo">>, <<"bar">>}
    ],
    Resp = resp(206, Headers, <<"hello">>),
    {Req, Result} = run(Resp, fun(C) ->
        livery_s3:get_object(C, <<"b">>, <<"k">>, #{range => {0, 4}})
    end),
    ?assertEqual(get, maps:get(method, Req)),
    ?assertEqual(<<"bytes=0-4">>, header(<<"range">>, maps:get(headers, Req))),
    {ok, Map} = Result,
    ?assertEqual(<<"hello">>, maps:get(body, Map)),
    ?assertEqual(#{<<"foo">> => <<"bar">>}, maps:get(metadata, Map)),
    ?assertEqual(5, maps:get(content_length, Map)),
    ?assertEqual(<<"e">>, maps:get(etag, Map)),
    ?assertEqual(<<"text/plain">>, maps:get(content_type, Map)).

get_object_range_forms_test() ->
    [
        ?assertEqual(Expected, range_header_for(Range))
     || {Range, Expected} <- [
            {{10, 20}, <<"bytes=10-20">>},
            {{100, eof}, <<"bytes=100-">>},
            {{suffix, 50}, <<"bytes=-50">>}
        ]
    ].

head_object_not_found_test() ->
    {_, Result} = run(resp(404, [], <<>>), fun(C) ->
        livery_s3:head_object(C, <<"b">>, <<"missing">>)
    end),
    ?assertEqual({error, not_found}, Result).

delete_object_versioned_test() ->
    {Req, Result} = run(resp(204, [], <<>>), fun(C) ->
        livery_s3:delete_object(C, <<"b">>, <<"k">>, #{version_id => <<"v1">>})
    end),
    ?assertEqual(delete, maps:get(method, Req)),
    ?assertEqual(<<"https://s3.example.com/b/k?versionId=v1">>, maps:get(url, Req)),
    ?assertEqual(ok, Result).

error_decoding_test() ->
    Xml = <<
        "<Error><Code>AccessDenied</Code><Message>Denied</Message>"
        "<RequestId>R1</RequestId></Error>"
    >>,
    {_, Result} = run(resp(403, [], Xml), fun(C) ->
        livery_s3:put_object(C, <<"b">>, <<"k">>, <<"x">>)
    end),
    ?assertMatch({error, {s3, <<"AccessDenied">>, <<"Denied">>, #{status := 403}}}, Result).

copy_object_success_test() ->
    Xml = <<"<CopyObjectResult><ETag>\"copied\"</ETag></CopyObjectResult>">>,
    {Req, Result} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:copy_object(C, <<"src">>, <<"a.txt">>, <<"dst">>, <<"b.txt">>)
    end),
    ?assertEqual(<<"/src/a.txt">>, header(<<"x-amz-copy-source">>, maps:get(headers, Req))),
    ?assertEqual({ok, #{etag => <<"copied">>}}, Result).

copy_object_inline_error_test() ->
    %% S3 may return 200 with an <Error> body for CopyObject.
    Xml = <<"<Error><Code>InternalError</Code><Message>retry</Message></Error>">>,
    {_, Result} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:copy_object(C, <<"src">>, <<"a">>, <<"dst">>, <<"b">>)
    end),
    ?assertMatch({error, {s3, <<"InternalError">>, _, _}}, Result).

%%====================================================================
%% Buckets
%%====================================================================

list_objects_test() ->
    Xml = <<
        "<ListBucketResult><IsTruncated>false</IsTruncated>"
        "<Contents><Key>a.txt</Key><Size>10</Size><ETag>\"x\"</ETag></Contents>"
        "<CommonPrefixes><Prefix>p/</Prefix></CommonPrefixes></ListBucketResult>"
    >>,
    {Req, Result} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:list_objects(C, <<"b">>, #{prefix => <<"p/">>, max_keys => 10})
    end),
    ?assertEqual(
        <<"https://s3.example.com/b?list-type=2&max-keys=10&prefix=p%2F">>, maps:get(url, Req)
    ),
    {ok, Map} = Result,
    ?assertEqual(false, maps:get(is_truncated, Map)),
    [Obj] = maps:get(objects, Map),
    ?assertEqual(<<"a.txt">>, maps:get(key, Obj)),
    ?assertEqual(10, maps:get(size, Obj)),
    ?assertEqual(<<"x">>, maps:get(etag, Obj)),
    ?assertEqual([<<"p/">>], maps:get(common_prefixes, Map)).

list_buckets_test() ->
    Xml = <<
        "<ListAllMyBucketsResult><Buckets>"
        "<Bucket><Name>one</Name><CreationDate>2020-01-01T00:00:00Z</CreationDate></Bucket>"
        "</Buckets></ListAllMyBucketsResult>"
    >>,
    {Req, Result} = run(resp(200, [], Xml), fun livery_s3:list_buckets/1),
    ?assertEqual(<<"https://s3.example.com/">>, maps:get(url, Req)),
    ?assertEqual({ok, [#{name => <<"one">>, creation_date => <<"2020-01-01T00:00:00Z">>}]}, Result).

head_bucket_ok_test() ->
    {_, Result} = run(resp(200, [], <<>>), fun(C) -> livery_s3:head_bucket(C, <<"b">>) end),
    ?assertEqual(ok, Result).

%%====================================================================
%% Versioning
%%====================================================================

get_bucket_versioning_test() ->
    Xml = <<"<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>">>,
    {Req, Result} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:get_bucket_versioning(C, <<"b">>)
    end),
    ?assertEqual(<<"https://s3.example.com/b?versioning=">>, maps:get(url, Req)),
    ?assertEqual({ok, enabled}, Result).

put_bucket_versioning_test() ->
    {Req, Result} = run(resp(200, [], <<>>), fun(C) ->
        livery_s3:put_bucket_versioning(C, <<"b">>, enabled)
    end),
    {full, Body} = maps:get(body, Req),
    ?assert(binary:match(Body, <<"<Status>Enabled</Status>">>) =/= nomatch),
    ?assertEqual(ok, Result).

put_bucket_versioning_suspended_test() ->
    {Req, Result} = run(resp(200, [], <<>>), fun(C) ->
        livery_s3:put_bucket_versioning(C, <<"b">>, suspended)
    end),
    {full, Body} = maps:get(body, Req),
    ?assert(binary:match(Body, <<"<Status>Suspended</Status>">>) =/= nomatch),
    ?assertEqual(ok, Result).

%%====================================================================
%% Multipart and batch delete
%%====================================================================

create_multipart_test() ->
    Xml =
        <<"<InitiateMultipartUploadResult><UploadId>UP1</UploadId></InitiateMultipartUploadResult>">>,
    {Req, Result} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:create_multipart_upload(C, <<"b">>, <<"k">>)
    end),
    ?assertEqual(post, maps:get(method, Req)),
    ?assertEqual(<<"https://s3.example.com/b/k?uploads=">>, maps:get(url, Req)),
    ?assertEqual({ok, <<"UP1">>}, Result).

delete_objects_test() ->
    Xml =
        <<"<DeleteResult><Deleted><Key>a</Key></Deleted><Deleted><Key>b</Key></Deleted></DeleteResult>">>,
    {Req, Result} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:delete_objects(C, <<"bucket">>, [<<"a">>, <<"b">>])
    end),
    ?assertEqual(post, maps:get(method, Req)),
    ?assertEqual(<<"https://s3.example.com/bucket?delete=">>, maps:get(url, Req)),
    ?assertNotEqual(undefined, header(<<"content-md5">>, maps:get(headers, Req))),
    {full, Body} = maps:get(body, Req),
    ?assert(binary:match(Body, <<"<Key>a</Key>">>) =/= nomatch),
    {ok, Map} = Result,
    ?assertEqual([#{key => <<"a">>}, #{key => <<"b">>}], maps:get(deleted, Map)),
    ?assertEqual([], maps:get(errors, Map)).

%%====================================================================
%% Presign (no network)
%%====================================================================

presign_test() ->
    C = client(resp(200, [], <<>>)),
    {ok, Url} = livery_s3:presign(C, get, <<"b">>, <<"k">>, 3600),
    ?assert(binary:match(Url, <<"https://s3.example.com/b/k?">>) =/= nomatch),
    ?assert(binary:match(Url, <<"X-Amz-Signature=">>) =/= nomatch),
    ?assert(binary:match(Url, <<"X-Amz-Expires=3600">>) =/= nomatch).

%%====================================================================
%% Objects (additional coverage)
%%====================================================================

put_object_stream_body_test() ->
    Producer = fun() -> eof end,
    {Req, _} = run(resp(200, [{<<"ETag">>, <<"\"e\"">>}], <<>>), fun(C) ->
        livery_s3:put_object(C, <<"b">>, <<"k">>, {stream, Producer})
    end),
    ?assertMatch({stream, _}, maps:get(body, Req)).

get_object_streaming_test() ->
    {Req, Result} = run(resp(200, [], <<"streamed-bytes">>), fun(C) ->
        livery_s3:get_object(C, <<"b">>, <<"k">>, #{stream => true})
    end),
    ?assertEqual(true, maps:get(stream, Req)),
    {ok, #{body := {stream, Reader}}} = Result,
    ?assertEqual({ok, <<"streamed-bytes">>}, livery_client:read_body(Reader)).

get_object_versioned_test() ->
    {Req, _} = run(resp(200, [], <<"v">>), fun(C) ->
        livery_s3:get_object(C, <<"b">>, <<"k">>, #{version_id => <<"V2">>})
    end),
    ?assertEqual(<<"https://s3.example.com/b/k?versionId=V2">>, maps:get(url, Req)).

head_object_success_test() ->
    Headers = [
        {<<"Content-Length">>, <<"42">>},
        {<<"Content-Type">>, <<"application/json">>},
        {<<"ETag">>, <<"\"abc\"">>},
        {<<"Last-Modified">>, <<"Mon, 01 Jan 2020 00:00:00 GMT">>},
        {<<"x-amz-version-id">>, <<"v9">>},
        {<<"x-amz-meta-k">>, <<"val">>}
    ],
    {Req, Result} = run(resp(200, Headers, <<>>), fun(C) ->
        livery_s3:head_object(C, <<"b">>, <<"k">>)
    end),
    ?assertEqual(head, maps:get(method, Req)),
    ?assertEqual(
        {ok, #{
            content_length => 42,
            content_type => <<"application/json">>,
            etag => <<"abc">>,
            last_modified => <<"Mon, 01 Jan 2020 00:00:00 GMT">>,
            version_id => <<"v9">>,
            metadata => #{<<"k">> => <<"val">>}
        }},
        Result
    ).

delete_object_simple_test() ->
    {Req, Result} = run(resp(204, [], <<>>), fun(C) ->
        livery_s3:delete_object(C, <<"b">>, <<"k">>)
    end),
    ?assertEqual(<<"https://s3.example.com/b/k">>, maps:get(url, Req)),
    ?assertEqual(ok, Result).

copy_object_metadata_replace_test() ->
    Xml = <<"<CopyObjectResult><ETag>\"c\"</ETag></CopyObjectResult>">>,
    {Req, _} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:copy_object(C, <<"s">>, <<"a">>, <<"d">>, <<"b">>, #{
            metadata => #{<<"x">> => <<"y">>}
        })
    end),
    H = maps:get(headers, Req),
    ?assertEqual(<<"REPLACE">>, header(<<"x-amz-metadata-directive">>, H)),
    ?assertEqual(<<"y">>, header(<<"x-amz-meta-x">>, H)).

%%====================================================================
%% Buckets (additional coverage)
%%====================================================================

create_bucket_simple_test() ->
    {Req, Result} = run(resp(200, [], <<>>), fun(C) ->
        livery_s3:create_bucket(C, <<"b">>)
    end),
    ?assertEqual(put, maps:get(method, Req)),
    ?assertEqual(<<"https://s3.example.com/b">>, maps:get(url, Req)),
    ?assertEqual({full, <<>>}, maps:get(body, Req)),
    ?assertEqual(ok, Result).

create_bucket_location_constraint_test() ->
    {Req, _} = run(resp(200, [], <<>>), fun(C) ->
        livery_s3:create_bucket(C, <<"b">>, #{location_constraint => <<"eu-west-1">>})
    end),
    {full, Body} = maps:get(body, Req),
    ?assert(
        binary:match(Body, <<"<LocationConstraint>eu-west-1</LocationConstraint>">>) =/= nomatch
    ).

create_bucket_acl_test() ->
    {Req, _} = run(resp(200, [], <<>>), fun(C) ->
        livery_s3:create_bucket(C, <<"b">>, #{acl => <<"private">>})
    end),
    ?assertEqual(<<"private">>, header(<<"x-amz-acl">>, maps:get(headers, Req))).

delete_bucket_test() ->
    {Req, Result} = run(resp(204, [], <<>>), fun(C) ->
        livery_s3:delete_bucket(C, <<"b">>)
    end),
    ?assertEqual(delete, maps:get(method, Req)),
    ?assertEqual(ok, Result).

head_bucket_not_found_test() ->
    {_, Result} = run(resp(404, [], <<>>), fun(C) -> livery_s3:head_bucket(C, <<"b">>) end),
    ?assertEqual({error, not_found}, Result).

list_objects_truncated_test() ->
    Xml = <<
        "<ListBucketResult><IsTruncated>true</IsTruncated>"
        "<NextContinuationToken>TOK</NextContinuationToken>"
        "<Contents><Key>a</Key><Size>1</Size></Contents></ListBucketResult>"
    >>,
    {_, {ok, Map}} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:list_objects(C, <<"b">>)
    end),
    ?assertEqual(true, maps:get(is_truncated, Map)),
    ?assertEqual(<<"TOK">>, maps:get(next_continuation_token, Map)).

list_objects_all_paginates_test() ->
    Page1 = resp(
        200,
        [],
        <<
            "<ListBucketResult><IsTruncated>true</IsTruncated>"
            "<NextContinuationToken>T2</NextContinuationToken>"
            "<Contents><Key>a</Key></Contents></ListBucketResult>"
        >>
    ),
    Page2 = resp(
        200,
        [],
        <<
            "<ListBucketResult><IsTruncated>false</IsTruncated>"
            "<Contents><Key>b</Key></Contents></ListBucketResult>"
        >>
    ),
    {Reqs, Result} = run_seq([Page1, Page2], fun(C) ->
        livery_s3:list_objects_all(C, <<"b">>)
    end),
    ?assertEqual(2, length(Reqs)),
    [_, Req2] = Reqs,
    ?assert(binary:match(maps:get(url, Req2), <<"continuation-token=T2">>) =/= nomatch),
    {ok, #{objects := Objects}} = Result,
    ?assertEqual([<<"a">>, <<"b">>], [maps:get(key, O) || O <- Objects]).

%%====================================================================
%% Versioning (additional coverage)
%%====================================================================

get_bucket_versioning_none_test() ->
    {_, Result} = run(resp(200, [], <<"<VersioningConfiguration/>">>), fun(C) ->
        livery_s3:get_bucket_versioning(C, <<"b">>)
    end),
    ?assertEqual({ok, none}, Result).

get_bucket_versioning_suspended_test() ->
    Xml = <<"<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>">>,
    {_, Result} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:get_bucket_versioning(C, <<"b">>)
    end),
    ?assertEqual({ok, suspended}, Result).

list_object_versions_test() ->
    Xml = <<
        "<ListVersionsResult><IsTruncated>false</IsTruncated>"
        "<Version><Key>k</Key><VersionId>v1</VersionId><IsLatest>true</IsLatest>"
        "<Size>3</Size><ETag>\"e\"</ETag></Version>"
        "<DeleteMarker><Key>k</Key><VersionId>v0</VersionId><IsLatest>false</IsLatest></DeleteMarker>"
        "</ListVersionsResult>"
    >>,
    {Req, {ok, Map}} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:list_object_versions(C, <<"b">>, #{prefix => <<"k">>})
    end),
    ?assert(binary:match(maps:get(url, Req), <<"versions=">>) =/= nomatch),
    [V] = maps:get(versions, Map),
    ?assertEqual(<<"v1">>, maps:get(version_id, V)),
    ?assertEqual(true, maps:get(is_latest, V)),
    ?assertEqual(3, maps:get(size, V)),
    [D] = maps:get(delete_markers, Map),
    ?assertEqual(<<"v0">>, maps:get(version_id, D)).

%%====================================================================
%% Multipart (additional coverage)
%%====================================================================

upload_part_test() ->
    {Req, Result} = run(resp(200, [{<<"ETag">>, <<"\"p1\"">>}], <<>>), fun(C) ->
        livery_s3:upload_part(C, <<"b">>, <<"k">>, <<"UP1">>, 1, <<"data">>)
    end),
    ?assertEqual(put, maps:get(method, Req)),
    ?assert(binary:match(maps:get(url, Req), <<"partNumber=1">>) =/= nomatch),
    ?assert(binary:match(maps:get(url, Req), <<"uploadId=UP1">>) =/= nomatch),
    ?assertEqual({ok, #{etag => <<"p1">>}}, Result).

complete_multipart_success_test() ->
    Xml = <<
        "<CompleteMultipartUploadResult><ETag>\"final-1\"</ETag>"
        "<Location>http://x/k</Location></CompleteMultipartUploadResult>"
    >>,
    {Req, Result} = run(resp(200, [{<<"x-amz-version-id">>, <<"vv">>}], Xml), fun(C) ->
        livery_s3:complete_multipart_upload(C, <<"b">>, <<"k">>, <<"UP1">>, [
            {1, <<"p1">>}, {2, <<"p2">>}
        ])
    end),
    {full, Body} = maps:get(body, Req),
    ?assert(binary:match(Body, <<"<PartNumber>1</PartNumber>">>) =/= nomatch),
    ?assert(binary:match(Body, <<"<ETag>\"p1\"</ETag>">>) =/= nomatch),
    ?assertEqual(
        {ok, #{etag => <<"final-1">>, location => <<"http://x/k">>, version_id => <<"vv">>}}, Result
    ).

complete_multipart_inline_error_test() ->
    Xml = <<"<Error><Code>NoSuchUpload</Code><Message>gone</Message></Error>">>,
    {_, Result} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:complete_multipart_upload(C, <<"b">>, <<"k">>, <<"UP1">>, [{1, <<"p1">>}])
    end),
    ?assertMatch({error, {s3, <<"NoSuchUpload">>, _, _}}, Result).

abort_multipart_test() ->
    {Req, Result} = run(resp(204, [], <<>>), fun(C) ->
        livery_s3:abort_multipart_upload(C, <<"b">>, <<"k">>, <<"UP1">>)
    end),
    ?assertEqual(delete, maps:get(method, Req)),
    ?assert(binary:match(maps:get(url, Req), <<"uploadId=UP1">>) =/= nomatch),
    ?assertEqual(ok, Result).

delete_objects_versioned_with_errors_test() ->
    Xml = <<
        "<DeleteResult>"
        "<Deleted><Key>a</Key><VersionId>v1</VersionId></Deleted>"
        "<Error><Key>b</Key><Code>AccessDenied</Code><Message>no</Message></Error>"
        "</DeleteResult>"
    >>,
    {Req, {ok, Map}} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:delete_objects(C, <<"bk">>, [{<<"a">>, <<"v1">>}, <<"b">>])
    end),
    {full, Body} = maps:get(body, Req),
    ?assert(binary:match(Body, <<"<VersionId>v1</VersionId>">>) =/= nomatch),
    ?assertEqual([#{key => <<"a">>, version_id => <<"v1">>}], maps:get(deleted, Map)),
    ?assertEqual(
        [#{key => <<"b">>, code => <<"AccessDenied">>, message => <<"no">>}], maps:get(errors, Map)
    ).

%%====================================================================
%% Errors, presign, session token (additional coverage)
%%====================================================================

error_decoding_non_xml_test() ->
    {_, Result} = run(resp(500, [], <<"upstream boom">>), fun(C) ->
        livery_s3:put_object(C, <<"b">>, <<"k">>, <<"x">>)
    end),
    ?assertMatch({error, {s3, <<"500">>, <<"upstream boom">>, #{status := 500}}}, Result).

error_decoding_empty_body_test() ->
    {_, Result} = run(resp(503, [], <<>>), fun(C) ->
        livery_s3:put_object(C, <<"b">>, <<"k">>, <<"x">>)
    end),
    ?assertMatch({error, {s3, <<"503">>, <<>>, #{status := 503}}}, Result).

presign_versioned_test() ->
    C = client(resp(200, [], <<>>)),
    {ok, Url} = livery_s3:presign(C, get, <<"b">>, <<"k">>, 3600, #{version_id => <<"V7">>}),
    ?assert(binary:match(Url, <<"versionId=V7">>) =/= nomatch),
    ?assert(binary:match(Url, <<"X-Amz-Signature=">>) =/= nomatch).

session_token_signs_header_test() ->
    C = livery_s3:new(#{
        endpoint => <<"https://s3.example.com">>,
        region => <<"us-east-1">>,
        access_key_id => <<"AK">>,
        secret_access_key => <<"SK">>,
        session_token => <<"TOKEN123">>,
        adapter => livery_s3_fake_adapter,
        adapter_opts => #{
            test_pid => self(), response => resp(200, [{<<"ETag">>, <<"\"e\"">>}], <<>>)
        }
    }),
    _ = livery_s3:put_object(C, <<"b">>, <<"k">>, <<"x">>),
    Req =
        receive
            {s3_request, R} -> R
        after 2000 -> error(no_request)
        end,
    H = maps:get(headers, Req),
    ?assertEqual(<<"TOKEN123">>, header(<<"x-amz-security-token">>, H)),
    %% security-token is an x-amz-* header, so it must be in the signed set.
    Auth = header(<<"authorization">>, H),
    ?assert(binary:match(Auth, <<"x-amz-security-token">>) =/= nomatch).

network_error_passthrough_test() ->
    {_, GetResult} = run({error, econnrefused}, fun(C) ->
        livery_s3:get_object(C, <<"b">>, <<"k">>)
    end),
    ?assertEqual({error, econnrefused}, GetResult),
    {_, PutResult} = run({error, timeout}, fun(C) ->
        livery_s3:put_object(C, <<"b">>, <<"k">>, <<"x">>)
    end),
    ?assertEqual({error, timeout}, PutResult).

batch_delete_escapes_keys_test() ->
    {Req, _} = run(resp(200, [], <<"<DeleteResult/>">>), fun(C) ->
        livery_s3:delete_objects(C, <<"b">>, [<<"a&b<c>\"d'e">>])
    end),
    {full, Body} = maps:get(body, Req),
    ?assert(binary:match(Body, <<"a&amp;b&lt;c&gt;&quot;d&apos;e">>) =/= nomatch).

complete_multipart_quoted_etag_test() ->
    Xml = <<"<CompleteMultipartUploadResult><ETag>\"f\"</ETag></CompleteMultipartUploadResult>">>,
    {Req, _} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:complete_multipart_upload(C, <<"b">>, <<"k">>, <<"U">>, [{1, <<"\"already\"">>}])
    end),
    {full, Body} = maps:get(body, Req),
    ?assert(binary:match(Body, <<"<ETag>\"already\"</ETag>">>) =/= nomatch).

put_object_open_quote_etag_test() ->
    %% A malformed ETag header (open quote only) is returned verbatim.
    {_, Result} = run(resp(200, [{<<"ETag">>, <<"\"abc">>}], <<>>), fun(C) ->
        livery_s3:put_object(C, <<"b">>, <<"k">>, <<"x">>)
    end),
    ?assertEqual({ok, #{etag => <<"\"abc">>}}, Result).

presign_session_token_test() ->
    C = livery_s3:new(#{
        endpoint => <<"https://s3.example.com">>,
        region => <<"us-east-1">>,
        access_key_id => <<"AK">>,
        secret_access_key => <<"SK">>,
        session_token => <<"TKN">>,
        adapter => livery_s3_fake_adapter,
        adapter_opts => #{response => resp(200, [], <<>>)}
    }),
    {ok, Url} = livery_s3:presign(C, get, <<"b">>, <<"k">>, 900),
    ?assert(binary:match(Url, <<"X-Amz-Security-Token=TKN">>) =/= nomatch).

addressing_virtual_test() ->
    C = livery_s3:new(#{
        endpoint => <<"https://s3.example.com">>,
        region => <<"us-east-1">>,
        access_key_id => <<"AK">>,
        secret_access_key => <<"SK">>,
        addressing => virtual,
        adapter => livery_s3_fake_adapter,
        adapter_opts => #{test_pid => self(), response => resp(200, [], <<"v">>)}
    }),
    _ = livery_s3:get_object(C, <<"bucket">>, <<"key">>),
    Req =
        receive
            {s3_request, R} -> R
        after 2000 -> error(no_request)
        end,
    ?assertEqual(<<"https://bucket.s3.example.com/key">>, maps:get(url, Req)).

%% Every operation must pass a transport error straight through as {error, _}.
all_ops_network_error_test() ->
    Ops = [
        fun(C) -> livery_s3:get_object(C, <<"b">>, <<"k">>) end,
        fun(C) -> livery_s3:put_object(C, <<"b">>, <<"k">>, <<"x">>) end,
        fun(C) -> livery_s3:head_object(C, <<"b">>, <<"k">>) end,
        fun(C) -> livery_s3:delete_object(C, <<"b">>, <<"k">>) end,
        fun(C) -> livery_s3:copy_object(C, <<"b">>, <<"a">>, <<"b">>, <<"c">>) end,
        fun(C) -> livery_s3:list_buckets(C) end,
        fun(C) -> livery_s3:create_bucket(C, <<"b">>) end,
        fun(C) -> livery_s3:delete_bucket(C, <<"b">>) end,
        fun(C) -> livery_s3:head_bucket(C, <<"b">>) end,
        fun(C) -> livery_s3:list_objects(C, <<"b">>) end,
        fun(C) -> livery_s3:list_objects_all(C, <<"b">>) end,
        fun(C) -> livery_s3:get_bucket_versioning(C, <<"b">>) end,
        fun(C) -> livery_s3:put_bucket_versioning(C, <<"b">>, enabled) end,
        fun(C) -> livery_s3:list_object_versions(C, <<"b">>) end,
        fun(C) -> livery_s3:create_multipart_upload(C, <<"b">>, <<"k">>) end,
        fun(C) -> livery_s3:upload_part(C, <<"b">>, <<"k">>, <<"u">>, 1, <<"x">>) end,
        fun(C) ->
            livery_s3:complete_multipart_upload(C, <<"b">>, <<"k">>, <<"u">>, [{1, <<"e">>}])
        end,
        fun(C) -> livery_s3:abort_multipart_upload(C, <<"b">>, <<"k">>, <<"u">>) end,
        fun(C) -> livery_s3:delete_objects(C, <<"b">>, [<<"k">>]) end,
        fun(C) -> livery_s3:get_bucket_location(C, <<"b">>) end,
        fun(C) -> livery_s3:list_parts(C, <<"b">>, <<"k">>, <<"u">>) end,
        fun(C) -> livery_s3:list_multipart_uploads(C, <<"b">>) end,
        fun(C) ->
            livery_s3:upload_part_copy(C, <<"b">>, <<"k">>, <<"u">>, 1, <<"sb">>, <<"sk">>)
        end
    ],
    lists:foreach(
        fun(Op) ->
            {_, Result} = run({error, boom}, Op),
            ?assertEqual({error, boom}, Result)
        end,
        Ops
    ).

%%====================================================================
%% Conditional requests, response overrides, MD5
%%====================================================================

get_object_conditional_headers_test() ->
    {Req, _} = run(resp(200, [], <<"x">>), fun(C) ->
        livery_s3:get_object(C, <<"b">>, <<"k">>, #{
            if_none_match => <<"\"e\"">>, if_modified_since => <<"Mon, 01 Jan 2020 00:00:00 GMT">>
        })
    end),
    H = maps:get(headers, Req),
    ?assertEqual(<<"\"e\"">>, header(<<"if-none-match">>, H)),
    ?assertEqual(<<"Mon, 01 Jan 2020 00:00:00 GMT">>, header(<<"if-modified-since">>, H)).

get_object_not_modified_test() ->
    {_, R} = run(resp(304, [], <<>>), fun(C) ->
        livery_s3:get_object(C, <<"b">>, <<"k">>, #{if_none_match => <<"\"e\"">>})
    end),
    ?assertEqual({error, not_modified}, R).

get_object_precondition_failed_test() ->
    {_, R} = run(resp(412, [], <<>>), fun(C) ->
        livery_s3:get_object(C, <<"b">>, <<"k">>, #{if_match => <<"\"e\"">>})
    end),
    ?assertEqual({error, precondition_failed}, R).

head_object_not_modified_test() ->
    {_, R} = run(resp(304, [], <<>>), fun(C) ->
        livery_s3:head_object(C, <<"b">>, <<"k">>, #{if_none_match => <<"\"e\"">>})
    end),
    ?assertEqual({error, not_modified}, R).

put_object_if_none_match_test() ->
    {Req, _} = run(resp(200, [{<<"ETag">>, <<"\"e\"">>}], <<>>), fun(C) ->
        livery_s3:put_object(C, <<"b">>, <<"k">>, <<"x">>, #{if_none_match => <<"*">>})
    end),
    ?assertEqual(<<"*">>, header(<<"if-none-match">>, maps:get(headers, Req))).

put_object_precondition_failed_test() ->
    {_, R} = run(resp(412, [], <<>>), fun(C) ->
        livery_s3:put_object(C, <<"b">>, <<"k">>, <<"x">>, #{if_none_match => <<"*">>})
    end),
    ?assertEqual({error, precondition_failed}, R).

put_object_content_md5_test() ->
    {Req, _} = run(resp(200, [{<<"ETag">>, <<"\"e\"">>}], <<>>), fun(C) ->
        livery_s3:put_object(C, <<"b">>, <<"k">>, <<"hello">>, #{content_md5 => true})
    end),
    Expected = base64:encode(crypto:hash(md5, <<"hello">>)),
    ?assertEqual(Expected, header(<<"content-md5">>, maps:get(headers, Req))).

get_object_response_overrides_test() ->
    {Req, _} = run(resp(200, [], <<"x">>), fun(C) ->
        livery_s3:get_object(C, <<"b">>, <<"k">>, #{response_content_type => <<"application/xml">>})
    end),
    ?assert(
        binary:match(maps:get(url, Req), <<"response-content-type=application%2Fxml">>) =/= nomatch
    ).

presign_response_override_test() ->
    C = client(resp(200, [], <<>>)),
    {ok, Url} = livery_s3:presign(C, get, <<"b">>, <<"k">>, 300, #{
        response_content_disposition => <<"attachment">>
    }),
    ?assert(binary:match(Url, <<"response-content-disposition=attachment">>) =/= nomatch),
    ?assert(binary:match(Url, <<"X-Amz-Signature=">>) =/= nomatch).

%%====================================================================
%% Bucket location, copy source versioning
%%====================================================================

get_bucket_location_test() ->
    {Req, R} = run(resp(200, [], <<"<LocationConstraint>eu-west-1</LocationConstraint>">>), fun(C) ->
        livery_s3:get_bucket_location(C, <<"b">>)
    end),
    ?assert(binary:match(maps:get(url, Req), <<"location=">>) =/= nomatch),
    ?assertEqual({ok, <<"eu-west-1">>}, R).

get_bucket_location_default_test() ->
    {_, R} = run(resp(200, [], <<"<LocationConstraint/>">>), fun(C) ->
        livery_s3:get_bucket_location(C, <<"b">>)
    end),
    ?assertEqual({ok, <<"us-east-1">>}, R).

copy_object_source_version_test() ->
    Xml = <<"<CopyObjectResult><ETag>\"c\"</ETag></CopyObjectResult>">>,
    {Req, _} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:copy_object(C, <<"s">>, <<"a">>, <<"d">>, <<"b">>, #{version_id => <<"V1">>})
    end),
    ?assertEqual(<<"/s/a?versionId=V1">>, header(<<"x-amz-copy-source">>, maps:get(headers, Req))).

%%====================================================================
%% Multipart: list_parts, list_multipart_uploads, upload_part_copy
%%====================================================================

list_parts_test() ->
    Xml = <<
        "<ListPartsResult><IsTruncated>false</IsTruncated>"
        "<Part><PartNumber>1</PartNumber><ETag>\"p1\"</ETag><Size>5242880</Size>"
        "<LastModified>2020-01-01T00:00:00Z</LastModified></Part></ListPartsResult>"
    >>,
    {Req, {ok, Map}} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:list_parts(C, <<"b">>, <<"k">>, <<"U1">>, #{max_parts => 100})
    end),
    Url = maps:get(url, Req),
    ?assert(binary:match(Url, <<"uploadId=U1">>) =/= nomatch),
    ?assert(binary:match(Url, <<"max-parts=100">>) =/= nomatch),
    [P] = maps:get(parts, Map),
    ?assertEqual(1, maps:get(part_number, P)),
    ?assertEqual(<<"p1">>, maps:get(etag, P)),
    ?assertEqual(5242880, maps:get(size, P)).

list_multipart_uploads_test() ->
    Xml = <<
        "<ListMultipartUploadsResult><IsTruncated>false</IsTruncated>"
        "<Upload><Key>k</Key><UploadId>U1</UploadId>"
        "<Initiated>2020-01-01T00:00:00Z</Initiated></Upload></ListMultipartUploadsResult>"
    >>,
    {Req, {ok, Map}} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:list_multipart_uploads(C, <<"b">>, #{prefix => <<"k">>})
    end),
    ?assert(binary:match(maps:get(url, Req), <<"uploads=">>) =/= nomatch),
    [U] = maps:get(uploads, Map),
    ?assertEqual(<<"k">>, maps:get(key, U)),
    ?assertEqual(<<"U1">>, maps:get(upload_id, U)).

upload_part_copy_test() ->
    Xml = <<"<CopyPartResult><ETag>\"cp\"</ETag></CopyPartResult>">>,
    {Req, R} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:upload_part_copy(C, <<"b">>, <<"k">>, <<"U1">>, 2, <<"src">>, <<"o">>, #{
            range => {0, 99}
        })
    end),
    H = maps:get(headers, Req),
    ?assertEqual(<<"/src/o">>, header(<<"x-amz-copy-source">>, H)),
    ?assertEqual(<<"bytes=0-99">>, header(<<"x-amz-copy-source-range">>, H)),
    Url = maps:get(url, Req),
    ?assert(binary:match(Url, <<"partNumber=2">>) =/= nomatch),
    ?assert(binary:match(Url, <<"uploadId=U1">>) =/= nomatch),
    ?assertEqual({ok, #{etag => <<"cp">>}}, R).

%%====================================================================
%% Resilience: retry, circuit breaker, concurrency
%%====================================================================

retry_then_success_test() ->
    Ref = atomics:new(1, [{signed, false}]),
    C = client_with(
        #{retry => #{max => 3, backoff => {1, 1.0}, statuses => [503]}},
        #{
            test_pid => self(),
            counter => Ref,
            responses => [resp(503, [], <<>>), resp(200, [{<<"ETag">>, <<"\"e\"">>}], <<>>)]
        }
    ),
    Result = livery_s3:put_object(C, <<"b">>, <<"k">>, <<"x">>),
    Reqs = drain_requests(),
    ?assertEqual(2, length(Reqs)),
    ?assertMatch({ok, #{etag := <<"e">>}}, Result),
    %% Each attempt is re-signed.
    lists:foreach(
        fun(R) -> ?assertNotEqual(undefined, header(<<"authorization">>, maps:get(headers, R))) end,
        Reqs
    ).

retry_exhausts_test() ->
    Ref = atomics:new(1, [{signed, false}]),
    C = client_with(
        #{retry => #{max => 3, backoff => {1, 1.0}, statuses => [503]}},
        #{test_pid => self(), counter => Ref, responses => [resp(503, [], <<>>)]}
    ),
    Result = livery_s3:put_object(C, <<"b">>, <<"k">>, <<"x">>),
    ?assertEqual(4, length(drain_requests())),
    ?assertMatch({error, {s3, _, _, #{status := 503}}}, Result).

retry_skips_non_retryable_status_test() ->
    Ref = atomics:new(1, [{signed, false}]),
    C = client_with(
        #{retry => #{max => 3, backoff => {1, 1.0}}},
        #{test_pid => self(), counter => Ref, responses => [resp(404, [], <<>>)]}
    ),
    Result = livery_s3:head_object(C, <<"b">>, <<"k">>),
    ?assertEqual(1, length(drain_requests())),
    ?assertEqual({error, not_found}, Result).

retry_skips_streamed_body_test() ->
    Ref = atomics:new(1, [{signed, false}]),
    C = client_with(
        #{retry => #{max => 3, backoff => {1, 1.0}}},
        #{test_pid => self(), counter => Ref, responses => [{error, closed}]}
    ),
    Result = livery_s3:put_object(C, <<"b">>, <<"k">>, {stream, fun() -> eof end}),
    ?assertEqual(1, length(drain_requests())),
    ?assertEqual({error, closed}, Result).

retry_skips_non_idempotent_test() ->
    Ref = atomics:new(1, [{signed, false}]),
    C = client_with(
        #{retry => #{max => 3, backoff => {1, 1.0}, statuses => [503]}},
        #{test_pid => self(), counter => Ref, responses => [resp(503, [], <<>>)]}
    ),
    _ = livery_s3:create_multipart_upload(C, <<"b">>, <<"k">>),
    ?assertEqual(1, length(drain_requests())).

retry_after_honored_test() ->
    Ref = atomics:new(1, [{signed, false}]),
    C = client_with(
        #{retry => #{max => 2, backoff => {1, 1.0}, statuses => [503]}},
        #{
            test_pid => self(),
            counter => Ref,
            responses => [
                resp(503, [{<<"retry-after">>, <<"0">>}], <<>>),
                resp(200, [{<<"ETag">>, <<"\"e\"">>}], <<>>)
            ]
        }
    ),
    Result = livery_s3:put_object(C, <<"b">>, <<"k">>, <<"x">>),
    ?assertEqual(2, length(drain_requests())),
    ?assertMatch({ok, #{etag := <<"e">>}}, Result).

retry_disabled_test() ->
    Ref = atomics:new(1, [{signed, false}]),
    C = client_with(
        #{retry => false},
        #{test_pid => self(), counter => Ref, responses => [resp(503, [], <<>>)]}
    ),
    _ = livery_s3:get_object(C, <<"b">>, <<"k">>),
    ?assertEqual(1, length(drain_requests())).

circuit_breaker_test() ->
    {ok, _} = application:ensure_all_started(livery),
    Name = {cb, erlang:unique_integer([positive])},
    C = client_with(
        #{
            retry => false,
            circuit_breaker => #{name => Name, window => 3, trip => 0.5, cooldown => 60000}
        },
        #{response => {error, closed}}
    ),
    [
        ?assertEqual({error, closed}, livery_s3:get_object(C, <<"b">>, <<"k">>))
     || _ <- [1, 2, 3]
    ],
    ?assertEqual({error, circuit_open}, livery_s3:get_object(C, <<"b">>, <<"k">>)).

stack_builders_test() ->
    Base = #{
        endpoint => <<"https://s3.example.com">>,
        region => <<"us-east-1">>,
        access_key_id => <<"AK">>,
        secret_access_key => <<"SK">>,
        adapter => livery_s3_fake_adapter,
        adapter_opts => #{response => resp(200, [], <<>>)}
    },
    %% Every resilience option composes a usable stack (exercises build_stack/2).
    Variants = [
        Base,
        Base#{retry => true},
        Base#{circuit_breaker => true},
        Base#{circuit_breaker => #{name => cb1}},
        Base#{concurrency => 4},
        Base#{endpoints => [<<"http://a">>, <<"http://b">>]},
        Base#{balance => #{name => bal1, endpoints => [<<"http://a">>]}},
        Base#{stack => [livery_client:retry(#{max => 1})]}
    ],
    lists:foreach(
        fun(Opts) ->
            C = livery_s3:new(Opts),
            {ok, Url} = livery_s3:presign(C, get, <<"b">>, <<"k">>, 60),
            ?assert(is_binary(Url))
        end,
        Variants
    ).

concurrency_test() ->
    C = client_with(
        #{retry => false, concurrency => 1},
        #{response => resp(200, [], <<>>), delay => 200}
    ),
    Self = self(),
    [spawn(fun() -> Self ! {r, livery_s3:get_object(C, <<"b">>, <<"k">>)} end) || _ <- [1, 2, 3]],
    Results = [
        receive
            {r, R} -> R
        after 5000 -> timeout
        end
     || _ <- [1, 2, 3]
    ],
    ?assert(lists:member({error, overloaded}, Results)).

%%====================================================================
%% Region redirects
%%====================================================================

region_redirect_301_test() ->
    Ref = atomics:new(1, [{signed, false}]),
    Redirect = resp(
        301,
        [{<<"x-amz-bucket-region">>, <<"us-west-2">>}],
        <<
            "<Error><Code>PermanentRedirect</Code>"
            "<Endpoint>bucket.s3.us-west-2.amazonaws.com</Endpoint></Error>"
        >>
    ),
    Ok = resp(200, [{<<"ETag">>, <<"\"e\"">>}], <<"data">>),
    C = livery_s3:new(#{
        endpoint => <<"https://s3.us-east-1.amazonaws.com">>,
        region => <<"us-east-1">>,
        access_key_id => <<"AK">>,
        secret_access_key => <<"SK">>,
        addressing => virtual,
        retry => false,
        adapter => livery_s3_fake_adapter,
        adapter_opts => #{test_pid => self(), counter => Ref, responses => [Redirect, Ok]}
    }),
    Result = livery_s3:get_object(C, <<"bucket">>, <<"key">>),
    [R1, R2] = drain_requests(),
    ?assertEqual(<<"https://bucket.s3.us-east-1.amazonaws.com/key">>, maps:get(url, R1)),
    ?assertEqual(<<"https://bucket.s3.us-west-2.amazonaws.com/key">>, maps:get(url, R2)),
    ?assertEqual(<<"us-west-2">>, maps:get(region, maps:get(meta, R2))),
    ?assertEqual(
        <<"bucket.s3.us-west-2.amazonaws.com">>, header(<<"host">>, maps:get(headers, R2))
    ),
    ?assertMatch({ok, #{body := <<"data">>}}, Result).

region_redirect_400_resign_test() ->
    Ref = atomics:new(1, [{signed, false}]),
    Bad = resp(
        400,
        [{<<"x-amz-bucket-region">>, <<"eu-west-1">>}],
        <<"<Error><Code>AuthorizationHeaderMalformed</Code><Region>eu-west-1</Region></Error>">>
    ),
    C = livery_s3:new(#{
        endpoint => <<"https://s3.example.com">>,
        region => <<"us-east-1">>,
        access_key_id => <<"AK">>,
        secret_access_key => <<"SK">>,
        retry => false,
        adapter => livery_s3_fake_adapter,
        adapter_opts => #{
            test_pid => self(), counter => Ref, responses => [Bad, resp(200, [], <<"ok">>)]
        }
    }),
    {ok, #{body := <<"ok">>}} = livery_s3:get_object(C, <<"b">>, <<"k">>),
    [R1, R2] = drain_requests(),
    %% Same host, re-signed with the corrected region.
    ?assertEqual(maps:get(url, R1), maps:get(url, R2)),
    ?assertEqual(<<"eu-west-1">>, maps:get(region, maps:get(meta, R2))).

region_redirect_disabled_test() ->
    Ref = atomics:new(1, [{signed, false}]),
    Bad = resp(
        400,
        [],
        <<"<Error><Code>AuthorizationHeaderMalformed</Code><Region>eu-west-1</Region></Error>">>
    ),
    C = livery_s3:new(#{
        endpoint => <<"https://s3.example.com">>,
        region => <<"us-east-1">>,
        access_key_id => <<"AK">>,
        secret_access_key => <<"SK">>,
        retry => false,
        follow_region_redirects => false,
        adapter => livery_s3_fake_adapter,
        adapter_opts => #{
            test_pid => self(), counter => Ref, responses => [Bad, resp(200, [], <<"ok">>)]
        }
    }),
    Result = livery_s3:get_object(C, <<"b">>, <<"k">>),
    ?assertEqual(1, length(drain_requests())),
    ?assertMatch({error, {s3, <<"AuthorizationHeaderMalformed">>, _, _}}, Result).

non_redirect_400_test() ->
    Ref = atomics:new(1, [{signed, false}]),
    C = client_with(
        #{retry => false},
        #{
            test_pid => self(),
            counter => Ref,
            responses => [
                resp(
                    400, [], <<"<Error><Code>InvalidArgument</Code><Message>bad</Message></Error>">>
                )
            ]
        }
    ),
    Result = livery_s3:list_objects(C, <<"b">>),
    ?assertEqual(1, length(drain_requests())),
    ?assertMatch({error, {s3, <<"InvalidArgument">>, _, _}}, Result).

%% 301 with the corrected region only in the body (no x-amz-bucket-region header).
region_redirect_body_region_test() ->
    Redirect = resp(
        301,
        [],
        <<
            "<Error><Code>PermanentRedirect</Code>"
            "<Endpoint>bucket.s3.eu-central-1.amazonaws.com</Endpoint>"
            "<Region>eu-central-1</Region></Error>"
        >>
    ),
    C = redirect_client([Redirect, resp(200, [], <<"ok">>)]),
    {ok, #{body := <<"ok">>}} = livery_s3:get_object(C, <<"bucket">>, <<"key">>),
    [_, R2] = drain_requests(),
    ?assertEqual(<<"https://bucket.s3.eu-central-1.amazonaws.com/key">>, maps:get(url, R2)),
    ?assertEqual(<<"eu-central-1">>, maps:get(region, maps:get(meta, R2))).

%% 301 host move with no region echoed: host is swapped, region left as-is.
region_redirect_no_region_test() ->
    Redirect = resp(
        301,
        [],
        <<
            "<Error><Code>PermanentRedirect</Code>"
            "<Endpoint>bucket.s3.eu-west-1.amazonaws.com</Endpoint></Error>"
        >>
    ),
    C = redirect_client([Redirect, resp(200, [], <<"ok">>)]),
    {ok, #{body := <<"ok">>}} = livery_s3:get_object(C, <<"bucket">>, <<"key">>),
    [_, R2] = drain_requests(),
    ?assertEqual(<<"https://bucket.s3.eu-west-1.amazonaws.com/key">>, maps:get(url, R2)),
    ?assertEqual(error, maps:find(region, maps:get(meta, R2))).

%% 301 without an <Endpoint> cannot be followed: returned to the caller.
region_redirect_no_endpoint_test() ->
    Ref = atomics:new(1, [{signed, false}]),
    C = client_with(
        #{retry => false},
        #{
            test_pid => self(),
            counter => Ref,
            responses => [resp(301, [], <<"<Error><Code>PermanentRedirect</Code></Error>">>)]
        }
    ),
    Result = livery_s3:get_object(C, <<"b">>, <<"k">>),
    ?assertEqual(1, length(drain_requests())),
    ?assertMatch({error, {s3, <<"PermanentRedirect">>, _, _}}, Result).

%% 400 AuthorizationHeaderMalformed without a region cannot be followed.
region_redirect_400_no_region_test() ->
    Ref = atomics:new(1, [{signed, false}]),
    C = client_with(
        #{retry => false},
        #{
            test_pid => self(),
            counter => Ref,
            responses => [
                resp(400, [], <<"<Error><Code>AuthorizationHeaderMalformed</Code></Error>">>)
            ]
        }
    ),
    Result = livery_s3:get_object(C, <<"b">>, <<"k">>),
    ?assertEqual(1, length(drain_requests())),
    ?assertMatch({error, {s3, <<"AuthorizationHeaderMalformed">>, _, _}}, Result).

%% An empty-bodied error is never mistaken for a redirect.
region_redirect_empty_body_test() ->
    Ref = atomics:new(1, [{signed, false}]),
    C = client_with(
        #{retry => false},
        #{test_pid => self(), counter => Ref, responses => [resp(400, [], <<>>)]}
    ),
    Result = livery_s3:get_object(C, <<"b">>, <<"k">>),
    ?assertEqual(1, length(drain_requests())),
    ?assertMatch({error, {s3, <<"400">>, _, _}}, Result).

%%====================================================================
%% Helpers
%%====================================================================

%% Deterministic single-attempt client: retry off so these tests assert exactly
%% one request regardless of status. Resilience behavior is tested separately.
client(Resp) ->
    livery_s3:new(#{
        endpoint => <<"https://s3.example.com">>,
        region => <<"us-east-1">>,
        access_key_id => <<"AKIDEXAMPLE">>,
        secret_access_key => <<"SECRET">>,
        retry => false,
        adapter => livery_s3_fake_adapter,
        adapter_opts => #{test_pid => self(), response => Resp}
    }).

run(Resp, Fun) ->
    C = client(Resp),
    Result = Fun(C),
    receive
        {s3_request, Req} -> {Req, Result}
    after 2000 ->
        error(no_request_captured)
    end.

%% For multi-request operations: responses are consumed in order and every
%% captured request is returned.
run_seq(Responses, Fun) ->
    Ref = atomics:new(1, [{signed, false}]),
    C = livery_s3:new(#{
        endpoint => <<"https://s3.example.com">>,
        region => <<"us-east-1">>,
        access_key_id => <<"AKIDEXAMPLE">>,
        secret_access_key => <<"SECRET">>,
        retry => false,
        adapter => livery_s3_fake_adapter,
        adapter_opts => #{test_pid => self(), responses => Responses, counter => Ref}
    }),
    Result = Fun(C),
    {drain_requests(), Result}.

drain_requests() ->
    receive
        {s3_request, Req} -> [Req | drain_requests()]
    after 200 -> []
    end.

%% Virtual-hosted client for region-redirect host-swap tests (retry off).
redirect_client(Responses) ->
    Ref = atomics:new(1, [{signed, false}]),
    livery_s3:new(#{
        endpoint => <<"https://s3.us-east-1.amazonaws.com">>,
        region => <<"us-east-1">>,
        access_key_id => <<"AK">>,
        secret_access_key => <<"SK">>,
        addressing => virtual,
        retry => false,
        adapter => livery_s3_fake_adapter,
        adapter_opts => #{test_pid => self(), counter => Ref, responses => Responses}
    }).

%% Client with extra new/1 options merged over the base (for resilience tests).
client_with(Extra, AdapterOpts) ->
    livery_s3:new(
        maps:merge(
            #{
                endpoint => <<"https://s3.example.com">>,
                region => <<"us-east-1">>,
                access_key_id => <<"AK">>,
                secret_access_key => <<"SK">>,
                adapter => livery_s3_fake_adapter,
                adapter_opts => AdapterOpts
            },
            Extra
        )
    ).

resp(Status, Headers, Body) ->
    #{status => Status, headers => Headers, body => {full, Body}}.

header(Name, Headers) ->
    L = string:lowercase(Name),
    case lists:search(fun({K, _}) -> string:lowercase(K) =:= L end, Headers) of
        {value, {_, V}} -> V;
        false -> undefined
    end.

range_header_for(Range) ->
    {Req, _} = run(resp(206, [], <<>>), fun(C) ->
        livery_s3:get_object(C, <<"b">>, <<"k">>, #{range => Range})
    end),
    header(<<"range">>, maps:get(headers, Req)).
