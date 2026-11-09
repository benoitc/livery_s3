-module(livery_s3_post_tests).

-include_lib("eunit/include/eunit.hrl").
-include("livery_s3.hrl").

-import(livery_s3_test_util, [client/2, resp/3]).

%% AWS's published SigV4 browser-upload (POST) example.
-define(AWS_SECRET, <<"wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY">>).
-define(AWS_POLICY, <<
    "eyAiZXhwaXJhdGlvbiI6ICIyMDE1LTEyLTMwVDEyOjAwOjAwLjAwMFoiLA0KICAiY29uZGl0aW9ucyI6IFsNCiAgICB7"
    "ImJ1Y2tldCI6ICJzaWd2NGV4YW1wbGVidWNrZXQifSwNCiAgICBbInN0YXJ0cy13aXRoIiwgIiRrZXkiLCAidXNlci91"
    "c2VyMS8iXSwNCiAgICB7ImFjbCI6ICJwdWJsaWMtcmVhZCJ9LA0KICAgIHsic3VjY2Vzc19hY3Rpb25fcmVkaXJlY3Qi"
    "OiAiaHR0cDovL3NpZ3Y0ZXhhbXBsZWJ1Y2tldC5zMy5hbWF6b25hd3MuY29tL3N1Y2Nlc3NmdWxfdXBsb2FkLmh0bWwi"
    "fSwNCiAgICBbInN0YXJ0cy13aXRoIiwgIiRDb250ZW50LVR5cGUiLCAiaW1hZ2UvIl0sDQogICAgeyJ4LWFtei1tZXRh"
    "LXV1aWQiOiAiMTQzNjUxMjM2NTEyNzQifSwNCiAgICB7IngtYW16LXNlcnZlci1zaWRlLWVuY3J5cHRpb24iOiAiQUVT"
    "MjU2In0sDQogICAgWyJzdGFydHMtd2l0aCIsICIkeC1hbXotbWV0YS10YWciLCAiIl0sDQoNCiAgICB7IngtYW16LWNy"
    "ZWRlbnRpYWwiOiAiQUtJQUlPU0ZPRE5ON0VYQU1QTEUvMjAxNTEyMjkvdXMtZWFzdC0xL3MzL2F3czRfcmVxdWVzdCJ9"
    "LA0KICAgIHsieC1hbXotYWxnb3JpdGhtIjogIkFXUzQtSE1BQy1TSEEyNTYifSwNCiAgICB7IngtYW16LWRhdGUiOiAi"
    "MjAxNTEyMjlUMDAwMDAwWiIgfQ0KICBdDQp9"
>>).
-define(AWS_SIGNATURE, <<"8afdbf4008c03f22c2cd3cdb72e4afbb1f6a588f3255ac628749a66d7f09699e">>).

-define(NOW, {<<"20151229T000000Z">>, <<"20151229">>}).

aws_post_example_signature_test() ->
    ?assertEqual(
        ?AWS_SIGNATURE,
        livery_s3_sigv4:post_signature(?AWS_SECRET, <<"20151229">>, <<"us-east-1">>, ?AWS_POLICY)
    ).

policy_conditions_test() ->
    #{url := Url, fields := F} = post(<<"user/${filename}">>, 3600, #{
        content_length_range => {1, 1024},
        content_type => <<"image/png">>,
        fields => #{<<"success_action_status">> => <<"201">>}
    }),
    ?assertEqual(<<"https://s3.example.com/photos">>, Url),
    Policy = json:decode(base64:decode(maps:get(<<"policy">>, F))),
    ?assertEqual(<<"2015-12-29T01:00:00.000Z">>, maps:get(<<"expiration">>, Policy)),
    Conds = maps:get(<<"conditions">>, Policy),
    Expected = [
        #{<<"bucket">> => <<"photos">>},
        [<<"starts-with">>, <<"$key">>, <<"user/">>],
        #{<<"success_action_status">> => <<"201">>},
        #{<<"Content-Type">> => <<"image/png">>},
        #{<<"x-amz-algorithm">> => <<"AWS4-HMAC-SHA256">>},
        #{<<"x-amz-credential">> => <<"AKIDEXAMPLE/20151229/us-east-1/s3/aws4_request">>},
        #{<<"x-amz-date">> => <<"20151229T000000Z">>},
        [<<"content-length-range">>, 1, 1024]
    ],
    ?assertEqual(lists:sort(Expected), lists:sort(Conds)).

