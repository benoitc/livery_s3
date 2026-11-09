-module(livery_s3_account_tests).

-include_lib("eunit/include/eunit.hrl").

-import(livery_s3_test_util, [run/3, run/2, resp/3, header/2, client/2]).

-define(ACCOUNT, #{request_payer => requester, expected_bucket_owner => <<"111122223333">>}).

headers_on_every_request_test() ->
    Ops = [
        fun(C) -> livery_s3:put_object(C, <<"b">>, <<"k">>, <<"x">>) end,
        fun(C) -> livery_s3:get_object(C, <<"b">>, <<"k">>) end,
        fun(C) -> livery_s3:list_objects(C, <<"b">>) end
    ],
    [
        begin
            {Req, _} = run(resp(200, [], <<"<ListBucketResult/>">>), ?ACCOUNT, Op),
            H = maps:get(headers, Req),
            ?assertEqual(<<"requester">>, header(<<"x-amz-request-payer">>, H)),
            ?assertEqual(<<"111122223333">>, header(<<"x-amz-expected-bucket-owner">>, H)),
            Auth = header(<<"authorization">>, H),
            ?assertNotEqual(nomatch, binary:match(Auth, <<"x-amz-request-payer">>)),
            ?assertNotEqual(nomatch, binary:match(Auth, <<"x-amz-expected-bucket-owner">>))
        end
     || Op <- Ops
    ].

absent_by_default_test() ->
    {Req, _} = run(resp(200, [], <<>>), fun(C) -> livery_s3:get_object(C, <<"b">>, <<"k">>) end),
    H = maps:get(headers, Req),
    ?assertEqual(undefined, header(<<"x-amz-request-payer">>, H)),
    ?assertEqual(undefined, header(<<"x-amz-expected-bucket-owner">>, H)).

presign_signs_request_payer_test() ->
    C = client(resp(200, [], <<>>), ?ACCOUNT),
    {ok, Url} = livery_s3:presign(C, get, <<"b">>, <<"k">>, 60),
    ?assertNotEqual(nomatch, binary:match(Url, <<"x-amz-request-payer=requester">>)),
    ?assertEqual(nomatch, binary:match(Url, <<"expected-bucket-owner">>)).
