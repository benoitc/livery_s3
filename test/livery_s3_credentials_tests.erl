-module(livery_s3_credentials_tests).

-include_lib("eunit/include/eunit.hrl").

%% Exported for the {Module, Function, Args} provider test.
-export([mfa_creds/1]).

mfa_creds(AccessKey) ->
    {ok, #{
        access_key_id => AccessKey,
        secret_access_key => <<"MS">>,
        expires_at => erlang:system_time(second) + 3600
    }}.

%%====================================================================
%% Static / env / file
%%====================================================================

static_test() ->
    {ok, H} = livery_s3_credentials:prepare({static, <<"AK">>, <<"SK">>, undefined}),
    ?assertEqual({ok, #{access_key_id => <<"AK">>, secret_access_key => <<"SK">>}}, current(H)).

static_with_token_test() ->
    {ok, H} = livery_s3_credentials:prepare({static, <<"AK">>, <<"SK">>, <<"TOK">>}),
    ?assertEqual(
        {ok, #{
            access_key_id => <<"AK">>, secret_access_key => <<"SK">>, session_token => <<"TOK">>
        }},
        current(H)
    ).

env_test() ->
    with_env(
        [
            {"AWS_ACCESS_KEY_ID", "EK"},
            {"AWS_SECRET_ACCESS_KEY", "ES"},
            {"AWS_SESSION_TOKEN", "ET"}
        ],
        fun() ->
            {ok, H} = livery_s3_credentials:prepare(env),
            ?assertEqual(
                {ok, #{
                    access_key_id => <<"EK">>,
                    secret_access_key => <<"ES">>,
                    session_token => <<"ET">>
                }},
                current(H)
            )
        end
    ).

env_missing_test() ->
    with_env([{"AWS_ACCESS_KEY_ID", false}, {"AWS_SECRET_ACCESS_KEY", false}], fun() ->
        ?assertEqual({error, no_env_credentials}, livery_s3_credentials:prepare(env))
    end).

file_test() ->
    Ini =
        <<
            "[default]\n"
            "aws_access_key_id = FK\n"
            "aws_secret_access_key = FS\n"
            "\n"
            "[work]\n"
            "aws_access_key_id = WK\n"
            "aws_secret_access_key = WS\n"
            "aws_session_token = WT\n"
        >>,
    with_file(Ini, fun(Path) ->
        with_env([{"AWS_SHARED_CREDENTIALS_FILE", binary_to_list(Path)}], fun() ->
            {ok, D} = livery_s3_credentials:prepare({file, <<"default">>}),
            ?assertEqual(
                {ok, #{access_key_id => <<"FK">>, secret_access_key => <<"FS">>}}, current(D)
            ),
            {ok, W} = livery_s3_credentials:prepare({file, <<"work">>}),
            ?assertEqual(
                {ok, #{
                    access_key_id => <<"WK">>,
                    secret_access_key => <<"WS">>,
                    session_token => <<"WT">>
                }},
                current(W)
            )
        end)
    end).

default_chain_env_test() ->
    with_env(
        [
            {"AWS_ACCESS_KEY_ID", "DK"},
            {"AWS_SECRET_ACCESS_KEY", "DS"},
            {"AWS_SESSION_TOKEN", false}
        ],
        fun() ->
            {ok, H} = livery_s3_credentials:prepare(default),
            ?assertEqual(
                {ok, #{access_key_id => <<"DK">>, secret_access_key => <<"DS">>}}, current(H)
            )
        end
    ).

invalid_provider_test() ->
    ?assertMatch({error, {invalid_credentials_provider, _}}, livery_s3_credentials:prepare(bogus)).

%%====================================================================
%% IMDS and web-identity (fetch via a fake transport)
%%====================================================================

imds_fetch_test() ->
    Ref = atomics:new(1, [{signed, false}]),
    Json =
        <<
            "{\"AccessKeyId\":\"IK\",\"SecretAccessKey\":\"IS\","
            "\"Token\":\"IT\",\"Expiration\":\"2099-01-01T00:00:00Z\"}"
        >>,
    Opts = #{
        base_url => <<"http://imds">>,
        adapter => livery_s3_fake_adapter,
        adapter_opts => #{
            counter => Ref,
            responses => [
                resp(200, <<"TOKEN">>),
                resp(200, <<"myrole">>),
                resp(200, Json)
            ]
        }
    },
    {ok, Creds} = livery_s3_credentials:fetch({imds, Opts}),
    ?assertEqual(<<"IK">>, maps:get(access_key_id, Creds)),
    ?assertEqual(<<"IS">>, maps:get(secret_access_key, Creds)),
    ?assertEqual(<<"IT">>, maps:get(session_token, Creds)),
    ?assert(maps:get(expires_at, Creds) > 0).

