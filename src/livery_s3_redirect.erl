%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(livery_s3_redirect).
-moduledoc """
Client layer: follow S3 region redirects.

AWS answers a request aimed at the wrong region with a redirect that names the
right one: `400 AuthorizationHeaderMalformed` carrying a `<Region>` element (the
endpoint is reachable but the request was signed for the wrong region), or `301
PermanentRedirect` carrying an `<Endpoint>` element (the request must go to a
different host). The correct region is also echoed in the `x-amz-bucket-region`
header. This layer detects those, rewrites the request (signing region and/or
host) and retries once, so the inner signing layer re-signs for the new target.

It is placed above the retry layer and below signing. Single-region
S3-compatible stores never emit these responses, so the layer is a no-op there.
Host rewriting follows AWS's virtual-hosted `<Endpoint>` and keeps the path, so
it targets virtual-hosted addressing (the AWS default). Streamed response bodies
are left untouched; detection then relies on the `x-amz-bucket-region` header.
""".

-export([call/3]).

-spec call(livery_client:request(), livery_client:next(), map()) ->
    livery_client:result().
call(Req, Next, Opts) ->
    follow(Req, Next, maps:get(max, Opts, 1)).

-spec follow(livery_client:request(), livery_client:next(), non_neg_integer()) ->
    livery_client:result().
follow(Req, Next, 0) ->
    Next(Req);
follow(Req, Next, Left) ->
    case Next(Req) of
        {ok, Resp} = Result ->
            case redirect(Req, Resp) of
                undefined -> Result;
                Req1 -> follow(Req1, Next, Left - 1)
            end;
        {error, _} = Error ->
            Error
    end.

%% The rewritten request to retry, or `undefined` when this is not a redirect.
-spec redirect(livery_client:request(), livery_client:response()) ->
    livery_client:request() | undefined.
redirect(Req, #{status := Status} = Resp) when Status =:= 301; Status =:= 307 ->
    case error_field(Resp, <<"Endpoint">>) of
        undefined -> undefined;
        Host -> with_region(Req#{url => swap_host(maps:get(url, Req), Host)}, region(Resp))
    end;
redirect(Req, #{status := 400} = Resp) ->
    case error_field(Resp, <<"Code">>) of
        <<"AuthorizationHeaderMalformed">> ->
            case region(Resp) of
                undefined -> undefined;
                Region -> with_region(Req, Region)
            end;
        _ ->
            undefined
    end;
redirect(_Req, _Resp) ->
    undefined.

%% The corrected region: the `x-amz-bucket-region` header, else `<Region>`.
-spec region(livery_client:response()) -> binary() | undefined.
region(Resp) ->
    case header(<<"x-amz-bucket-region">>, Resp) of
        undefined -> error_field(Resp, <<"Region">>);
        Region -> Region
    end.

-spec with_region(livery_client:request(), binary() | undefined) -> livery_client:request().
with_region(Req, undefined) ->
    Req;
with_region(Req, Region) ->
    Meta = maps:get(meta, Req, #{}),
    Req#{meta => Meta#{region => Region}}.

%% Replace the authority of an absolute URL, keeping scheme, path, and query.
-spec swap_host(binary(), binary()) -> binary().
swap_host(Url, Host) ->
    [Scheme, Rest] = binary:split(Url, <<"://">>),
    PathQuery =
        case binary:split(Rest, <<"/">>) of
            [_Authority, PQ] -> <<"/", PQ/binary>>;
            [_Authority] -> <<>>
        end,
    <<Scheme/binary, "://", Host/binary, PathQuery/binary>>.

-spec header(binary(), livery_client:response()) -> binary() | undefined.
header(Name, #{headers := Headers}) ->
    L = string:lowercase(Name),
    case lists:search(fun({K, _}) -> string:lowercase(K) =:= L end, Headers) of
        {value, {_, V}} -> V;
        false -> undefined
    end.

%% Read a child element's text from a full-body XML error. Streamed bodies are
%% left untouched (header-only detection still applies).
-spec error_field(livery_client:response(), binary()) -> binary() | undefined.
error_field(#{body := {full, Bin}}, Field) when Bin =/= <<>> ->
    case livery_s3_xml:parse(Bin) of
        {ok, Tree} -> livery_s3_xml:text(Tree, Field);
        {error, _} -> undefined
    end;
error_field(_Resp, _Field) ->
    undefined.
