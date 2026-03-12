use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Config ();
use Digest::SHA qw(sha256);
use File::Path qw(remove_tree);
use File::Spec;
use FindBin qw($Bin);
use JSON::PP qw(encode_json);
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

use Crypt::PK::ECC;
use Mojo::URL;
use Test::Mojo;
use ATProto::PDS;
use ATProto::PDS::Util::BaseX qw(base64url_encode);

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $tmp  = File::Spec->catdir($root, 'data', 'tmp-tests', 'oauth');
remove_tree($tmp) if -d $tmp;

my $config = {
  base_url              => 'http://127.0.0.1:7755',
  service_did_method    => 'did:web',
  service_handle_domain => 'localhost',
  jwt_secret            => 'test-secret',
  data_dir              => $tmp,
  db_path               => File::Spec->catfile($tmp, 'perlsky.sqlite'),
};

my $client_key = Crypt::PK::ECC->new;
$client_key->generate_key('prime256v1');
my $client_private = $client_key->export_key_raw('private');
my $client_public  = $client_key->export_key_raw('public');
my $client_jwk = _p256_public_jwk($client_public, 'tangled-test-key');
my $client_metadata = {
  client_id                         => 'https://client.example/metadata.json',
  client_name                       => 'Tangled Test Client',
  client_uri                        => 'https://client.example',
  redirect_uris                     => ['https://client.example/callback'],
  scope                             => 'atproto repo:sh.tangled.repo',
  grant_types                       => ['authorization_code', 'refresh_token'],
  response_types                    => ['code'],
  token_endpoint_auth_method        => 'private_key_jwt',
  token_endpoint_auth_signing_alg   => 'ES256',
  dpop_bound_access_tokens          => JSON::PP::true,
  jwks                              => { keys => [$client_jwk] },
};

