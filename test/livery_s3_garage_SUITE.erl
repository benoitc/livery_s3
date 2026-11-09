-module(livery_s3_garage_SUITE).
-moduledoc """
Integration suite against a real Garage S3 endpoint.

Bring Garage up with `test/docker/garage-up.sh` (or `make test`). The suite reads
`LIVERY_S3_ENDPOINT`/`_REGION`/`_ACCESS_KEY`/`_SECRET_KEY`/`_BUCKET` from the
environment, falling back to the local Garage defaults. If the endpoint is
unreachable the whole suite skips, so a machine without Docker is not a failure.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    object_crud/1,
    range_get/1,
    metadata_roundtrip/1,
    streaming_download/1,
    list_objects/1,
    copy_object/1,
    multipart_upload/1,
    batch_delete/1,
    presign_roundtrip/1,
    bucket_lifecycle/1,
    versioning/1,
    bucket_location/1,
    conditional_get/1,
    multipart_complete_conditional_fresh/1,
    multipart_complete_no_such_upload/1,
    multipart_complete_if_none_match_existing/1,
    multipart_complete_if_match_deleted/1,
    multipart_listing/1,
    upload_part_copy/1,
    presign_response_override/1,
    resilience_stack/1,
    credential_env_provider/1,
    anonymous_public_read/1,
    anonymous_denied_on_private/1,
    checksum_roundtrip/1,
    checksum_mismatch_rejected/1,
    checksum_multipart/1,
    sse_c_roundtrip/1,
    sse_c_copy/1,
    sse_s3_roundtrip/1,
    sse_kms_roundtrip/1,
    post_upload/1,
    post_upload_filename/1,
    post_too_large_rejected/1,
    post_expired_rejected/1,
    tagging_roundtrip/1,
    tagging_on_write/1,
    list_encoding_url/1,
    request_payer_ignored/1
]).

all() ->
    [
        object_crud,
        range_get,
        metadata_roundtrip,
        streaming_download,
        list_objects,
        copy_object,
        multipart_upload,
        batch_delete,
        presign_roundtrip,
        bucket_lifecycle,
        versioning,
        bucket_location,
        conditional_get,
        multipart_complete_conditional_fresh,
        multipart_complete_no_such_upload,
        multipart_complete_if_none_match_existing,
        multipart_complete_if_match_deleted,
        multipart_listing,
        upload_part_copy,
        presign_response_override,
        resilience_stack,
        credential_env_provider,
        anonymous_public_read,
        anonymous_denied_on_private,
        checksum_roundtrip,
        checksum_mismatch_rejected,
        checksum_multipart,
        sse_c_roundtrip,
        sse_c_copy,
        sse_s3_roundtrip,
        sse_kms_roundtrip,
        post_upload,
        post_upload_filename,
        post_too_large_rejected,
        post_expired_rejected,
        tagging_roundtrip,
        tagging_on_write,
        list_encoding_url,
        request_payer_ignored
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(hackney),
    %% livery app provides the circuit/balance ETS stores.
    {ok, _} = application:ensure_all_started(livery),
    Endpoint = env("LIVERY_S3_ENDPOINT", <<"http://127.0.0.1:3900">>),
    Opts = #{
        endpoint => Endpoint,
        region => env("LIVERY_S3_REGION", <<"garage">>),
        access_key_id => env("LIVERY_S3_ACCESS_KEY", <<"GKtestaccesskey1234567890">>),
        secret_access_key =>
            env("LIVERY_S3_SECRET_KEY", <<"testsecretkey00000000000000000000000000000000000">>)
    },
    Client = livery_s3:new(Opts),
    case wait_ready(Client, 30) of
        ok ->
            [
                {client, Client},
                {opts, Opts},
                {backend, backend()},
                {bucket, env("LIVERY_S3_BUCKET", <<"livery-s3-test">>)}
                | Config
            ];
        error ->
            {skip, "garage not reachable at " ++ binary_to_list(Endpoint)}
    end.

end_per_suite(_Config) ->
    ok.

%%====================================================================
%% Object operations
%%====================================================================

object_crud(Config) ->
    {C, B} = ctx(Config),
    K = uniq(<<"crud-">>),
    {ok, #{etag := _}} = livery_s3:put_object(C, B, K, <<"hello">>, #{
        content_type => <<"text/plain">>, metadata => #{<<"a">> => <<"1">>}
    }),
    {ok, Meta} = livery_s3:head_object(C, B, K),
    ?assertEqual(5, maps:get(content_length, Meta)),
    ?assertEqual(#{<<"a">> => <<"1">>}, maps:get(metadata, Meta)),
    ?assertEqual(<<"text/plain">>, maps:get(content_type, Meta)),
    {ok, #{body := <<"hello">>}} = livery_s3:get_object(C, B, K),
    ok = livery_s3:delete_object(C, B, K),
    ?assertEqual({error, not_found}, livery_s3:head_object(C, B, K)).

range_get(Config) ->
    {C, B} = ctx(Config),
    K = uniq(<<"range-">>),
    {ok, _} = livery_s3:put_object(C, B, K, <<"abcdefghij">>),
    {ok, #{body := <<"abcde">>}} = livery_s3:get_object(C, B, K, #{range => {0, 4}}),
    {ok, #{body := <<"hij">>}} = livery_s3:get_object(C, B, K, #{range => {suffix, 3}}),
    {ok, #{body := <<"fghij">>}} = livery_s3:get_object(C, B, K, #{range => {5, eof}}),
    ok = livery_s3:delete_object(C, B, K).

metadata_roundtrip(Config) ->
    {C, B} = ctx(Config),
    K = uniq(<<"meta-">>),
    Meta = #{<<"author">> => <<"benoitc">>, <<"team">> => <<"enki">>},
    {ok, _} = livery_s3:put_object(C, B, K, <<"x">>, #{metadata => Meta}),
    {ok, #{metadata := Got}} = livery_s3:head_object(C, B, K),
    ?assertEqual(Meta, Got),
    ok = livery_s3:delete_object(C, B, K).

streaming_download(Config) ->
    {C, B} = ctx(Config),
    K = uniq(<<"stream-">>),
    Payload = binary:copy(<<"x">>, 1000),
    {ok, _} = livery_s3:put_object(C, B, K, Payload),
    {ok, #{body := {stream, Reader}}} = livery_s3:get_object(C, B, K, #{stream => true}),
    {ok, Bin} = livery_client:read_body(Reader),
    ?assertEqual(1000, byte_size(Bin)),
    ok = livery_s3:delete_object(C, B, K).

list_objects(Config) ->
    {C, B} = ctx(Config),
    Prefix = <<(uniq(<<"list-">>))/binary, "/">>,
    Keys = [<<Prefix/binary, (integer_to_binary(N))/binary>> || N <- [1, 2, 3]],
    [{ok, _} = livery_s3:put_object(C, B, K, <<"v">>) || K <- Keys],
    {ok, #{objects := Objects}} = livery_s3:list_objects(C, B, #{prefix => Prefix}),
    Got = lists:sort([maps:get(key, O) || O <- Objects]),
    ?assertEqual(lists:sort(Keys), Got),
    [ok = livery_s3:delete_object(C, B, K) || K <- Keys].

copy_object(Config) ->
    {C, B} = ctx(Config),
    Src = uniq(<<"copy-src-">>),
    Dst = uniq(<<"copy-dst-">>),
    {ok, _} = livery_s3:put_object(C, B, Src, <<"payload">>),
    {ok, #{etag := _}} = livery_s3:copy_object(C, B, Src, B, Dst),
    {ok, #{body := <<"payload">>}} = livery_s3:get_object(C, B, Dst),
    ok = livery_s3:delete_object(C, B, Src),
    ok = livery_s3:delete_object(C, B, Dst).

multipart_upload(Config) ->
    {C, B} = ctx(Config),
    K = uniq(<<"mpu-">>),
    {ok, UploadId} = livery_s3:create_multipart_upload(C, B, K),
    {ok, #{etag := ETag}} = livery_s3:upload_part(C, B, K, UploadId, 1, binary:copy(<<"a">>, 100)),
    {ok, #{etag := _}} = livery_s3:complete_multipart_upload(C, B, K, UploadId, [{1, ETag}]),
    {ok, #{body := Body}} = livery_s3:get_object(C, B, K),
    ?assertEqual(100, byte_size(Body)),
    ok = livery_s3:delete_object(C, B, K).

batch_delete(Config) ->
    {C, B} = ctx(Config),
    K1 = uniq(<<"bd-">>),
    K2 = uniq(<<"bd-">>),
    {ok, _} = livery_s3:put_object(C, B, K1, <<"1">>),
    {ok, _} = livery_s3:put_object(C, B, K2, <<"2">>),
    {ok, #{deleted := Deleted, errors := []}} = livery_s3:delete_objects(C, B, [K1, K2]),
    ?assertEqual(2, length(Deleted)),
    ?assertEqual({error, not_found}, livery_s3:head_object(C, B, K1)),
    ?assertEqual({error, not_found}, livery_s3:head_object(C, B, K2)).

presign_roundtrip(Config) ->
    {C, B} = ctx(Config),
    K = uniq(<<"ps-">>),
    {ok, _} = livery_s3:put_object(C, B, K, <<"presigned-content">>),
    {ok, Url} = livery_s3:presign(C, get, B, K, 3600),
    {ok, 200, _, Body} = hackney:request(get, Url, [], <<>>, [{with_body, true}]),
    ?assertEqual(<<"presigned-content">>, Body),
    ok = livery_s3:delete_object(C, B, K).

%%====================================================================
%% Buckets and versioning
%%====================================================================

bucket_lifecycle(Config) ->
    {C, _B} = ctx(Config),
    NB = uniq(<<"lc-">>),
    case livery_s3:create_bucket(C, NB) of
        ok ->
            ?assertEqual(ok, livery_s3:head_bucket(C, NB)),
            ?assertEqual(ok, livery_s3:delete_bucket(C, NB)),
            ?assertEqual({error, not_found}, livery_s3:head_bucket(C, NB));
        {error, Reason} ->
            {skip, {bucket_create_unsupported, Reason}}
    end.

versioning(Config) ->
    {C, B} = ctx(Config),
    %% Garage does not implement versioning; require a clean result either way.
    case livery_s3:get_bucket_versioning(C, B) of
        {ok, S} when S =:= none; S =:= enabled; S =:= suspended -> ok;
        {error, {s3, _, _, _}} -> ok
    end,
    case livery_s3:put_bucket_versioning(C, B, enabled) of
        ok -> ok;
        {error, {s3, _Code, _Msg, _Meta}} -> ok
    end.

%%====================================================================
%% Conditional requests, bucket location, multipart listing/copy
%%====================================================================

bucket_location(Config) ->
    {C, B} = ctx(Config),
    {ok, Region} = livery_s3:get_bucket_location(C, B),
    ?assert(is_binary(Region)).

conditional_get(Config) ->
    {C, B} = ctx(Config),
    K = uniq(<<"cond-">>),
    {ok, #{etag := ETag}} = livery_s3:put_object(C, B, K, <<"hello">>),
    Quoted = <<"\"", ETag/binary, "\"">>,
    ?assertEqual({error, not_modified}, livery_s3:get_object(C, B, K, #{if_none_match => Quoted})),
    ?assertEqual(
        {error, precondition_failed},
        livery_s3:get_object(C, B, K, #{if_match => <<"\"deadbeef\"">>})
    ),
    {ok, #{body := <<"hello">>}} = livery_s3:get_object(C, B, K, #{if_match => Quoted}),
    ok = livery_s3:delete_object(C, B, K).

%% A conditional completion over a key that does not exist: the precondition
%% holds, so this must succeed on every store, whether or not it enforces
%% conditional writes. Proves the header signs and round-trips.
multipart_complete_conditional_fresh(Config) ->
    {C, B} = ctx(Config),
    K = uniq(<<"mpu-cond-fresh-">>),
    Part = binary:copy(<<"a">>, 100),
    {ok, UploadId} = livery_s3:create_multipart_upload(C, B, K),
    {ok, #{etag := ETag}} = livery_s3:upload_part(C, B, K, UploadId, 1, Part),
    {ok, #{etag := _}} = livery_s3:complete_multipart_upload(C, B, K, UploadId, [{1, ETag}], #{
        if_none_match => <<"*">>
    }),
    {ok, #{body := Got}} = livery_s3:get_object(C, B, K),
    ?assertEqual(Part, Got),
    ok = livery_s3:delete_object(C, B, K).

%% A dead upload id is not the if_match-lost-to-delete race, so it must keep
%% its S3 error code even though the request carries a conditional header.
%% This needs no conditional-write support, so it is strict on every store.
multipart_complete_no_such_upload(Config) ->
    {C, B} = ctx(Config),
    K = uniq(<<"mpu-dead-">>),
    {ok, UploadId} = livery_s3:create_multipart_upload(C, B, K),
    {ok, #{etag := ETag}} = livery_s3:upload_part(C, B, K, UploadId, 1, binary:copy(<<"a">>, 100)),
    ok = livery_s3:abort_multipart_upload(C, B, K, UploadId),
    Result = livery_s3:complete_multipart_upload(C, B, K, UploadId, [{1, ETag}], #{
        if_match => <<"\"deadbeef\"">>
    }),
    ct:pal("dead upload id + if_match -> ~p", [Result]),
    ?assertNotEqual({error, not_found}, Result),
    ?assertMatch({error, {s3, _, _, _}}, Result).

%% A conditional completion over a key that already exists. Stores that enforce
%% conditional writes must reject it and leave the object untouched; stores that
%% ignore the header must complete and replace it. Both branches assert the
%% resulting object state, so neither is a free pass.
multipart_complete_if_none_match_existing(Config) ->
    {C, B} = ctx(Config),
    K = uniq(<<"mpu-cond-exists-">>),
    Original = <<"original">>,
    New = binary:copy(<<"b">>, 100),
    {ok, _} = livery_s3:put_object(C, B, K, Original),
    {ok, UploadId} = livery_s3:create_multipart_upload(C, B, K),
    {ok, #{etag := ETag}} = livery_s3:upload_part(C, B, K, UploadId, 1, New),
    Result = livery_s3:complete_multipart_upload(C, B, K, UploadId, [{1, ETag}], #{
        if_none_match => <<"*">>
    }),
    case Result of
        {error, R} when R =:= precondition_failed; R =:= conditional_request_conflict ->
            ct:pal("store ENFORCES conditional completion (~p)", [R]),
            {ok, #{body := Original}} = livery_s3:get_object(C, B, K),
            ok = livery_s3:abort_multipart_upload(C, B, K, UploadId);
        {ok, #{etag := _}} ->
            ct:pal("store IGNORES conditional completion: object was replaced"),
            {ok, #{body := Got}} = livery_s3:get_object(C, B, K),
            ?assertEqual(New, Got);
        {error, {s3, Code, _, _}} ->
            %% Store refuses conditional completion outright. The object must
            %% still be untouched, and the upload must still be abortable.
            ct:pal("store REJECTS conditional completion (~s)", [Code]),
            {ok, #{body := Original}} = livery_s3:get_object(C, B, K),
            ok = livery_s3:abort_multipart_upload(C, B, K, UploadId)
    end,
    ok = livery_s3:delete_object(C, B, K).

%% The 404 race AWS documents for if_match, staged deterministically rather
%% than raced: the object named by if_match is deleted before the completion
%% lands. Stores split three ways here, and all three are legitimate:
%%
%%   * enforcing (AWS)  -> not_found: the object the condition named is gone.
%%   * Garage           -> NoSuchUpload: deleting the key also discards the
%%                         in-flight upload, so the upload id dies first.
%%   * ignoring          -> the completion simply succeeds.
%%
%% The property that must hold everywhere is that a dead upload id keeps its S3
%% code instead of being flattened into not_found, since the two need different
%% recovery (re-upload the parts vs. the object really is absent).
multipart_complete_if_match_deleted(Config) ->
    {C, B} = ctx(Config),
    K = uniq(<<"mpu-cond-del-">>),
    {ok, #{etag := Original}} = livery_s3:put_object(C, B, K, <<"original">>),
    Quoted = <<"\"", Original/binary, "\"">>,
    {ok, UploadId} = livery_s3:create_multipart_upload(C, B, K),
    {ok, #{etag := ETag}} = livery_s3:upload_part(C, B, K, UploadId, 1, binary:copy(<<"c">>, 100)),
    ok = livery_s3:delete_object(C, B, K),
    Result = livery_s3:complete_multipart_upload(C, B, K, UploadId, [{1, ETag}], #{
        if_match => Quoted
    }),
    ct:pal("if_match after concurrent delete -> ~p", [Result]),
    case Result of
        {error, Reason} when Reason =:= not_found; Reason =:= precondition_failed ->
            ?assertEqual({error, not_found}, livery_s3:head_object(C, B, K)),
            _ = livery_s3:abort_multipart_upload(C, B, K, UploadId);
        {error, {s3, <<"NoSuchUpload">>, _, _}} ->
            %% The store discarded the upload along with the key. The object is
            %% still gone, and the caller can tell "re-upload the parts" apart
            %% from "the object is absent".
            ?assertEqual({error, not_found}, livery_s3:head_object(C, B, K));
        {ok, #{etag := _}} ->
            {ok, _} = livery_s3:head_object(C, B, K),
            ok = livery_s3:delete_object(C, B, K)
    end.

multipart_listing(Config) ->
    {C, B} = ctx(Config),
    K = uniq(<<"mpl-">>),
    Part = binary:copy(<<"a">>, 5 * 1024 * 1024),
    {ok, UploadId} = livery_s3:create_multipart_upload(C, B, K),
    {ok, #{etag := _}} = livery_s3:upload_part(C, B, K, UploadId, 1, Part),
    {ok, #{parts := Parts}} = livery_s3:list_parts(C, B, K, UploadId),
    ?assertEqual(1, length(Parts)),
    {ok, #{uploads := Uploads}} = livery_s3:list_multipart_uploads(C, B),
    ?assert(lists:any(fun(U) -> maps:get(upload_id, U) =:= UploadId end, Uploads)),
    ok = livery_s3:abort_multipart_upload(C, B, K, UploadId).

upload_part_copy(Config) ->
    {C, B} = ctx(Config),
    Src = uniq(<<"upc-src-">>),
    Dst = uniq(<<"upc-dst-">>),
    Size = 5 * 1024 * 1024,
    {ok, _} = livery_s3:put_object(C, B, Src, binary:copy(<<"a">>, Size)),
    {ok, UploadId} = livery_s3:create_multipart_upload(C, B, Dst),
    {ok, #{etag := ETag}} = livery_s3:upload_part_copy(C, B, Dst, UploadId, 1, B, Src),
    {ok, #{etag := _}} = livery_s3:complete_multipart_upload(C, B, Dst, UploadId, [{1, ETag}]),
    {ok, #{body := Body}} = livery_s3:get_object(C, B, Dst),
    ?assertEqual(Size, byte_size(Body)),
    ok = livery_s3:delete_object(C, B, Src),
    ok = livery_s3:delete_object(C, B, Dst).

presign_response_override(Config) ->
    {C, B} = ctx(Config),
    K = uniq(<<"pso-">>),
    {ok, _} = livery_s3:put_object(C, B, K, <<"data">>),
    {ok, Url} = livery_s3:presign(C, get, B, K, 300, #{
        response_content_type => <<"application/xml">>
    }),
    {ok, 200, _, <<"data">>} = hackney:request(get, Url, [], <<>>, [{with_body, true}]),
    ok = livery_s3:delete_object(C, B, K).

%% A client composed with retry (default), circuit breaker, and a concurrency
%% cap still signs and round-trips correctly against a live endpoint.
resilience_stack(Config) ->
    Opts = ?config(opts, Config),
    B = ?config(bucket, Config),
    C = livery_s3:new(Opts#{circuit_breaker => true, concurrency => 20}),
    K = uniq(<<"resil-">>),
    {ok, _} = livery_s3:put_object(C, B, K, <<"resilient">>),
    {ok, #{body := <<"resilient">>}} = livery_s3:get_object(C, B, K),
    ok = livery_s3:delete_object(C, B, K).

%% Credentials sourced from environment variables (env provider) sign and
%% round-trip like static keys.
credential_env_provider(Config) ->
    Opts = ?config(opts, Config),
    B = ?config(bucket, Config),
    os:putenv("AWS_ACCESS_KEY_ID", binary_to_list(maps:get(access_key_id, Opts))),
    os:putenv("AWS_SECRET_ACCESS_KEY", binary_to_list(maps:get(secret_access_key, Opts))),
    try
        Base = maps:without([access_key_id, secret_access_key], Opts),
        C = livery_s3:new(Base#{credentials => env}),
        K = uniq(<<"env-">>),
        {ok, _} = livery_s3:put_object(C, B, K, <<"via-env">>),
        {ok, #{body := <<"via-env">>}} = livery_s3:get_object(C, B, K),
        ok = livery_s3:delete_object(C, B, K)
    after
        os:unsetenv("AWS_ACCESS_KEY_ID"),
        os:unsetenv("AWS_SECRET_ACCESS_KEY")
    end.

%%====================================================================
%% Anonymous access
%%====================================================================

%% A signed client writes into the public bucket; an anonymous client reads,
%% heads, and lists it with no credentials at all.
anonymous_public_read(Config) ->
    maybe
        ok ?= require(anonymous, Config),
        {C, _} = ctx(Config),
        Pub = env("LIVERY_S3_PUBLIC_BUCKET", <<"livery-s3-public">>),
        K = uniq(<<"anon-">>),
        {ok, _} = livery_s3:put_object(C, Pub, K, <<"open data">>),
        A = anon_client(Config),
        {ok, #{body := <<"open data">>}} = livery_s3:get_object(A, Pub, K),
        {ok, #{content_length := 9}} = livery_s3:head_object(A, Pub, K),
        {ok, #{objects := Objects}} = livery_s3:list_objects(A, Pub, #{prefix => K}),
        ?assertEqual([K], [maps:get(key, O) || O <- Objects]),
        ok = livery_s3:delete_object(C, Pub, K)
    end.

%% The private bucket rejects an anonymous write and an anonymous read. Every
%% store must refuse, so this runs everywhere.
anonymous_denied_on_private(Config) ->
    {C, B} = ctx(Config),
    K = uniq(<<"anon-priv-">>),
    {ok, _} = livery_s3:put_object(C, B, K, <<"secret">>),
    A = anon_client(Config),
    W = livery_s3:put_object(A, B, uniq(<<"anon-w-">>), <<"x">>),
    R = livery_s3:get_object(A, B, K),
    ct:pal("anonymous write -> ~p~nanonymous read -> ~p", [W, R]),
    ?assertMatch({error, {s3, _, _, #{status := 403}}}, W),
    ?assertMatch({error, {s3, _, _, #{status := 403}}}, R),
    ok = livery_s3:delete_object(C, B, K).

%%====================================================================
%% Integrity checksums
%%====================================================================

%% Each algorithm: the store accepts the computed value and returns the same
%% value on HEAD with checksum mode on.
checksum_roundtrip(Config) ->
    maybe
        ok ?= require(checksums, Config),
        {C, B} = ctx(Config),
        Data = <<"checksummed payload">>,
        lists:foreach(
            fun(Alg) ->
                K = uniq(<<"ck-", (atom_to_binary(Alg))/binary, "-">>),
                Expected = livery_s3_checksum:compute(Alg, Data),
                {ok, _} = livery_s3:put_object(C, B, K, Data, #{checksum => Alg}),
                {ok, Meta} = livery_s3:head_object(C, B, K, #{checksum_mode => true}),
                ct:pal("~p head checksum -> ~p", [Alg, maps:get(checksum, Meta, none)]),
                ?assertEqual(Expected, maps:get(Alg, maps:get(checksum, Meta))),
                ok = livery_s3:delete_object(C, B, K)
            end,
            [crc32, crc32c, sha1, sha256]
        )
    end.

%% A wrong checksum is refused and nothing is stored.
checksum_mismatch_rejected(Config) ->
    maybe
        ok ?= require(checksums, Config),
        {C, B} = ctx(Config),
        K = uniq(<<"ck-bad-">>),
        Wrong = livery_s3_checksum:compute(crc32, <<"something else">>),
        Result = livery_s3:put_object(C, B, K, <<"payload">>, #{checksum => {crc32, Wrong}}),
        ct:pal("mismatched checksum -> ~p", [Result]),
        ?assertMatch({error, {s3, _, _, #{status := 400}}}, Result),
        ?assertEqual({error, not_found}, livery_s3:head_object(C, B, K))
    end.

%% A multipart upload with per-part CRC32C completes and reads back.
checksum_multipart(Config) ->
    maybe
        ok ?= require(checksums, Config),
        {C, B} = ctx(Config),
        K = uniq(<<"ck-mpu-">>),
        P1 = binary:copy(<<"a">>, 5 * 1024 * 1024),
        P2 = <<"tail">>,
        {ok, U} = livery_s3:create_multipart_upload(C, B, K, #{checksum_algorithm => crc32c}),
        {ok, #{etag := E1} = R1} = livery_s3:upload_part(C, B, K, U, 1, P1, #{checksum => crc32c}),
        {ok, #{etag := E2} = R2} = livery_s3:upload_part(C, B, K, U, 2, P2, #{checksum => crc32c}),
        ?assertEqual(
            livery_s3_checksum:compute(crc32c, P1), maps:get(crc32c, maps:get(checksum, R1))
        ),
        Parts = [
            {1, E1, #{crc32c => livery_s3_checksum:compute(crc32c, P1)}},
            {2, E2, #{crc32c => livery_s3_checksum:compute(crc32c, P2)}}
        ],
        _ = R2,
        {ok, Done} = livery_s3:complete_multipart_upload(C, B, K, U, Parts),
        ct:pal("multipart completion -> ~p", [Done]),
        {ok, #{body := Body}} = livery_s3:get_object(C, B, K),
        ?assertEqual(<<P1/binary, P2/binary>>, Body),
        ok = livery_s3:delete_object(C, B, K)
    end.

%%====================================================================
%% Server-side encryption
%%====================================================================

-define(SSE_KEY, <<"0123456789abcdef0123456789abcdef">>).
-define(SSE_KEY2, <<"fedcba9876543210fedcba9876543210">>).

%% SSE-C: the object reads back only with the key it was written with.
sse_c_roundtrip(Config) ->
    maybe
        ok ?= require(sse_c, Config),
        {C, B} = ctx(Config),
        K = uniq(<<"ssec-">>),
        Opts = #{sse_customer_key => ?SSE_KEY},
        {ok, Put} = livery_s3:put_object(C, B, K, <<"sealed">>, Opts),
        ct:pal("SSE-C put -> ~p", [Put]),
        {ok, #{body := <<"sealed">>}} = livery_s3:get_object(C, B, K, Opts),
        {ok, Meta} = livery_s3:head_object(C, B, K, Opts),
        ?assertEqual(<<"AES256">>, maps:get(sse_customer_algorithm, Meta)),
        NoKey = livery_s3:get_object(C, B, K),
        WrongKey = livery_s3:get_object(C, B, K, #{sse_customer_key => ?SSE_KEY2}),
        ct:pal("SSE-C get without key -> ~p~nwith wrong key -> ~p", [NoKey, WrongKey]),
        ?assertMatch({error, {s3, _, _, _}}, NoKey),
        ?assertMatch({error, {s3, _, _, _}}, WrongKey),
        ok = livery_s3:delete_object(C, B, K)
    end.

%% A copy reads the SSE-C source with its key and re-encrypts with a new one.
sse_c_copy(Config) ->
    maybe
        ok ?= require(sse_c, Config),
        {C, B} = ctx(Config),
        Src = uniq(<<"ssec-src-">>),
        Dst = uniq(<<"ssec-dst-">>),
        {ok, _} = livery_s3:put_object(C, B, Src, <<"rekeyed">>, #{sse_customer_key => ?SSE_KEY}),
        {ok, _} = livery_s3:copy_object(C, B, Src, B, Dst, #{
            copy_source_sse_customer_key => ?SSE_KEY, sse_customer_key => ?SSE_KEY2
        }),
        {ok, #{body := <<"rekeyed">>}} =
            livery_s3:get_object(C, B, Dst, #{sse_customer_key => ?SSE_KEY2}),
        ok = livery_s3:delete_object(C, B, Src),
        ok = livery_s3:delete_object(C, B, Dst)
    end.

sse_s3_roundtrip(Config) ->
    maybe
        ok ?= require(sse_s3, Config),
        {C, B} = ctx(Config),
        K = uniq(<<"sses3-">>),
        {ok, Put} = livery_s3:put_object(C, B, K, <<"managed">>, #{sse => aes256}),
        ?assertEqual(<<"AES256">>, maps:get(sse, Put)),
        {ok, #{sse := <<"AES256">>}} = livery_s3:head_object(C, B, K),
        {ok, #{body := <<"managed">>}} = livery_s3:get_object(C, B, K),
        ok = livery_s3:delete_object(C, B, K)
    end.

sse_kms_roundtrip(Config) ->
    maybe
        ok ?= require(sse_kms, Config),
        {C, B} = ctx(Config),
        K = uniq(<<"ssekms-">>),
        {ok, Put} = livery_s3:put_object(C, B, K, <<"kms">>, #{sse => {kms, <<"livery-s3-key">>}}),
        ct:pal("SSE-KMS put -> ~p", [Put]),
        {ok, #{sse := <<"aws:kms">>}} = livery_s3:head_object(C, B, K),
        {ok, #{body := <<"kms">>}} = livery_s3:get_object(C, B, K),
        ok = livery_s3:delete_object(C, B, K)
    end.

%%====================================================================
%% Presigned POST (browser form uploads)
%%====================================================================

post_upload(Config) ->
    maybe
        ok ?= require(post_object, Config),
        {C, B} = ctx(Config),
        K = uniq(<<"post-">>),
        {ok, Form} = livery_s3:presign_post(C, B, K, 300, #{
            content_type => <<"text/plain">>,
            fields => #{<<"x-amz-meta-origin">> => <<"browser">>}
        }),
        {Status, _} = post_form(Form, <<"form body">>, <<"text/plain">>),
        ?assert(lists:member(Status, [200, 201, 204])),
        {ok, #{body := <<"form body">>, metadata := Meta}} = livery_s3:get_object(C, B, K),
        ?assertEqual(#{<<"origin">> => <<"browser">>}, Meta),
        ok = livery_s3:delete_object(C, B, K)
    end.

%% `${filename}` is filled in from the uploaded file's name.
post_upload_filename(Config) ->
    maybe
        ok ?= require(post_object, Config),
        {C, B} = ctx(Config),
        Prefix = uniq(<<"post-fn-">>),
        {ok, Form} = livery_s3:presign_post(C, B, <<Prefix/binary, "/${filename}">>, 300, #{}),
        {Status, _} = post_form(Form, <<"named">>, <<"application/octet-stream">>),
        ?assert(lists:member(Status, [200, 201, 204])),
        K = <<Prefix/binary, "/upload.txt">>,
        {ok, #{body := <<"named">>}} = livery_s3:get_object(C, B, K),
        ok = livery_s3:delete_object(C, B, K)
    end.

post_too_large_rejected(Config) ->
    maybe
        ok ?= require(post_object, Config),
        {C, B} = ctx(Config),
        K = uniq(<<"post-big-">>),
        {ok, Form} = livery_s3:presign_post(C, B, K, 300, #{content_length_range => {1, 10}}),
        {Status, Body} = post_form(Form, binary:copy(<<"x">>, 100), <<"text/plain">>),
        ct:pal("oversized POST -> ~p ~s", [Status, Body]),
        ?assert(Status >= 400),
        ?assertEqual({error, not_found}, livery_s3:head_object(C, B, K))
    end.

post_expired_rejected(Config) ->
    maybe
        ok ?= require(post_object, Config),
        {C, B} = ctx(Config),
        K = uniq(<<"post-exp-">>),
        {ok, Form} = livery_s3:presign_post(C, B, K, 1, #{}),
        timer:sleep(2500),
        {Status, Body} = post_form(Form, <<"late">>, <<"text/plain">>),
        ct:pal("expired POST -> ~p ~s", [Status, Body]),
        ?assert(Status >= 400),
        ?assertEqual({error, not_found}, livery_s3:head_object(C, B, K))
    end.

%% Send a presigned form the way a browser does: every field, then the file.
post_form(#{url := Url, fields := Fields}, Data, ContentType) ->
    Boundary = <<"livery-s3-boundary">>,
    Part = fun(Name, Value) ->
        [
            <<"--", Boundary/binary, "\r\n">>,
            <<"Content-Disposition: form-data; name=\"", Name/binary, "\"\r\n\r\n">>,
            Value,
            <<"\r\n">>
        ]
    end,
    Body = iolist_to_binary([
        [Part(N, V) || {N, V} <- maps:to_list(Fields)],
        <<"--", Boundary/binary, "\r\n">>,
        <<"Content-Disposition: form-data; name=\"file\"; filename=\"upload.txt\"\r\n">>,
        <<"Content-Type: ", ContentType/binary, "\r\n\r\n">>,
        Data,
        <<"\r\n--", Boundary/binary, "--\r\n">>
    ]),
    Headers = [{<<"content-type">>, <<"multipart/form-data; boundary=", Boundary/binary>>}],
    {ok, Status, _, RespBody} = hackney:request(post, Url, Headers, Body, [{with_body, true}]),
    {Status, RespBody}.

%%====================================================================
%% Object tagging
%%====================================================================

tagging_roundtrip(Config) ->
    maybe
        ok ?= require(tagging, Config),
        {C, B} = ctx(Config),
        K = uniq(<<"tag-">>),
        {ok, _} = livery_s3:put_object(C, B, K, <<"x">>),
        ?assertEqual({ok, #{}}, livery_s3:get_object_tagging(C, B, K)),
        Tags = #{<<"team">> => <<"a+b c">>, <<"env">> => <<"prod">>},
        ok = livery_s3:put_object_tagging(C, B, K, Tags),
        ?assertEqual({ok, Tags}, livery_s3:get_object_tagging(C, B, K)),
        ok = livery_s3:put_object_tagging(C, B, K, #{<<"only">> => <<"one">>}),
        ?assertEqual({ok, #{<<"only">> => <<"one">>}}, livery_s3:get_object_tagging(C, B, K)),
        ok = livery_s3:delete_object_tagging(C, B, K),
        ?assertEqual({ok, #{}}, livery_s3:get_object_tagging(C, B, K)),
        ok = livery_s3:delete_object(C, B, K)
    end.

%% Tags set at write time, kept by a plain copy and replaced by a tagged one.
tagging_on_write(Config) ->
    maybe
        ok ?= require(tagging, Config),
        {C, B} = ctx(Config),
        K = uniq(<<"tag-w-">>),
        Kept = uniq(<<"tag-kept-">>),
        Replaced = uniq(<<"tag-repl-">>),
        Tags = #{<<"a b">> => <<"1=2/3+4">>},
        {ok, _} = livery_s3:put_object(C, B, K, <<"x">>, #{tagging => Tags}),
        ?assertEqual({ok, Tags}, livery_s3:get_object_tagging(C, B, K)),
        {ok, _} = livery_s3:copy_object(C, B, K, B, Kept),
        ?assertEqual({ok, Tags}, livery_s3:get_object_tagging(C, B, Kept)),
        {ok, _} = livery_s3:copy_object(C, B, K, B, Replaced, #{tagging => #{<<"n">> => <<"v">>}}),
        ?assertEqual({ok, #{<<"n">> => <<"v">>}}, livery_s3:get_object_tagging(C, B, Replaced)),
        [ok = livery_s3:delete_object(C, B, X) || X <- [K, Kept, Replaced]],
        ok
    end.

%%====================================================================
%% encoding-type=url listings
%%====================================================================

%% Keys with a newline, a space, a plus, and non-ASCII come back intact.
list_encoding_url(Config) ->
    maybe
        ok ?= require(encoding_url, Config),
        {C, B} = ctx(Config),
        Prefix = <<(uniq(<<"enc-">>))/binary, "/">>,
        Names = [<<"line\nbreak">>, <<"sp ace+plus">>, <<"caf", 16#C3, 16#A9>>],
        Keys = lists:sort([<<Prefix/binary, N/binary>> || N <- Names]),
        [{ok, _} = livery_s3:put_object(C, B, K, <<"v">>) || K <- Keys],
        {ok, #{objects := Objects}} =
            livery_s3:list_objects(C, B, #{prefix => Prefix, encoding_type => url}),
        ?assertEqual(Keys, lists:sort([maps:get(key, O) || O <- Objects])),
        {ok, #{common_prefixes := Prefixes}} = livery_s3:list_objects(C, B, #{
            prefix => Prefix, delimiter => <<" ">>, encoding_type => url
        }),
        ?assertEqual([<<Prefix/binary, "sp ">>], Prefixes),
        [ok = livery_s3:delete_object(C, B, K) || K <- Keys],
        ok
    end.

%% Requester pays is AWS-only: other stores must still accept the signed
%% header, including on a presigned URL.
request_payer_ignored(Config) ->
    Opts = ?config(opts, Config),
    B = ?config(bucket, Config),
    C = livery_s3:new(Opts#{request_payer => requester}),
    K = uniq(<<"payer-">>),
    {ok, _} = livery_s3:put_object(C, B, K, <<"paid">>),
    {ok, #{body := <<"paid">>}} = livery_s3:get_object(C, B, K),
    {ok, Url} = livery_s3:presign(C, get, B, K, 300),
    {ok, 200, _, <<"paid">>} = hackney:request(get, Url, [], <<>>, [{with_body, true}]),
    ok = livery_s3:delete_object(C, B, K).

anon_client(Config) ->
    Opts = ?config(opts, Config),
    livery_s3:new((maps:without([access_key_id, secret_access_key], Opts))#{
        credentials => anonymous
    }).

%%====================================================================
%% Helpers
%%====================================================================

ctx(Config) ->
    {?config(client, Config), ?config(bucket, Config)}.

%% Which store the suite runs against; selects the capability table below.
backend() ->
    case os:getenv("LIVERY_S3_BACKEND") of
        "minio" -> minio;
        _ -> garage
    end.

%% Features each store implements. Every entry was checked against the real
%% server; a testcase for a missing capability skips instead of passing silently.
%%
%% Garage: no anonymous S3 API access (public reads go through its website
%% endpoint), it accepts SSE-S3/SSE-KMS headers without encrypting, and object
%% tagging is NotImplemented.
%% MinIO: refuses SSE-C over plain HTTP, and the test container has no TLS.
capabilities(garage) ->
    [checksums, sse_c, post_object, encoding_url];
capabilities(minio) ->
    [anonymous, checksums, sse_s3, sse_kms, post_object, tagging, encoding_url].

%% Skip the calling testcase when the backend lacks `Cap`.
require(Cap, Config) ->
    Backend = ?config(backend, Config),
    case lists:member(Cap, capabilities(Backend)) of
        true -> ok;
        false -> {skip, {Backend, lacks, Cap}}
    end.

env(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        Value -> list_to_binary(Value)
    end.

uniq(Prefix) ->
    N = erlang:unique_integer([positive]),
    <<Prefix/binary, (integer_to_binary(N))/binary>>.

wait_ready(_Client, 0) ->
    error;
wait_ready(Client, N) ->
    Result =
        try
            livery_s3:list_buckets(Client)
        catch
            _:_ -> retry
        end,
    case Result of
        {ok, _} ->
            ok;
        _ ->
            timer:sleep(1000),
            wait_ready(Client, N - 1)
    end.
