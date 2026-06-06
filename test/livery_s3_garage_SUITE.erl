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
    multipart_listing/1,
    upload_part_copy/1,
    presign_response_override/1
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
        multipart_listing,
        upload_part_copy,
        presign_response_override
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(hackney),
    Endpoint = env("LIVERY_S3_ENDPOINT", <<"http://127.0.0.1:3900">>),
    Client = livery_s3:new(#{
        endpoint => Endpoint,
        region => env("LIVERY_S3_REGION", <<"garage">>),
        access_key_id => env("LIVERY_S3_ACCESS_KEY", <<"GKtestaccesskey1234567890">>),
        secret_access_key =>
            env("LIVERY_S3_SECRET_KEY", <<"testsecretkey00000000000000000000000000000000000">>)
    }),
    case wait_ready(Client, 30) of
        ok -> [{client, Client}, {bucket, env("LIVERY_S3_BUCKET", <<"livery-s3-test">>)} | Config];
        error -> {skip, "garage not reachable at " ++ binary_to_list(Endpoint)}
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

%%====================================================================
%% Helpers
%%====================================================================

ctx(Config) ->
    {?config(client, Config), ?config(bucket, Config)}.

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