web_identity_fetch_test() ->
    Xml =
        <<
            "<AssumeRoleWithWebIdentityResponse><AssumeRoleWithWebIdentityResult>"
            "<Credentials><AccessKeyId>XK</AccessKeyId><SecretAccessKey>XS</SecretAccessKey>"
            "<SessionToken>XT</SessionToken><Expiration>2099-01-01T00:00:00Z</Expiration>"
            "</Credentials></AssumeRoleWithWebIdentityResult></AssumeRoleWithWebIdentityResponse>"
        >>,
    with_file(<<"the-token">>, fun(TokenFile) ->
        Opts = #{
            token_file => TokenFile,
            role_arn => <<"arn:aws:iam::1:role/r">>,
            base_url => <<"http://sts">>,
            adapter => livery_s3_fake_adapter,
            adapter_opts => #{response => resp(200, Xml)}
        },
        {ok, Creds} = livery_s3_credentials:fetch({web_identity, Opts}),
        ?assertEqual(<<"XK">>, maps:get(access_key_id, Creds)),
        ?assertEqual(<<"XT">>, maps:get(session_token, Creds)),
        ?assert(maps:get(expires_at, Creds) > 0)
    end).

web_identity_missing_token_test() ->
    with_env([{"AWS_WEB_IDENTITY_TOKEN_FILE", false}], fun() ->
        ?assertEqual(
            {error, no_web_identity_token},
            livery_s3_credentials:fetch({web_identity, #{role_arn => <<"arn">>}})
        )
    end).

web_identity_missing_role_test() ->
    with_env([{"AWS_ROLE_ARN", false}], fun() ->
        with_file(<<"tok">>, fun(File) ->
            ?assertEqual(
                {error, no_role_arn},
                livery_s3_credentials:fetch({web_identity, #{token_file => File}})
            )
        end)
    end).

web_identity_malformed_test() ->
    with_file(<<"tok">>, fun(File) ->
        Opts = #{
            token_file => File,
            role_arn => <<"arn">>,
            base_url => <<"http://sts">>,
            adapter => livery_s3_fake_adapter,
            adapter_opts => #{response => resp(200, <<"<Other/>">>)}
        },
        ?assertEqual({error, sts_malformed}, livery_s3_credentials:fetch({web_identity, Opts}))
    end).

imds_token_error_test() ->
    Opts = #{
        base_url => <<"http://imds">>,
        adapter => livery_s3_fake_adapter,
        adapter_opts => #{response => resp(500, <<>>)}
    },
    ?assertMatch({error, {imds_token, _}}, livery_s3_credentials:fetch({imds, Opts})).

imds_malformed_test() ->
    Ref = atomics:new(1, [{signed, false}]),
    Opts = #{
        base_url => <<"http://imds">>,
        adapter => livery_s3_fake_adapter,
        adapter_opts => #{
            counter => Ref,
            responses => [resp(200, <<"TOKEN">>), resp(200, <<"role">>), resp(200, <<"not json">>)]
        }
    },
    ?assertEqual({error, imds_malformed}, livery_s3_credentials:fetch({imds, Opts})).

imds_role_error_test() ->
    Ref = atomics:new(1, [{signed, false}]),
    Opts = #{
        base_url => <<"http://imds">>,
        adapter => livery_s3_fake_adapter,
        adapter_opts => #{
            counter => Ref, responses => [resp(200, <<"TOKEN">>), resp(403, <<>>)]
        }
    },
    ?assertMatch({error, {imds, _}}, livery_s3_credentials:fetch({imds, Opts})).

