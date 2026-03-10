use v5.34;
use warnings;

use Config ();
use File::Spec;
use FindBin qw($Bin);
use JSON::PP qw(decode_json);
use Test::More;

BEGIN {
  require lib;
  my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
  lib->import(
    File::Spec->catdir($root, 'lib'),
    File::Spec->catdir($root, 'local', 'lib', 'perl5'),
    File::Spec->catdir($root, 'local', 'lib', 'perl5', $Config::Config{archname}),
  );
}

use ATProto::PDS::Crypto::Secp256k1 qw(
  did_key_from_public_key
  public_key_from_did_key
  signing_did_from_private_key
);

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $fixture_path = File::Spec->catfile(
  $root,
  'tools',
  'reference',
  'atproto',
  'interop-test-files',
  'crypto',
  'w3c_didkey_K256.json',
);

open my $fh, '<', $fixture_path or die "open($fixture_path): $!";
local $/;
my $vectors = decode_json(<$fh>);
close $fh;

for my $vector (@{$vectors}) {
  my $private_key = pack('H*', $vector->{privateKeyBytesHex});
  my $did_key     = $vector->{publicDidKey};

  is(
    signing_did_from_private_key($private_key),
    $did_key,
    "private key fixture derives the official did:key $did_key",
  );

  is(
    did_key_from_public_key(public_key_from_did_key($did_key)),
    $did_key,
    "did:key round-trips through our secp256k1 codec for $did_key",
  );
}

done_testing;
