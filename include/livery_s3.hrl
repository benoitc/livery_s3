%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%%
%% Shared definitions for livery_s3.

%% SigV4 / S3 constants.
-define(S3_SERVICE, <<"s3">>).
-define(SIGV4_ALGORITHM, <<"AWS4-HMAC-SHA256">>).
-define(UNSIGNED_PAYLOAD, <<"UNSIGNED-PAYLOAD">>).
%% SHA-256 of the empty string, used as the payload hash for bodyless requests.
-define(EMPTY_SHA256,
    <<"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855">>
).

%% Immutable per-client configuration. Captured once in livery_s3:new/1 and
%% reused for URL building (endpoint + addressing) and request signing (keys +
%% region). `port' is undefined when the endpoint URL carries no explicit port.
-record(s3_config, {
    scheme :: binary(),
    host :: binary(),
    port :: undefined | inet:port_number(),
    region :: binary(),
    access_key_id :: binary(),
    secret_access_key :: binary(),
    session_token :: undefined | binary(),
    addressing :: path | virtual
}).