{
  no warnings 'redefine';
  local *ATProto::PDS::Auth::OAuth::_load_client_metadata = sub ($self, $client_id) {
    die 'client metadata client_id did not match request'
      unless $client_id eq $client_metadata->{client_id};
    return $client_metadata;
  };

  my $t = Test::Mojo->new(ATProto::PDS->new(
    project_root => $root,
    settings     => $config,
  ));

  $t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
    handle   => 'alice',
    email    => 'alice@example.com',
    password => 'password123',
  })->status_is(200)
    ->json_is('/handle' => 'alice.localhost');

  my $did = $t->tx->res->json->{did};
  my $code_verifier  = 'verifier-' . _random_hex(24);
  my $code_challenge = base64url_encode(sha256($code_verifier));
  my $par_url = $config->{base_url} . '/oauth/par';

  $t->post_ok('/oauth/par' => {
    DPoP => _dpop_jwt($client_jwk, $client_private, 'POST', $par_url),
  } => form => {
    client_id             => $client_metadata->{client_id},
    response_type         => 'code',
    redirect_uri          => $client_metadata->{redirect_uris}[0],
    scope                 => $client_metadata->{scope},
    state                 => 'oauth-state-1',
    login_hint            => 'alice.localhost',
    code_challenge        => $code_challenge,
    code_challenge_method => 'S256',
    client_assertion_type => 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer',
    client_assertion      => _client_assertion($client_metadata->{client_id}, $par_url, $client_jwk, $client_private),
  })->status_is(201)
    ->json_has('/request_uri');

  my $request_uri = $t->tx->res->json->{request_uri};

  $t->get_ok(Mojo::URL->new('/oauth/authorize')->query(request_uri => $request_uri)->to_string)
    ->status_is(200)
    ->content_like(qr/Authorize Tangled Test Client/);

  $t->post_ok('/oauth/authorize' => form => {
    request_uri => $request_uri,
    identifier  => 'alice.localhost',
    password    => 'password123',
    decision    => 'approve',
  })->status_is(302);

  my $callback = Mojo::URL->new($t->tx->res->headers->location);
  is($callback->host, 'client.example', 'authorization redirects back to the registered client');
  is($callback->query->param('state'), 'oauth-state-1', 'authorization redirect keeps state');
  is($callback->query->param('iss'), $config->{base_url}, 'authorization redirect includes issuer');
  ok(length($callback->query->param('code') // q()), 'authorization redirect returns a code');
  my $code = $callback->query->param('code');

  my $token_url = $config->{base_url} . '/oauth/token';
  $t->post_ok('/oauth/token' => {
    DPoP => _dpop_jwt($client_jwk, $client_private, 'POST', $token_url),
  } => form => {
    grant_type            => 'authorization_code',
    client_id             => $client_metadata->{client_id},
    redirect_uri          => $client_metadata->{redirect_uris}[0],
    code                  => $code,
    code_verifier         => $code_verifier,
    client_assertion_type => 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer',
    client_assertion      => _client_assertion($client_metadata->{client_id}, $token_url, $client_jwk, $client_private),
  })->status_is(200);
  diag 'authorization_code response: ' . $t->tx->res->body if $t->tx->res->code != 200;
  $t->json_is('/token_type' => 'DPoP')
    ->json_is('/sub' => $did)
    ->json_has('/access_token')
    ->json_has('/refresh_token');

  my $token_data    = $t->tx->res->json;
  my $access_token  = $token_data->{access_token};
  my $refresh_token = $token_data->{refresh_token};

  my $session_url = $config->{base_url} . '/xrpc/com.atproto.server.getSession';
  $t->get_ok('/xrpc/com.atproto.server.getSession' => {
    Authorization => "DPoP $access_token",
    DPoP          => _dpop_jwt($client_jwk, $client_private, 'GET', $session_url, ath => $access_token),
  })->status_is(200)
    ->json_is('/did' => $did)
    ->json_is('/handle' => 'alice.localhost');

  $t->get_ok('/xrpc/com.atproto.server.getAccountInviteCodes' => {
    Authorization => "DPoP $access_token",
    DPoP          => _dpop_jwt($client_jwk, $client_private, 'GET', $config->{base_url} . '/xrpc/com.atproto.server.getAccountInviteCodes', ath => $access_token),
  })->status_is(403)
    ->json_is('/error' => 'Forbidden')
    ->json_is('/message' => 'OAuth credentials are not supported for this endpoint');

  $t->post_ok('/oauth/token' => {
    DPoP => _dpop_jwt($client_jwk, $client_private, 'POST', $token_url),
  } => form => {
    grant_type            => 'refresh_token',
    client_id             => $client_metadata->{client_id},
    refresh_token         => $refresh_token,
    client_assertion_type => 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer',
    client_assertion      => _client_assertion($client_metadata->{client_id}, $token_url, $client_jwk, $client_private),
  })->status_is(200);
  diag 'refresh response: ' . $t->tx->res->body if $t->tx->res->code != 200;
  $t->json_has('/access_token')
    ->json_has('/refresh_token');

  my $refreshed = $t->tx->res->json;

  my $revoke_url = $config->{base_url} . '/oauth/revoke';
  $t->post_ok('/oauth/revoke' => {
    DPoP => _dpop_jwt($client_jwk, $client_private, 'POST', $revoke_url),
  } => form => {
    client_id             => $client_metadata->{client_id},
    token                 => $refreshed->{refresh_token},
    client_assertion_type => 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer',
    client_assertion      => _client_assertion($client_metadata->{client_id}, $revoke_url, $client_jwk, $client_private),
  })->status_is(200)
    ->json_is({});

  $t->get_ok('/xrpc/com.atproto.server.getSession' => {
    Authorization => "DPoP $refreshed->{access_token}",
    DPoP          => _dpop_jwt($client_jwk, $client_private, 'GET', $session_url, ath => $refreshed->{access_token}),
  })->status_is(401)
    ->json_is('/error' => 'ExpiredToken');

  $t->post_ok('/oauth/token' => {
    DPoP => _dpop_jwt($client_jwk, $client_private, 'POST', $token_url),
  } => form => {
    grant_type            => 'refresh_token',
    client_id             => $client_metadata->{client_id},
    refresh_token         => $refreshed->{refresh_token},
    client_assertion_type => 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer',
    client_assertion      => _client_assertion($client_metadata->{client_id}, $token_url, $client_jwk, $client_private),
  })->status_is(400)
    ->json_is('/error' => 'invalid_grant');
}

done_testing;

sub _client_assertion ($client_id, $aud, $jwk, $private_key) {
  return _es256_jwt(
    {
      alg => 'ES256',
      typ => 'JWT',
      kid => $jwk->{kid},
    },
    {
      iss => $client_id,
      sub => $client_id,
      aud => $aud,
      jti => _random_hex(16),
      iat => time,
      exp => time + 300,
    },
    $private_key,
  );
}

sub _dpop_jwt ($jwk, $private_key, $method, $htu, %extra_claims) {
  my %claims = (
    htm => uc($method),
    htu => $htu,
    jti => _random_hex(16),
    iat => time,
  );
  if (defined(my $access_token = delete $extra_claims{ath})) {
    $claims{ath} = base64url_encode(sha256($access_token));
  }
  %claims = (%claims, %extra_claims);

  return _es256_jwt(
    {
      alg => 'ES256',
      typ => 'dpop+jwt',
      jwk => {
        map { $_ => $jwk->{$_} } qw(kty crv x y),
      },
    },
    \%claims,
    $private_key,
  );
}

sub _es256_jwt ($header, $claims, $private_key) {
  my $header_b64 = base64url_encode(encode_json($header));
  my $claims_b64 = base64url_encode(encode_json($claims));
  my $signing_str = join '.', $header_b64, $claims_b64;

  my $pk = Crypt::PK::ECC->new;
  $pk->import_key_raw($private_key, 'prime256v1');
  my $sig = $pk->sign_message_rfc7518($signing_str, 'SHA256');
  return join '.', $signing_str, base64url_encode($sig);
}

sub _p256_public_jwk ($public_key, $kid) {
  my $x = substr($public_key, 1, 32);
  my $y = substr($public_key, 33, 32);
  return {
    kty => 'EC',
    crv => 'P-256',
    kid => $kid,
    x   => base64url_encode($x),
    y   => base64url_encode($y),
  };
}

sub _random_hex ($bytes) {
  return join q{}, map { sprintf '%02x', int(rand(256)) } 1 .. $bytes;
}