%% Every non-policy field the form sends is signed by an exact condition, so the
%% browser cannot change it.
fields_are_all_signed_test() ->
    #{fields := F} = post(<<"exact.txt">>, 60, #{fields => #{<<"acl">> => <<"private">>}}),
    Conds = maps:get(<<"conditions">>, json:decode(base64:decode(maps:get(<<"policy">>, F)))),
    Signed = maps:without([<<"policy">>, <<"x-amz-signature">>], F),
    [?assert(lists:member(#{N => V}, Conds)) || {N, V} <- maps:to_list(Signed)],
    ?assertEqual(<<"exact.txt">>, maps:get(<<"key">>, F)).

signature_matches_policy_test() ->
    #{fields := F} = post(<<"k">>, 60, #{}),
    ?assertEqual(
        livery_s3_sigv4:post_signature(
            <<"SECRET">>, <<"20151229">>, <<"us-east-1">>, maps:get(<<"policy">>, F)
        ),
        maps:get(<<"x-amz-signature">>, F)
    ).

session_token_field_test() ->
    Cfg = cfg(path),
    Creds = #{access_key_id => <<"AK">>, secret_access_key => <<"S">>, session_token => <<"T">>},
    #{fields := F} = livery_s3_sigv4:presigned_post(Cfg, Creds, <<"b">>, <<"k">>, 60, #{}, ?NOW),
    ?assertEqual(<<"T">>, maps:get(<<"x-amz-security-token">>, F)).

key_starts_with_and_type_prefix_test() ->
    #{fields := F} = post(<<"any">>, 60, #{
        key_starts_with => <<"in/">>, content_type_starts_with => <<"image/">>
    }),
    Conds = maps:get(<<"conditions">>, json:decode(base64:decode(maps:get(<<"policy">>, F)))),
    ?assert(lists:member([<<"starts-with">>, <<"$key">>, <<"in/">>], Conds)),
    ?assert(lists:member([<<"starts-with">>, <<"$Content-Type">>, <<"image/">>], Conds)).

virtual_hosted_url_test() ->
    Creds = #{access_key_id => <<"AK">>, secret_access_key => <<"S">>},
    #{url := Url} = livery_s3_sigv4:presigned_post(
        cfg(virtual), Creds, <<"photos">>, <<"k">>, 60, #{}, ?NOW
    ),
    ?assertEqual(<<"https://photos.s3.example.com/">>, Url).

expiration_rolls_over_test() ->
    #{fields := F} = livery_s3_sigv4:presigned_post(
        cfg(path),
        #{access_key_id => <<"AK">>, secret_access_key => <<"S">>},
        <<"b">>,
        <<"k">>,
        86400 * 3,
        #{},
        {<<"20151230T235959Z">>, <<"20151230">>}
    ),
    Policy = json:decode(base64:decode(maps:get(<<"policy">>, F))),
    ?assertEqual(<<"2016-01-02T23:59:59.000Z">>, maps:get(<<"expiration">>, Policy)).

facade_presign_post_test() ->
    C = client(resp(200, [], <<>>), #{}),
    {ok, #{url := <<"https://s3.example.com/b">>, fields := F}} =
        livery_s3:presign_post(C, <<"b">>, <<"k">>, 60, #{}),
    ?assert(maps:is_key(<<"x-amz-signature">>, F)).

anonymous_presign_post_errors_test() ->
    C = client(resp(200, [], <<>>), #{credentials => anonymous}),
    ?assertEqual(
        {error, {credentials, anonymous}},
        livery_s3:presign_post(C, <<"b">>, <<"k">>, 60, #{})
    ).

%%====================================================================
%% Helpers
%%====================================================================

post(Key, Expires, Opts) ->
    Creds = #{access_key_id => <<"AKIDEXAMPLE">>, secret_access_key => <<"SECRET">>},
    livery_s3_sigv4:presigned_post(cfg(path), Creds, <<"photos">>, Key, Expires, Opts, ?NOW).

cfg(Addressing) ->
    #s3_config{
        scheme = <<"https">>,
        host = <<"s3.example.com">>,
        port = undefined,
        region = <<"us-east-1">>,
        credentials = undefined,
        addressing = Addressing
    }.
