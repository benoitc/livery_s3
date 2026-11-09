-module(livery_s3_sse_tests).

-include_lib("eunit/include/eunit.hrl").

-import(livery_s3_test_util, [run/2, run_seq/3, resp/3, header/2]).

-define(KEY, <<"0123456789abcdef0123456789abcdef">>).
-define(CUST, <<"x-amz-server-side-encryption-customer-">>).
-define(COPY_CUST, <<"x-amz-copy-source-server-side-encryption-customer-">>).

%%====================================================================
%% Header builders
%%====================================================================

sse_s3_test() ->
    ?assertEqual(
        {ok, [{<<"x-amz-server-side-encryption">>, <<"AES256">>}]},
        livery_s3_sse:write_headers(#{sse => aes256})
    ).

sse_kms_default_key_test() ->
    ?assertEqual(
        {ok, [{<<"x-amz-server-side-encryption">>, <<"aws:kms">>}]},
        livery_s3_sse:write_headers(#{sse => {kms, undefined}})
    ).

sse_kms_full_test() ->
    {ok, H} = livery_s3_sse:write_headers(#{
        sse => {kms, <<"arn:aws:kms:k">>},
        sse_kms_context => #{<<"project">> => <<"x">>},
        bucket_key_enabled => true
    }),
    ?assertEqual(<<"aws:kms">>, header(<<"x-amz-server-side-encryption">>, H)),
    ?assertEqual(<<"arn:aws:kms:k">>, header(<<"x-amz-server-side-encryption-aws-kms-key-id">>, H)),
    ?assertEqual(<<"true">>, header(<<"x-amz-server-side-encryption-bucket-key-enabled">>, H)),
    Ctx = header(<<"x-amz-server-side-encryption-context">>, H),
    ?assertEqual(#{<<"project">> => <<"x">>}, json:decode(base64:decode(Ctx))).

kms_options_without_kms_rejected_test() ->
    ?assertMatch(
        {error, {sse_option_requires_kms, _}},
        livery_s3_sse:write_headers(#{sse_kms_context => #{<<"a">> => <<"b">>}})
    ),
    ?assertMatch(
        {error, {sse_option_requires_kms, _}},
        livery_s3_sse:write_headers(#{sse => aes256, bucket_key_enabled => true})
    ).

invalid_sse_rejected_test() ->
    ?assertEqual({error, {invalid_sse, des}}, livery_s3_sse:write_headers(#{sse => des})).

sse_c_headers_test() ->
    {ok, H} = livery_s3_sse:customer_headers(#{sse_customer_key => ?KEY}),
    ?assertEqual(
        [
            {<<?CUST/binary, "algorithm">>, <<"AES256">>},
            {<<?CUST/binary, "key">>, base64:encode(?KEY)},
            {<<?CUST/binary, "key-md5">>, base64:encode(crypto:hash(md5, ?KEY))}
        ],
        H
    ).

sse_c_bad_key_length_test() ->
    ?assertEqual(
        {error, invalid_sse_customer_key},
        livery_s3_sse:customer_headers(#{sse_customer_key => <<"short">>})
    ).

copy_source_headers_test() ->
    {ok, H} = livery_s3_sse:copy_source_headers(#{copy_source_sse_customer_key => ?KEY}),
    ?assertEqual(base64:encode(?KEY), header(<<?COPY_CUST/binary, "key">>, H)),
    ?assertEqual({ok, []}, livery_s3_sse:copy_source_headers(#{})).

from_headers_test() ->
    Headers = [
        {<<"X-Amz-Server-Side-Encryption">>, <<"aws:kms">>},
        {<<"x-amz-server-side-encryption-aws-kms-key-id">>, <<"k1">>},
        {<<"x-amz-server-side-encryption-bucket-key-enabled">>, <<"TRUE">>},
        {<<"etag">>, <<"e">>}
    ],
    ?assertEqual(
        #{sse => <<"aws:kms">>, sse_kms_key_id => <<"k1">>, bucket_key_enabled => true},
        livery_s3_sse:from_headers(Headers)
    ).

%%====================================================================
%% Facade wiring
%%====================================================================

put_sse_c_signed_test() ->
    Resp = resp(200, [{<<"x-amz-server-side-encryption-customer-algorithm">>, <<"AES256">>}], <<>>),
    {Req, Result} = run(Resp, fun(C) ->
        livery_s3:put_object(C, <<"b">>, <<"k">>, <<"x">>, #{sse_customer_key => ?KEY})
    end),
    H = maps:get(headers, Req),
    ?assertEqual(base64:encode(?KEY), header(<<?CUST/binary, "key">>, H)),
    ?assertNotEqual(nomatch, binary:match(header(<<"authorization">>, H), <<?CUST/binary, "key">>)),
    ?assertMatch({ok, #{sse_customer_algorithm := <<"AES256">>}}, Result).

get_and_head_send_customer_key_test() ->
    Resp = resp(200, [{<<"x-amz-server-side-encryption">>, <<"AES256">>}], <<"x">>),
    {GetReq, {ok, #{sse := <<"AES256">>}}} = run(Resp, fun(C) ->
        livery_s3:get_object(C, <<"b">>, <<"k">>, #{sse_customer_key => ?KEY})
    end),
    ?assertEqual(<<"AES256">>, header(<<?CUST/binary, "algorithm">>, maps:get(headers, GetReq))),
    {HeadReq, {ok, _}} = run(Resp, fun(C) ->
        livery_s3:head_object(C, <<"b">>, <<"k">>, #{sse_customer_key => ?KEY})
    end),
    ?assertEqual(base64:encode(?KEY), header(<<?CUST/binary, "key">>, maps:get(headers, HeadReq))).

copy_with_both_keys_test() ->
    Xml = <<"<CopyObjectResult><ETag>\"c\"</ETag></CopyObjectResult>">>,
    {Req, {ok, #{etag := <<"c">>}}} = run(resp(200, [], Xml), fun(C) ->
        livery_s3:copy_object(C, <<"b">>, <<"src">>, <<"b">>, <<"dst">>, #{
            sse => aes256, copy_source_sse_customer_key => ?KEY
        })
    end),
    H = maps:get(headers, Req),
    ?assertEqual(<<"AES256">>, header(<<"x-amz-server-side-encryption">>, H)),
    ?assertEqual(base64:encode(?KEY), header(<<?COPY_CUST/binary, "key">>, H)),
    ?assertEqual(undefined, header(<<?CUST/binary, "key">>, H)).

multipart_sse_c_test() ->
    Init =
        <<"<InitiateMultipartUploadResult><UploadId>U</UploadId></InitiateMultipartUploadResult>">>,
    Part = resp(200, [{<<"ETag">>, <<"\"p\"">>}], <<>>),
    CopyPart = <<"<CopyPartResult><ETag>\"cp\"</ETag></CopyPartResult>">>,
    Done = <<"<CompleteMultipartUploadResult><ETag>\"m\"</ETag></CompleteMultipartUploadResult>">>,
    Responses = [resp(200, [], Init), Part, resp(200, [], CopyPart), resp(200, [], Done)],
    Opts = #{sse_customer_key => ?KEY},
    {Reqs, {ok, _}} = run_seq(Responses, #{}, fun(C) ->
        {ok, U} = livery_s3:create_multipart_upload(C, <<"b">>, <<"k">>, Opts),
        {ok, _} = livery_s3:upload_part(C, <<"b">>, <<"k">>, U, 1, <<"x">>, Opts),
        {ok, _} = livery_s3:upload_part_copy(C, <<"b">>, <<"k">>, U, 2, <<"b">>, <<"s">>, Opts),
        livery_s3:complete_multipart_upload(
            C, <<"b">>, <<"k">>, U, [{1, <<"p">>}, {2, <<"cp">>}], Opts
        )
    end),
    ?assertEqual(4, length(Reqs)),
    [
        ?assertEqual(base64:encode(?KEY), header(<<?CUST/binary, "key">>, maps:get(headers, R)))
     || R <- Reqs
    ].

bad_key_sends_nothing_test() ->
    {Reqs, Result} = run_seq([resp(200, [], <<>>)], #{}, fun(C) ->
        livery_s3:get_object(C, <<"b">>, <<"k">>, #{sse_customer_key => <<"short">>})
    end),
    ?assertEqual([], Reqs),
    ?assertEqual({error, invalid_sse_customer_key}, Result).
