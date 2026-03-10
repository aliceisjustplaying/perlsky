use v5.34;
use warnings;

use Config ();
use File::Spec;
use FindBin qw($Bin);
use Test2::V0;
use JSON::PP qw(decode_json);
use MIME::Base64 qw(decode_base64);

BEGIN {
  require lib;
  my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
  lib->import(
    File::Spec->catdir($root, 'lib'),
    File::Spec->catdir($root, 'local', 'lib', 'perl5'),
    File::Spec->catdir($root, 'local', 'lib', 'perl5', $Config::Config{archname}),
  );
}

use Crypt::PK::ECC;
use ATProto::PDS::Auth::JWT qw(decode_jwt encode_jwt encode_service_jwt);
use ATProto::PDS::Crypto::Secp256k1 qw(generate_keypair);

my $token = encode_jwt(
  {
    sub => 'did:web:example.com:users:alice',
    aud => 'perlsky',
    exp => 1_900_000_000,
  },
  'super-secret',
);

my $decoded = decode_jwt($token, 'super-secret', audience => 'perlsky', now => 1_800_000_000);

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

my $keys = generate_keypair();
my $service = encode_service_jwt(
  {
    iss => 'did:plc:alice',
    aud => 'did:web:api.bsky.app',
    exp => 1_900_000_000,
    iat => 1_800_000_000,
    lxm => 'app.bsky.actor.getPreferences',
    jti => 'test-jti',
  },
  $keys->{private_key},
);
my ($header_b64, $claims_b64, $sig_b64) = split /\./, $service, 3;
my $header = decode_json(_b64url_decode($header_b64));
my $claims = decode_json(_b64url_decode($claims_b64));

is($header->{alg}, 'ES256K', 'service tokens use ES256K');
is($claims->{iss}, 'did:plc:alice', 'service token issuer round-trips');
is($claims->{aud}, 'did:web:api.bsky.app', 'service token audience round-trips');
is($claims->{lxm}, 'app.bsky.actor.getPreferences', 'service token method round-trips');

my $pk = Crypt::PK::ECC->new;
$pk->import_key_raw($keys->{public_key}, 'secp256k1');
ok(
  $pk->verify_message_rfc7518(_b64url_decode($sig_b64), "$header_b64.$claims_b64", 'SHA256'),
  'service token signature verifies',
);

done_testing;

sub _b64url_decode {
  my ($text) = @_;
  my $b64 = $text;
  $b64 =~ tr/-_/+\//;
  my $pad = length($b64) % 4;
  $b64 .= '=' x (4 - $pad) if $pad;
  return decode_base64($b64);
}
