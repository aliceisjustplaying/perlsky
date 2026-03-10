use v5.34;
use warnings;

use Config ();
use FindBin qw($Bin);
use File::Spec;
use JSON::PP ();
use Test2::V0;

BEGIN {
  require lib;
  my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
  lib->import(
    File::Spec->catdir($root, 'lib'),
    File::Spec->catdir($root, 'local', 'lib', 'perl5'),
    File::Spec->catdir($root, 'local', 'lib', 'perl5', $Config::Config{archname}),
  );
}

use ATProto::PDS::Repo::Bytes;
use ATProto::PDS::Repo::CAR qw(read_car write_car);
use ATProto::PDS::Repo::CID qw(CID_CODEC_DAG_CBOR);
use ATProto::PDS::Repo::DagCbor qw(decode_dag_cbor encode_dag_cbor);
use ATProto::PDS::Repo::MST qw(build_mst);

my $record = {
  '$type' => 'app.bsky.feed.post',
  text    => 'hello world',
  langs   => ['en'],
  reply   => undef,
  seen    => JSON::PP::true,
  gone    => JSON::PP::false,
};

my $record_bytes = encode_dag_cbor($record);
my $record_cid   = ATProto::PDS::Repo::CID->for_dag_cbor($record_bytes);
my $roundtrip    = decode_dag_cbor($record_bytes);

is($roundtrip->{text}, 'hello world', 'dag-cbor roundtrip preserves text');
is($record_cid->codec, CID_CODEC_DAG_CBOR, 'record cid uses dag-cbor codec');
is(
  ATProto::PDS::Repo::CID->from_string($record_cid->to_string)->to_string,
  $record_cid->to_string,
  'cid string roundtrip works',
);

my $mst_a = build_mst({
  'app.bsky.feed.post/aaa' => $record_cid,
  'app.bsky.feed.post/bbb' => $record_cid,
  'app.bsky.feed.post/ccc' => $record_cid,
});

my $mst_b = build_mst({
  'app.bsky.feed.post/ccc' => $record_cid,
  'app.bsky.feed.post/aaa' => $record_cid,
  'app.bsky.feed.post/bbb' => $record_cid,
});

is($mst_a->{root}->to_string, $mst_b->{root}->to_string, 'mst root is deterministic');

my $car = write_car($record_cid, [
  { cid => $record_cid, bytes => $record_bytes },
  @{ $mst_a->{blocks} },
]);

my $parsed = read_car($car);
is($parsed->{roots}[0]->to_string, $record_cid->to_string, 'car root roundtrip works');
ok(@{ $parsed->{blocks} } >= 2, 'car returns blocks');

done_testing;