web_identity_http_error_test() ->
    with_file(<<"tok">>, fun(File) ->
        Opts = #{
            token_file => File,
            role_arn => <<"arn">>,
            base_url => <<"http://sts">>,
            adapter => livery_s3_fake_adapter,
            adapter_opts => #{response => resp(403, <<"denied">>)}
        },
        ?assertMatch(
            {error, {web_identity, 403, _}}, livery_s3_credentials:fetch({web_identity, Opts})
        )
    end).

default_file_fallthrough_test() ->
    Ini = <<"[default]\naws_access_key_id = LK\naws_secret_access_key = LS\n">>,
    with_file(Ini, fun(Path) ->
        with_env(
            [
                {"AWS_ACCESS_KEY_ID", false},
                {"AWS_SECRET_ACCESS_KEY", false},
                {"AWS_ROLE_ARN", false},
                {"AWS_SHARED_CREDENTIALS_FILE", binary_to_list(Path)}
            ],
            fun() ->
                {ok, H} = livery_s3_credentials:prepare(default),
                ?assertEqual(
                    {ok, #{access_key_id => <<"LK">>, secret_access_key => <<"LS">>}}, current(H)
                )
            end
        )
    end).

mfa_provider_test() ->
    {ok, H} = livery_s3_credentials:prepare(
        {?MODULE, mfa_creds, [<<"MK">>]}
    ),
    {ok, _} = application:ensure_all_started(livery_s3),
    ?assertMatch({ok, #{access_key_id := <<"MK">>}}, current(H)).

store_message_handling_test() ->
    {ok, _} = application:ensure_all_started(livery_s3),
    ?assertEqual({error, unknown_request}, gen_server:call(livery_s3_credentials_store, bogus)),
    ok = gen_server:cast(livery_s3_credentials_store, ignored),
    livery_s3_credentials_store ! ignored,
    ?assert(is_pid(whereis(livery_s3_credentials_store))).

app_stop_test() ->
    ?assertEqual(ok, livery_s3_app:stop(state)).

%%====================================================================
%% Refresh cache (needs the livery_s3 application)
%%====================================================================

cache_fresh_not_refetched_test() ->
    {ok, _} = application:ensure_all_started(livery_s3),
    Ref = atomics:new(1, [{signed, false}]),
    Fun = fun() ->
        atomics:add(Ref, 1, 1),
        {ok, #{
            access_key_id => <<"CK">>,
            secret_access_key => <<"CS">>,
            expires_at => far_future()
        }}
    end,
    {ok, H} = livery_s3_credentials:prepare(Fun),
    {ok, _} = current(H),
    {ok, _} = current(H),
    ?assertEqual(1, atomics:get(Ref, 1)).

cache_stale_refetched_test() ->
    {ok, _} = application:ensure_all_started(livery_s3),
    Ref = atomics:new(1, [{signed, false}]),
    Fun = fun() ->
        atomics:add(Ref, 1, 1),
        {ok, #{
            access_key_id => <<"CK">>,
            secret_access_key => <<"CS">>,
            %% Already within the refresh margin, so every read re-fetches.
            expires_at => erlang:system_time(second)
        }}
    end,
    {ok, H} = livery_s3_credentials:prepare(Fun),
    {ok, _} = current(H),
    {ok, _} = current(H),
    ?assertEqual(2, atomics:get(Ref, 1)).

%%====================================================================
%% Helpers
%%====================================================================

current(H) -> livery_s3_credentials:current(H).

far_future() -> erlang:system_time(second) + 3600.

resp(Status, Body) -> #{status => Status, headers => [], body => {full, Body}}.

with_env(Vars, Fun) ->
    Saved = [{K, os:getenv(K)} || {K, _} <- Vars],
    lists:foreach(fun set_env/1, Vars),
    try
        Fun()
    after
        lists:foreach(fun set_env/1, Saved)
    end.

set_env({K, false}) -> os:unsetenv(K);
set_env({K, V}) -> os:putenv(K, V).

with_file(Content, Fun) ->
    Path = iolist_to_binary([
        "/tmp/livery_s3_cred_", integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = file:write_file(Path, Content),
    try
        Fun(Path)
    after
        file:delete(Path)
    end.
