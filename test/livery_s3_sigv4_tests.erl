-module(livery_s3_sigv4_tests).

-include_lib("eunit/include/eunit.hrl").
-include("livery_s3.hrl").

%% AWS published S3 SigV4 worked examples. Keys, region, and date are fixed by
%% AWS; the expected signatures are the values from the documentation.
-define(AK, <<"AKIAIOSFODNN7EXAMPLE">>).
-define(SK, <<"wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY">>).
-define(REGION, <<"us-east-1">>).
-define(DATETIME, <<"20130524T000000Z">>).
-define(DATE, <<"20130524">>).

%% Example 1: GET Object with a Range header.
get_object_example_test() ->
    Headers = [
        {<<"host">>, <<"examplebucket.s3.amazonaws.com">>},
        {<<"range">>, <<"bytes=0-9">>},
        {<<"x-amz-content-sha256">>, ?EMPTY_SHA256},
        {<<"x-amz-date">>, ?DATETIME}
    ],
    Auth = livery_s3_sigv4:authorization(#{
        method => <<"GET">>,
        path => <<"/test.txt">>,
        query => <<>>,
        headers => Headers,
        payload_hash => ?EMPTY_SHA256,
        access_key_id => ?AK,
        secret => ?SK,
        region => ?REGION,
        service => ?S3_SERVICE,
        datetime => ?DATETIME,
        date => ?DATE
    }),
    Expected = <<
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
        "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, "
        "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
    >>,
    ?assertEqual(Expected, Auth).

%% Example 2: PUT Object with a body and storage class.
put_object_example_test() ->
    PayloadHash = sha256_hex(<<"Welcome to Amazon S3.">>),
    Headers = [
        {<<"date">>, <<"Fri, 24 May 2013 00:00:00 GMT">>},
        {<<"host">>, <<"examplebucket.s3.amazonaws.com">>},
        {<<"x-amz-content-sha256">>, PayloadHash},
        {<<"x-amz-date">>, ?DATETIME},
        {<<"x-amz-storage-class">>, <<"REDUCED_REDUNDANCY">>}
    ],
    Auth = livery_s3_sigv4:authorization(#{
        method => <<"PUT">>,
        path => <<"/test%24file.text">>,
        query => <<>>,
        headers => Headers,
        payload_hash => PayloadHash,
        access_key_id => ?AK,
        secret => ?SK,
        region => ?REGION,
        service => ?S3_SERVICE,
        datetime => ?DATETIME,
        date => ?DATE
    }),
    Expected = <<
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
        "SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class, "
        "Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"
    >>,
    ?assertEqual(Expected, Auth).

%% Example 3: presigned GET URL (query-string signing).
presigned_url_example_test() ->
    Cfg = #s3_config{
        scheme = <<"https">>,
        host = <<"s3.amazonaws.com">>,
        port = undefined,
        region = ?REGION,
        access_key_id = ?AK,
        secret_access_key = ?SK,
        session_token = undefined,
        addressing = virtual
    },
    Url = livery_s3_sigv4:presigned_url(
        Cfg, get, <<"examplebucket">>, <<"test.txt">>, 86400, [], ?DATETIME, ?DATE
    ),
    Expected = <<
        "https://examplebucket.s3.amazonaws.com/test.txt?"
        "X-Amz-Algorithm=AWS4-HMAC-SHA256&"
        "X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&"
        "X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&"
        "X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
    >>,
    ?assertEqual(Expected, Url).

%% Internal header whitespace runs are collapsed before signing, so values that
%% differ only by extra spaces produce the same signature (SigV4 Trimall).
header_whitespace_collapse_test() ->
    Sign = fun(Value) ->
        livery_s3_sigv4:authorization(#{
            method => <<"PUT">>,
            path => <<"/k">>,
            query => <<>>,
            headers => [
                {<<"host">>, <<"h">>},
                {<<"x-amz-meta-note">>, Value}
            ],
            payload_hash => ?EMPTY_SHA256,
            access_key_id => ?AK,
            secret => ?SK,
            region => ?REGION,
            service => ?S3_SERVICE,
            datetime => ?DATETIME,
            date => ?DATE
        })
    end,
    ?assertEqual(Sign(<<"a  b   c">>), Sign(<<"a b c">>)).

sha256_hex(Data) ->
    list_to_binary([io_lib:format("~2.16.0b", [B]) || <<B>> <= crypto:hash(sha256, Data)]).
