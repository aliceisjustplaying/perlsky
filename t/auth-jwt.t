use v5.34;
use warnings;

use Config ();
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use Mojo::Headers;
use Mojo::Message::Request;
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
use ATProto::PDS::API::Server qw(require_auth);
use ATProto::PDS::Auth::JWT qw(decode_jwt encode_jwt encode_service_jwt);
use ATProto::PDS::Crypto::Secp256k1 qw(generate_keypair);
use ATProto::PDS::Store::SQLite;
use ATProto::PDS::Constants qw(TOKEN_AUD_ACCESS);

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

{
  my $tmp = tempdir(CLEANUP => 1);
  my $store = ATProto::PDS::Store::SQLite->new(
    path => File::Spec->catfile($tmp, 'perlsky.sqlite'),
  )->bootstrap;

  my $account = $store->create_account(
    id            => 'acct-auth-jwt',
    did           => 'did:web:example.test:users:alice',
    handle        => 'alice.example.test',
    email         => 'alice@example.test',
    password_hash => 'sha256:abc',
    did_doc       => { id => 'did:web:example.test:users:alice' },
  );

  my $app_session = $store->create_session(
    id         => 'sess-app',
    did        => $account->{did},
    kind       => 'app_password',
    scope      => 'app_password',
    expires_at => 1_900_000_000,
  );
  my $full_session = $store->create_session(
    id         => 'sess-full',
    did        => $account->{did},
    kind       => 'account',
    scope      => TOKEN_AUD_ACCESS,
    expires_at => 1_900_000_000,
  );

  my $secret = 'auth-jwt-secret';
  my $app_token = encode_jwt({
    iss   => 'did:web:example.test',
    sub   => $account->{did},
    aud   => TOKEN_AUD_ACCESS,
    scope => 'app_password',
    typ   => TOKEN_AUD_ACCESS,
    jti   => $app_session->{id},
    exp   => 1_900_000_000,
  }, $secret);
  my $full_token = encode_jwt({
    iss   => 'did:web:example.test',
    sub   => $account->{did},
    aud   => TOKEN_AUD_ACCESS,
    scope => TOKEN_AUD_ACCESS,
    typ   => TOKEN_AUD_ACCESS,
    jti   => $full_session->{id},
    exp   => 1_900_000_000,
  }, $secret);

  my $app_error = dies {
    require_auth(
      _mock_controller($store, $app_token, $secret),
      audience       => TOKEN_AUD_ACCESS,
      required_scope => 'full',
    );
  };
  is(
    $app_error,
    {
      status  => 400,
      error   => 'InvalidToken',
      message => 'Bad token scope',
    },
    'full-scope auth gates reject app-password sessions',
  );

  my ($claims, $resolved_account, $resolved_session) = require_auth(
    _mock_controller($store, $full_token, $secret),
    audience       => TOKEN_AUD_ACCESS,
    required_scope => 'full',
  );
  is($claims->{jti}, $full_session->{id}, 'full-scope auth accepts a normal account session token');
  is($resolved_account->{did}, $account->{did}, 'full-scope auth returns the account');
  is($resolved_session->{id}, $full_session->{id}, 'full-scope auth returns the matched session');
}

done_testing;

sub _b64url_decode {
  my ($text) = @_;
  my $b64 = $text;
  $b64 =~ tr/-_/+\//;
  my $pad = length($b64) % 4;
  $b64 .= '=' x (4 - $pad) if $pad;
  return decode_base64($b64);
}

sub _mock_controller {
  my ($store, $token, $secret) = @_;
  return bless {
    store  => $store,
    req    => _mock_request($token),
    config => {
      jwt_secret => $secret,
    },
  }, 'Local::AuthJWT::Controller';
}

sub _mock_request {
  my ($token) = @_;
  my $req = Mojo::Message::Request->new;
  $req->headers->authorization("Bearer $token");
  return $req;
}

package Local::AuthJWT::Controller;

sub req         { shift->{req} }
sub store       { shift->{store} }
sub config_value {
  my ($self, $key, $default) = @_;
  return exists $self->{config}{$key} ? $self->{config}{$key} : $default;
}
