use v5.34;
use warnings;

use Config ();
use File::Spec;
use FindBin qw($Bin);
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

use ATProto::PDS::Auth::JWT qw(decode_jwt encode_jwt);

my $token = encode_jwt(
  {
    sub => 'did:web:example.com:users:alice',
    aud => 'perlds',
    exp => 1_900_000_000,
  },
  'super-secret',
);

my $decoded = decode_jwt($token, 'super-secret', audience => 'perlds', now => 1_800_000_000);

is($decoded->{claims}{sub}, 'did:web:example.com:users:alice', 'subject round-trips');
is($decoded->{header}{alg}, 'HS256', 'algorithm preserved');

like(
  dies { decode_jwt($token, 'wrong-secret', now => 1_800_000_000) },
  qr/invalid signature/,
  'signature mismatches are rejected',
);

my $expired = encode_jwt({ exp => 10 }, 'super-secret');
like(
  dies { decode_jwt($expired, 'super-secret', now => 10) },
  qr/token expired/,
  'expiration is enforced',
);

done_testing;
