-module(livery_s3_checksum_tests).

-include_lib("eunit/include/eunit.hrl").

-import(livery_s3_test_util, [run/2, run_seq/3, resp/3, header/2]).

-define(CHECK, <<"123456789">>).

%%====================================================================
%% Algorithms (standard check values for "123456789")
%%====================================================================

crc32_check_value_test() ->
    ?assertEqual(b64(<<16#CBF43926:32>>), livery_s3_checksum:compute(crc32, ?CHECK)).

crc32c_check_value_test() ->
    ?assertEqual(b64(<<16#E3069283:32>>), livery_s3_checksum:compute(crc32c, ?CHECK)).

crc32c_empty_test() ->
    ?assertEqual(b64(<<0:32>>), livery_s3_checksum:compute(crc32c, <<>>)).

%% RFC 3720 B.4: 32 bytes of zeros, and 32 bytes of 0xFF.
crc32c_rfc3720_vectors_test() ->
    ?assertEqual(b64(<<16#8A9136AA:32>>), livery_s3_checksum:compute(crc32c, <<0:256>>)),
    ?assertEqual(
        b64(<<16#62A8AB43:32>>),
        livery_s3_checksum:compute(crc32c, binary:copy(<<16#FF>>, 32))
    ).

sha_test() ->
    ?assertEqual(b64(crypto:hash(sha, ?CHECK)), livery_s3_checksum:compute(sha1, ?CHECK)),
    ?assertEqual(b64(crypto:hash(sha256, ?CHECK)), livery_s3_checksum:compute(sha256, ?CHECK)).

iodata_equals_flat_test() ->
    Io = [<<"123">>, ["45", [$6]], <<"789">>],
    [
        ?assertEqual(livery_s3_checksum:compute(A, ?CHECK), livery_s3_checksum:compute(A, Io))
     || A <- [crc32, crc32c, sha1, sha256]
    ].

from_headers_test() ->
    Headers = [
        {<<"X-Amz-Checksum-CRC32C">>, <<"a">>},
        {<<"x-amz-checksum-sha256">>, <<"b">>},
        {<<"x-amz-checksum-type">>, <<"FULL_OBJECT">>},
        {<<"etag">>, <<"e">>}
    ],
    ?assertEqual(#{crc32c => <<"a">>, sha256 => <<"b">>}, livery_s3_checksum:from_headers(Headers)).

headers_invalid_algorithm_test() ->
    ?assertEqual(
        {error, {invalid_checksum_algorithm, md5}},
        livery_s3_checksum:headers(#{checksum => md5}, {full, <<>>})
    ).

%%====================================================================
%% Facade wiring
%%====================================================================

put_sends_computed_checksum_test() ->
    {Req, Result} = run(resp(200, [{<<"x-amz-checksum-crc32c">>, <<"echo">>}], <<>>), fun(C) ->
        livery_s3:put_object(C, <<"b">>, <<"k">>, ?CHECK, #{checksum => crc32c})
    end),
    Headers = maps:get(headers, Req),
    ?assertEqual(
        livery_s3_checksum:compute(crc32c, ?CHECK), header(<<"x-amz-checksum-crc32c">>, Headers)
    ),
    %% x-amz-* headers are signed.
    ?assertNotEqual(
        nomatch, binary:match(header(<<"authorization">>, Headers), <<"x-amz-checksum-crc32c">>)
    ),
    ?assertMatch({ok, #{checksum := #{crc32c := <<"echo">>}}}, Result).

put_stream_requires_precomputed_test() ->
    C = livery_s3_test_util:client(resp(200, [], <<>>)),
    Stream = {stream, fun() -> eof end},
    ?assertEqual(
        {error, {checksum_requires_full_body, sha256}},
        livery_s3:put_object(C, <<"b">>, <<"k">>, Stream, #{checksum => sha256})
    ).

put_stream_precomputed_passes_test() ->
    Stream = {stream, fun() -> eof end},
    {Req, _} = run(resp(200, [], <<>>), fun(C) ->
        livery_s3:put_object(C, <<"b">>, <<"k">>, Stream, #{checksum => {sha256, <<"given">>}})
    end),
    ?assertEqual(<<"given">>, header(<<"x-amz-checksum-sha256">>, maps:get(headers, Req))).

get_checksum_mode_test() ->
    Resp = resp(200, [{<<"x-amz-checksum-crc32">>, <<"v">>}], <<"x">>),
    {Req, Result} = run(Resp, fun(C) ->
        livery_s3:get_object(C, <<"b">>, <<"k">>, #{checksum_mode => true})
    end),
    ?assertEqual(<<"ENABLED">>, header(<<"x-amz-checksum-mode">>, maps:get(headers, Req))),
    ?assertMatch({ok, #{checksum := #{crc32 := <<"v">>}}}, Result).

head_without_checksum_mode_test() ->
    {Req, Result} = run(resp(200, [], <<>>), fun(C) ->
        livery_s3:head_object(C, <<"b">>, <<"k">>)
    end),
    ?assertEqual(undefined, header(<<"x-amz-checksum-mode">>, maps:get(headers, Req))),
    {ok, Meta} = Result,
    ?assertNot(maps:is_key(checksum, Meta)).

create_multipart_announces_algorithm_test() ->
    Xml =
        <<"<InitiateMultipartUploadResult><UploadId>U</UploadId></InitiateMultipartUploadResult>">>,
    {Req, {ok, <<"U">>}} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:create_multipart_upload(C, <<"b">>, <<"k">>, #{checksum_algorithm => crc32c})
    end),
    ?assertEqual(<<"CRC32C">>, header(<<"x-amz-checksum-algorithm">>, maps:get(headers, Req))).

upload_part_checksum_test() ->
    Resp = resp(200, [{<<"ETag">>, <<"\"p1\"">>}, {<<"x-amz-checksum-crc32c">>, <<"c1">>}], <<>>),
    {Req, Result} = run(Resp, fun(C) ->
        livery_s3:upload_part(C, <<"b">>, <<"k">>, <<"U">>, 1, ?CHECK, #{checksum => crc32c})
    end),
    ?assertEqual(
        livery_s3_checksum:compute(crc32c, ?CHECK),
        header(<<"x-amz-checksum-crc32c">>, maps:get(headers, Req))
    ),
    ?assertEqual({ok, #{etag => <<"p1">>, checksum => #{crc32c => <<"c1">>}}}, Result).

complete_with_part_checksums_test() ->
    Xml = <<
        "<CompleteMultipartUploadResult><ETag>\"m-2\"</ETag>"
        "<ChecksumCRC32C>whole-2</ChecksumCRC32C></CompleteMultipartUploadResult>"
    >>,
    {Req, Result} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:complete_multipart_upload(C, <<"b">>, <<"k">>, <<"U">>, [
            {1, <<"p1">>, #{crc32c => <<"c1">>}},
            {2, <<"p2">>}
        ])
    end),
    {full, Body} = maps:get(body, Req),
    ?assertNotEqual(
        nomatch,
        binary:match(Body, <<"<ETag>\"p1\"</ETag><ChecksumCRC32C>c1</ChecksumCRC32C></Part>">>)
    ),
    ?assertNotEqual(nomatch, binary:match(Body, <<"<ETag>\"p2\"</ETag></Part>">>)),
    ?assertMatch({ok, #{etag := <<"m-2">>, checksum := #{crc32c := <<"whole-2">>}}}, Result).

bad_digest_decodes_test() ->
    Xml = <<"<Error><Code>BadDigest</Code><Message>mismatch</Message></Error>">>,
    {_, Result} = run(resp(400, [], Xml), fun(C) ->
        livery_s3:put_object(C, <<"b">>, <<"k">>, <<"x">>, #{checksum => {crc32, <<"AAAAAA==">>}})
    end),
    ?assertMatch({error, {s3, <<"BadDigest">>, _, #{status := 400}}}, Result).

%% A checksum error never reaches the wire.
invalid_algorithm_sends_nothing_test() ->
    {Reqs, Result} = run_seq([resp(200, [], <<>>)], #{}, fun(C) ->
        livery_s3:put_object(C, <<"b">>, <<"k">>, <<"x">>, #{checksum => md5})
    end),
    ?assertEqual([], Reqs),
    ?assertEqual({error, {invalid_checksum_algorithm, md5}}, Result).

b64(Bin) -> base64:encode(Bin).
