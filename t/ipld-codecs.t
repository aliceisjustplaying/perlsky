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

use ATProto::PDS::IPLD::Base32 qw(encode_base32 decode_base32);
use ATProto::PDS::IPLD::Base58 qw(encode_base58btc decode_base58btc);
use ATProto::PDS::IPLD::Base64 qw(encode_base64url decode_base64url);
use ATProto::PDS::IPLD::CID qw(CODEC_DAG_CBOR CODEC_RAW);
use ATProto::PDS::IPLD::DAGCBOR qw(encode_dag_cbor decode_dag_cbor cid_for_dag_cbor);
use ATProto::PDS::IPLD::Bytes;
use JSON::PP ();

my $sample = "hello world\x00\xff";

is(decode_base32(encode_base32($sample)), $sample, 'base32 round-trips bytes');
is(decode_base58btc(encode_base58btc($sample)), $sample, 'base58btc round-trips bytes');
is(decode_base64url(encode_base64url($sample)), $sample, 'base64url round-trips bytes');

my $raw_cid = ATProto::PDS::IPLD::CID->from_data(CODEC_RAW, $sample);
is("$raw_cid", $raw_cid->to_string, 'CID stringification uses multibase form');
ok($raw_cid->equals(ATProto::PDS::IPLD::CID->parse($raw_cid->to_string)), 'CID base32 parse round-trips');
ok($raw_cid->equals(ATProto::PDS::IPLD::CID->from_bytes($raw_cid->to_bytes)), 'CID byte parse round-trips');
ok($raw_cid->equals(ATProto::PDS::IPLD::CID->parse($raw_cid->to_string('base58btc'))), 'CID base58btc parse round-trips');

my $value = {
  zed   => 7,
  alpha => [JSON::PP::true, JSON::PP::false, undef],
  blob  => ATProto::PDS::IPLD::Bytes->new("\x01\x02\x03"),
  link  => $raw_cid,
  text  => 'jalapeno',
};

my $encoded = encode_dag_cbor($value);
my $decoded = decode_dag_cbor($encoded);

is($decoded->{zed}, 7, 'decoded integer preserved');
ok($decoded->{alpha}[0], 'decoded boolean true preserved');
ok(!$decoded->{alpha}[1], 'decoded boolean false preserved');
is($decoded->{alpha}[2], undef, 'decoded null preserved');
is($decoded->{blob}->bytes, "\x01\x02\x03", 'decoded bytes preserved');
ok($decoded->{link}->equals($raw_cid), 'decoded CID preserved');
is($decoded->{text}, 'jalapeno', 'decoded text preserved');

my $dag_cid = cid_for_dag_cbor({ hello => 'world' });
is($dag_cid->codec, CODEC_DAG_CBOR, 'DAG-CBOR CID uses dag-cbor codec');
ok($dag_cid->equals(ATProto::PDS::IPLD::CID->from_data(CODEC_DAG_CBOR, encode_dag_cbor({ hello => 'world' }))), 'CID matches encoded bytes');

like(dies { decode_dag_cbor("\x9f\x01\x02\xff") }, qr/indefinite-length/, 'rejects indefinite-length CBOR');
like(dies { decode_dag_cbor("\xfb\x7f\xf8\x00\x00\x00\x00\x00\x00") }, qr/floating point/, 'rejects floats');

done_testing;
