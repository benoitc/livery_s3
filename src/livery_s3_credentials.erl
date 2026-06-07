%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(livery_s3_credentials).
-moduledoc """
AWS credential providers for the S3 client.

A provider says where credentials come from; `prepare/1` turns it into a
`handle()` stored on the client. One-shot sources (static, environment, shared
config file) are resolved immediately into a `{fixed, _}` handle. Refreshing
sources (EC2/ECS instance metadata, web-identity/STS, custom funs) become a
`{dynamic, _, _}` handle whose credentials are fetched lazily and cached by
`livery_s3_credentials_store`, which refreshes them before `expires_at`.

The credentials themselves (key, secret, optional session token) feed SigV4 and
work against any S3-compatible store; the providers are environment-specific
(env/file/static everywhere, IMDS on AWS, web-identity on AWS or MinIO STS).
""".

-export([prepare/1, current/1, fetch/1]).
-export_type([provider/0, creds/0, handle/0]).

-type creds() :: #{
    access_key_id := binary(),
    secret_access_key := binary(),
    session_token => binary(),
    expires_at => integer()
}.
-type provider() ::
    {static, binary(), binary(), binary() | undefined}
    | env
    | {file, binary()}
    | imds
    | {imds, map()}
    | {web_identity, map()}
    | default
    | fun(() -> {ok, creds()} | {error, term()})
    | {module(), atom(), [term()]}.
-opaque handle() :: {fixed, creds()} | {dynamic, term(), provider()}.

%%====================================================================
%% Handle lifecycle
%%====================================================================

-doc """
Turn a provider into a handle. One-shot providers resolve now (and may fail);
refreshing providers return a lazy handle that fetches on first use.
""".
-spec prepare(provider()) -> {ok, handle()} | {error, term()}.
prepare({static, AccessKey, Secret, Token}) ->
    {ok, {fixed, creds(AccessKey, Secret, Token)}};
prepare(env) ->
    case resolve_env() of
        {ok, Creds} -> {ok, {fixed, Creds}};
        {error, _} = E -> E
    end;
prepare({file, Profile}) ->
    case resolve_file(Profile) of
        {ok, Creds} -> {ok, {fixed, Creds}};
        {error, _} = E -> E
    end;
