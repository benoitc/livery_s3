-module(livery_s3_xml_tests).

-include_lib("eunit/include/eunit.hrl").

parse_list_buckets_test() ->
    Xml = <<
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        "<ListAllMyBucketsResult><Owner><ID>id</ID></Owner><Buckets>"
        "<Bucket><Name>one</Name><CreationDate>2020-01-01T00:00:00.000Z</CreationDate></Bucket>"
        "<Bucket><Name>two</Name><CreationDate>2021-02-02T00:00:00.000Z</CreationDate></Bucket>"
        "</Buckets></ListAllMyBucketsResult>"
    >>,
    {ok, Tree} = livery_s3_xml:parse(Xml),
    Buckets = livery_s3_xml:children(livery_s3_xml:child(Tree, <<"Buckets">>), <<"Bucket">>),
    ?assertEqual(2, length(Buckets)),
    [B1, B2] = Buckets,
    ?assertEqual(<<"one">>, livery_s3_xml:text(B1, <<"Name">>)),
    ?assertEqual(<<"two">>, livery_s3_xml:text(B2, <<"Name">>)).

parse_error_test() ->
    Xml = <<
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        "<Error><Code>NoSuchKey</Code><Message>The key does not exist.</Message>"
        "<RequestId>ABC123</RequestId></Error>"
    >>,
    {ok, Tree} = livery_s3_xml:parse(Xml),
    ?assertEqual(<<"NoSuchKey">>, livery_s3_xml:text(Tree, <<"Code">>)),
    ?assertEqual(<<"The key does not exist.">>, livery_s3_xml:text(Tree, <<"Message">>)),
    ?assertEqual(<<"ABC123">>, livery_s3_xml:text(Tree, <<"RequestId">>)).

parse_list_objects_test() ->
    Xml = <<
        "<ListBucketResult><Name>b</Name><IsTruncated>false</IsTruncated>"
        "<Contents><Key>a.txt</Key><Size>10</Size><ETag>\"abc\"</ETag>"
        "<LastModified>2020-01-01T00:00:00.000Z</LastModified></Contents>"
        "<Contents><Key>b.txt</Key><Size>20</Size><ETag>\"def\"</ETag></Contents>"
        "<CommonPrefixes><Prefix>photos/</Prefix></CommonPrefixes>"
        "</ListBucketResult>"
    >>,
    {ok, Tree} = livery_s3_xml:parse(Xml),
    Contents = livery_s3_xml:children(Tree, <<"Contents">>),
    ?assertEqual(2, length(Contents)),
    ?assertEqual(<<"a.txt">>, livery_s3_xml:text(hd(Contents), <<"Key">>)),
    ?assertEqual(<<"10">>, livery_s3_xml:text(hd(Contents), <<"Size">>)),
    Prefixes = livery_s3_xml:children(Tree, <<"CommonPrefixes">>),
    ?assertEqual(<<"photos/">>, livery_s3_xml:text(hd(Prefixes), <<"Prefix">>)),
    ?assertEqual(<<"false">>, livery_s3_xml:text(Tree, <<"IsTruncated">>)).

parse_versioning_test() ->
    Xml = <<"<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>">>,
    {ok, Tree} = livery_s3_xml:parse(Xml),
    ?assertEqual(<<"Enabled">>, livery_s3_xml:text(Tree, <<"Status">>)).

missing_child_test() ->
    {ok, Tree} = livery_s3_xml:parse(<<"<Root><A>x</A></Root>">>),
    ?assertEqual(undefined, livery_s3_xml:child(Tree, <<"Missing">>)),
    ?assertEqual(undefined, livery_s3_xml:text(Tree, <<"Missing">>)).

malformed_test() ->
    ?assertMatch({error, _}, livery_s3_xml:parse(<<"<not closed">>)).

no_root_element_test() ->
    ?assertMatch({error, _}, livery_s3_xml:parse(<<"not xml at all">>)).

attributes_test() ->
    {ok, Tree} = livery_s3_xml:parse(<<"<Root id=\"7\"><Child>v</Child></Root>">>),
    ?assertEqual(<<"v">>, livery_s3_xml:text(Tree, <<"Child">>)).
