use v5.34;
use warnings;

use Config ();
use FindBin qw($Bin);
use File::Spec;
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

use ATProto::PDS::IPLD::CID qw(CODEC_RAW);
use ATProto::PDS::IPLD::DAGCBOR qw(encode_dag_cbor decode_dag_cbor);

my $cid = ATProto::PDS::IPLD::CID->from_data(CODEC_RAW, 'abc');

my $encoded = encode_dag_cbor({
  aa  => 2,
  b   => 1,
  link => $cid,
});

my $expected_hex = join '', (
  'a3',
  '61', '62', '01',
  '62', '6161', '02',
  '64', '6c696e6b',
  'd82a',
  '58', '25',
  '00',
  unpack('H*', $cid->to_bytes),
);

is(unpack('H*', $encoded), $expected_hex, 'maps are encoded in canonical order and CID uses tag 42');

my $decoded = decode_dag_cbor($encoded);
ok($decoded->{link}->equals($cid), 'CID link decodes back to CID object');

done_testing;