prepare(imds) ->
    prepare({imds, #{}});
prepare({imds, _Opts} = Provider) ->
    {ok, {dynamic, imds, Provider}};
prepare({web_identity, Opts} = Provider) ->
    {ok, {dynamic, {web_identity, maps:get(role_arn, Opts, env_role_arn())}, Provider}};
prepare(default) ->
    resolve_default();
prepare(Fun) when is_function(Fun, 0) ->
    {ok, {dynamic, Fun, Fun}};
prepare({Mod, Fun, Args} = Provider) when is_atom(Mod), is_atom(Fun), is_list(Args) ->
    {ok, {dynamic, Provider, Provider}};
prepare(Other) ->
    {error, {invalid_credentials_provider, Other}}.

-doc "Return the current credentials for a handle, refreshing if needed.".
-spec current(handle()) -> {ok, creds()} | {error, term()}.
current({fixed, Creds}) ->
    {ok, Creds};
current({dynamic, Key, Provider}) ->
    livery_s3_credentials_store:current(Key, Provider).

-doc """
Fetch fresh credentials for a refreshing provider (used by the cache). One-shot
providers (static/env/file) resolve at `prepare/1` and never reach here.
""".
-spec fetch(provider()) -> {ok, creds()} | {error, term()}.
fetch({imds, Opts}) -> fetch_imds(Opts);
fetch({web_identity, Opts}) -> fetch_web_identity(Opts);
fetch(Fun) when is_function(Fun, 0) -> Fun();
fetch({Mod, Fun, Args}) -> apply(Mod, Fun, Args).

%%====================================================================
%% Default chain: env -> web-identity -> file -> imds
%%====================================================================

-spec resolve_default() -> {ok, handle()} | {error, term()}.
resolve_default() ->
    case resolve_env() of
        {ok, Creds} ->
            {ok, {fixed, Creds}};
        {error, _} ->
            case env_role_arn() of
                undefined -> resolve_default_file();
                _ -> prepare({web_identity, #{}})
            end
    end.

resolve_default_file() ->
    case resolve_file(default_profile()) of
        {ok, Creds} -> {ok, {fixed, Creds}};
        {error, _} -> prepare(imds)
    end.

%%====================================================================
%% Environment and shared config file
%%====================================================================

-spec resolve_env() -> {ok, creds()} | {error, term()}.
resolve_env() ->
    case {getenv("AWS_ACCESS_KEY_ID"), getenv("AWS_SECRET_ACCESS_KEY")} of
        {undefined, _} -> {error, no_env_credentials};
        {_, undefined} -> {error, no_env_credentials};
        {AccessKey, Secret} -> {ok, creds(AccessKey, Secret, getenv("AWS_SESSION_TOKEN"))}
    end.

-spec resolve_file(binary()) -> {ok, creds()} | {error, term()}.
resolve_file(Profile) ->
    Path = shared_credentials_path(),
    case file:read_file(Path) of
        {ok, Bin} -> profile_creds(parse_ini(Bin), Profile);
        {error, Reason} -> {error, {credentials_file, Reason}}
    end.

-spec profile_creds(#{binary() => #{binary() => binary()}}, binary()) ->
    {ok, creds()} | {error, term()}.
profile_creds(Ini, Profile) ->
    case maps:get(Profile, Ini, undefined) of
        undefined ->
            {error, {no_such_profile, Profile}};
        Section ->
            case
                {
                    maps:get(<<"aws_access_key_id">>, Section, undefined),
                    maps:get(<<"aws_secret_access_key">>, Section, undefined)
                }
            of
                {undefined, _} ->
                    {error, {incomplete_profile, Profile}};
                {_, undefined} ->
                    {error, {incomplete_profile, Profile}};
                {AccessKey, Secret} ->
                    {ok,
                        creds(
                            AccessKey, Secret, maps:get(<<"aws_session_token">>, Section, undefined)
                        )}
            end
    end.

%% Minimal INI: [section] headers and key = value lines; comments (# or ;) and
%% blanks ignored.
-spec parse_ini(binary()) -> #{binary() => #{binary() => binary()}}.
parse_ini(Bin) ->
    Lines = binary:split(Bin, [<<"\n">>, <<"\r\n">>], [global]),
    {_, Sections} = lists:foldl(fun ini_line/2, {<<"default">>, #{}}, Lines),
    Sections.

ini_line(Raw, {Current, Sections}) ->
    Line = string:trim(Raw),
    case Line of
        <<>> ->
            {Current, Sections};
        <<"#", _/binary>> ->
            {Current, Sections};
        <<";", _/binary>> ->
            {Current, Sections};
        <<"[", Rest/binary>> ->
            [Name | _] = binary:split(Rest, <<"]">>),
            {string:trim(Name), Sections};
        _ ->
            case binary:split(Line, <<"=">>) of
                [K, V] ->
                    Section = maps:get(Current, Sections, #{}),
                    Entry = Section#{string:trim(K) => string:trim(V)},
                    {Current, Sections#{Current => Entry}};
                _ ->
                    {Current, Sections}
            end
    end.

%%====================================================================
%% IMDSv2 (EC2/ECS instance metadata)
%%====================================================================

-spec fetch_imds(map()) -> {ok, creds()} | {error, term()}.
fetch_imds(Opts) ->
    Client = metadata_client(Opts, <<"http://169.254.169.254">>),
    case imds_token(Client) of
        {ok, Token} ->
            Auth = [{<<"x-aws-ec2-metadata-token">>, Token}],
            case imds_get(Client, <<"/latest/meta-data/iam/security-credentials/">>, Auth) of
                {ok, Role} ->
                    Path = <<"/latest/meta-data/iam/security-credentials/", Role/binary>>,
                    case imds_get(Client, Path, Auth) of
                        {ok, Json} -> imds_creds(Json);
                        {error, _} = E -> E
                    end;
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

imds_token(Client) ->
    Headers = [{<<"x-aws-ec2-metadata-token-ttl-seconds">>, <<"21600">>}],
    case livery_client:request(Client, put, <<"/latest/api/token">>, #{headers => Headers}) of
        {ok, #{status := 200} = Resp} -> {ok, body(Resp)};
        {ok, #{status := S}} -> {error, {imds_token, S}};
        {error, Reason} -> {error, {imds_token, Reason}}
    end.

imds_get(Client, Path, Headers) ->
    case livery_client:request(Client, get, Path, #{headers => Headers}) of
        {ok, #{status := 200} = Resp} -> {ok, body(Resp)};
        {ok, #{status := S}} -> {error, {imds, S}};
        {error, Reason} -> {error, {imds, Reason}}
    end.

-spec imds_creds(binary()) -> {ok, creds()} | {error, term()}.
imds_creds(Json) ->
    try json:decode(Json) of
        #{
            <<"AccessKeyId">> := AccessKey,
            <<"SecretAccessKey">> := Secret,
            <<"Token">> := Token
        } = Map ->
            {ok,
                with_expiry(
                    creds(AccessKey, Secret, Token), maps:get(<<"Expiration">>, Map, undefined)
                )};
        _ ->
            {error, imds_malformed}
    catch
        _:_ -> {error, imds_malformed}
    end.

%%====================================================================
%% Web identity (STS AssumeRoleWithWebIdentity)
%%====================================================================

-spec fetch_web_identity(map()) -> {ok, creds()} | {error, term()}.
fetch_web_identity(Opts) ->
    case {token_file(Opts), role_arn(Opts)} of
        {undefined, _} ->
            {error, no_web_identity_token};
        {_, undefined} ->
            {error, no_role_arn};
        {File, RoleArn} ->
            case file:read_file(File) of
                {ok, TokenRaw} -> assume_role(Opts, RoleArn, string:trim(TokenRaw));
                {error, Reason} -> {error, {web_identity_token, Reason}}
            end
    end.

assume_role(Opts, RoleArn, Token) ->
    Client = metadata_client(Opts, <<"https://sts.amazonaws.com">>),
    Session = maps:get(role_session_name, Opts, <<"livery-s3">>),
    Body = livery_s3_uri:canonical_query([
        {<<"Action">>, <<"AssumeRoleWithWebIdentity">>},
        {<<"Version">>, <<"2011-06-15">>},
        {<<"RoleArn">>, RoleArn},
        {<<"RoleSessionName">>, Session},
        {<<"WebIdentityToken">>, Token}
    ]),
    Headers = [{<<"content-type">>, <<"application/x-www-form-urlencoded">>}],
    case
        livery_client:request(Client, post, <<"/">>, #{headers => Headers, body => {full, Body}})
    of
        {ok, #{status := 200} = Resp} -> sts_creds(body(Resp));
        {ok, #{status := S} = Resp} -> {error, {web_identity, S, body(Resp)}};
        {error, Reason} -> {error, {web_identity, Reason}}
    end.

-spec sts_creds(binary()) -> {ok, creds()} | {error, term()}.
sts_creds(Xml) ->
    case livery_s3_xml:parse(Xml) of
        {ok, Tree} ->
            case credentials_node(Tree) of
                undefined ->
                    {error, sts_malformed};
                Node ->
                    Base = creds(
                        livery_s3_xml:text(Node, <<"AccessKeyId">>),
                        livery_s3_xml:text(Node, <<"SecretAccessKey">>),
                        livery_s3_xml:text(Node, <<"SessionToken">>)
                    ),
                    {ok, with_expiry(Base, livery_s3_xml:text(Node, <<"Expiration">>))}
            end;
        {error, Reason} ->
            {error, {sts_parse, Reason}}
    end.

credentials_node(Tree) ->
    case livery_s3_xml:child(Tree, <<"AssumeRoleWithWebIdentityResult">>) of
        undefined -> undefined;
        Result -> livery_s3_xml:child(Result, <<"Credentials">>)
    end.

%%====================================================================
%% Helpers
%%====================================================================

-spec creds(binary(), binary(), binary() | undefined) -> creds().
creds(AccessKey, Secret, undefined) ->
    #{access_key_id => AccessKey, secret_access_key => Secret};
creds(AccessKey, Secret, Token) ->
    #{access_key_id => AccessKey, secret_access_key => Secret, session_token => Token}.

-spec with_expiry(creds(), binary() | undefined) -> creds().
with_expiry(Creds, undefined) ->
    Creds;
with_expiry(Creds, Iso) ->
    try calendar:rfc3339_to_system_time(binary_to_list(Iso), [{unit, second}]) of
        Epoch -> Creds#{expires_at => Epoch}
    catch
        _:_ -> Creds
    end.

%% A small livery_client for metadata fetches; Opts may override base_url,
%% adapter, and adapter_opts (the latter two let tests inject a fake transport).
metadata_client(Opts, DefaultBase) ->
    livery_client:new(#{
        base_url => maps:get(base_url, Opts, DefaultBase),
        adapter => maps:get(adapter, Opts, livery_client_hackney),
        adapter_opts => maps:get(adapter_opts, Opts, #{hackney => [{connect_timeout, 1000}]}),
        stack => [livery_client:timeout(maps:get(timeout, Opts, 3000))]
    }).

body(Resp) ->
    case livery_client:body(Resp) of
        {full, Bin} -> Bin;
        _ -> <<>>
    end.

getenv(Name) ->
    case os:getenv(Name) of
        false -> undefined;
        "" -> undefined;
        Value -> list_to_binary(Value)
    end.

token_file(Opts) ->
    case maps:get(token_file, Opts, undefined) of
        undefined -> getenv("AWS_WEB_IDENTITY_TOKEN_FILE");
        File -> File
    end.

role_arn(Opts) ->
    case maps:get(role_arn, Opts, undefined) of
        undefined -> env_role_arn();
        Arn -> Arn
    end.

env_role_arn() ->
    getenv("AWS_ROLE_ARN").

default_profile() ->
    case getenv("AWS_PROFILE") of
        undefined -> <<"default">>;
        Profile -> Profile
    end.

shared_credentials_path() ->
    case getenv("AWS_SHARED_CREDENTIALS_FILE") of
        undefined -> iolist_to_binary([home(), "/.aws/credentials"]);
        Path -> Path
    end.

home() ->
    case os:getenv("HOME") of
        false -> ".";
        Home -> Home
    end.
