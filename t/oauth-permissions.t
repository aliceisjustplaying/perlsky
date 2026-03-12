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
my $tmp  = File::Spec->catdir($root, 'data', 'tmp-tests', 'oauth-permissions');
remove_tree($tmp) if -d $tmp;

my $config = {
  base_url              => 'http://127.0.0.1:7755',
  service_did_method    => 'did:web',
  service_handle_domain => 'localhost',
  jwt_secret            => 'test-secret',
  testing_auto_confirm_email => 1,
  data_dir              => $tmp,
  db_path               => File::Spec->catfile($tmp, 'perlsky.sqlite'),
};
my $chat_aud = 'did:web:api.bsky.chat%23bsky_chat';

my $client_key = Crypt::PK::ECC->new;
$client_key->generate_key('prime256v1');
my $client_private = $client_key->export_key_raw('private');
my $client_public  = $client_key->export_key_raw('public');
my $client_jwk = _p256_public_jwk($client_public, 'oauth-permissions-key');
my $client_metadata = {
  client_id                       => 'https://client.example/permissions-metadata.json',
  client_name                     => 'Permission Test Client',
  client_uri                      => 'https://client.example',
  redirect_uris                   => ['https://client.example/callback'],
  grant_types                     => ['authorization_code', 'refresh_token'],
  response_types                  => ['code'],
  token_endpoint_auth_method      => 'private_key_jwt',
  token_endpoint_auth_signing_alg => 'ES256',
  dpop_bound_access_tokens        => JSON::PP::true,
  jwks                            => { keys => [$client_jwk] },
};

{
  no warnings 'redefine';
  local *ATProto::PDS::Auth::OAuth::_load_client_metadata = sub ($self, $client_id) {
    die 'client metadata client_id did not match request'
      unless $client_id eq $client_metadata->{client_id};
    return $client_metadata;
  };
  local *ATProto::PDS::Auth::OAuth::_load_permission_set = sub ($self, $c, $nsid) {
    return {
      permissions => [
        {
          type       => 'permission',
          resource   => 'rpc',
          inheritAud => JSON::PP::true,
          lxm        => [
            'app.bsky.notification.getPreferences',
            'app.bsky.notification.updateSeen',
          ],
        },
      ],
    } if $nsid eq 'app.bsky.authManageNotifications';
    return undef;
  };

  my $app = ATProto::PDS->new(
    project_root => $root,
    settings     => $config,
  );
  my $t = Test::Mojo->new($app);

  $t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
    handle   => 'alice',
    email    => 'alice@example.com',
    password => 'password123',
  })->status_is(200)
    ->json_is('/handle' => 'alice.localhost');

  my $account = $t->tx->res->json;
  my $did = $account->{did};

  my $atproto_only = _oauth_tokens_for_scope($t, $did, 'atproto');
  $t->get_ok('/xrpc/com.atproto.server.getSession' => _oauth_headers($atproto_only->{access_token}, 'GET', $config->{base_url} . '/xrpc/com.atproto.server.getSession'))
    ->status_is(200)
    ->json_is('/did' => $did)
    ->json_hasnt('/email');

  my $email_read = _oauth_tokens_for_scope($t, $did, 'atproto account:email');
  $t->get_ok('/xrpc/com.atproto.server.getSession' => _oauth_headers($email_read->{access_token}, 'GET', $config->{base_url} . '/xrpc/com.atproto.server.getSession'))
    ->status_is(200)
    ->json_is('/email' => 'alice@example.com');

  $t->post_ok('/xrpc/com.atproto.server.requestEmailConfirmation' => _oauth_headers($atproto_only->{access_token}, 'POST', $config->{base_url} . '/xrpc/com.atproto.server.requestEmailConfirmation') => json => {})
    ->status_is(403)
    ->json_like('/message' => qr/account:email\?action=manage/);

  my $email_manage = _oauth_tokens_for_scope($t, $did, 'atproto account:email?action=manage');
  $t->post_ok('/xrpc/com.atproto.server.requestEmailConfirmation' => _oauth_headers($email_manage->{access_token}, 'POST', $config->{base_url} . '/xrpc/com.atproto.server.requestEmailConfirmation') => json => {})
    ->status_is(200)
    ->content_is(q());
  $t->post_ok('/xrpc/com.atproto.server.requestEmailUpdate' => _oauth_headers($email_manage->{access_token}, 'POST', $config->{base_url} . '/xrpc/com.atproto.server.requestEmailUpdate') => json => {})
    ->status_is(200)
    ->json_is('/tokenRequired' => JSON::PP::true);

  $t->post_ok('/xrpc/com.atproto.repo.createRecord' => _oauth_headers($atproto_only->{access_token}, 'POST', $config->{base_url} . '/xrpc/com.atproto.repo.createRecord') => json => {
    repo       => $did,
    collection => 'app.bsky.feed.post',
    record     => {
      '$type'   => 'app.bsky.feed.post',
      text      => 'forbidden write',
      createdAt => '2026-03-12T00:00:00Z',
    },
  })->status_is(403)
    ->json_like('/message' => qr/repo:app\.bsky\.feed\.post\?action=create/);

  my $transition_generic = _oauth_tokens_for_scope($t, $did, 'atproto transition:generic');
  $t->post_ok('/xrpc/com.atproto.repo.createRecord' => _oauth_headers($transition_generic->{access_token}, 'POST', $config->{base_url} . '/xrpc/com.atproto.repo.createRecord') => json => {
    repo       => $did,
    collection => 'app.bsky.feed.post',
    record     => {
      '$type'   => 'app.bsky.feed.post',
      text      => 'transition generic write',
      createdAt => '2026-03-12T00:00:01Z',
    },
  })->status_is(200)
    ->json_like('/uri' => qr{\Aat://\Q$did\E/app\.bsky\.feed\.post/});

  my $repo_create_only = _oauth_tokens_for_scope($t, $did, 'atproto repo:app.bsky.feed.post?action=create');
  $t->post_ok('/xrpc/com.atproto.repo.putRecord' => _oauth_headers($repo_create_only->{access_token}, 'POST', $config->{base_url} . '/xrpc/com.atproto.repo.putRecord') => json => {
    repo       => $did,
    collection => 'app.bsky.feed.post',
    rkey       => 'new-post',
    record     => {
      '$type'   => 'app.bsky.feed.post',
      text      => 'put record needs both create and update',
      createdAt => '2026-03-12T00:00:02Z',
    },
  })->status_is(403)
    ->json_like('/message' => qr/repo:app\.bsky\.feed\.post\?action=update/);

  my $blob_png = _oauth_tokens_for_scope($t, $did, 'atproto blob:image/png');
  $t->post_ok('/xrpc/com.atproto.repo.uploadBlob' => {
    %{ _oauth_headers($blob_png->{access_token}, 'POST', $config->{base_url} . '/xrpc/com.atproto.repo.uploadBlob') },
    'Content-Type' => 'image/png',
  } => 'png-data')->status_is(200)
    ->json_has('/blob/ref/$link');

  $t->post_ok('/xrpc/com.atproto.repo.uploadBlob' => {
    %{ _oauth_headers($blob_png->{access_token}, 'POST', $config->{base_url} . '/xrpc/com.atproto.repo.uploadBlob') },
    'Content-Type' => 'image/jpeg',
  } => 'jpeg-data')->status_is(403)
    ->json_like('/message' => qr/blob:image\/jpeg/);

  $t->get_ok('/xrpc/app.bsky.actor.getPreferences' => _oauth_headers(
    $transition_generic->{access_token},
    'GET',
    $config->{base_url} . '/xrpc/app.bsky.actor.getPreferences',
  ))->status_is(200)
    ->json_is('/preferences' => []);

  my $notifications_include = _oauth_tokens_for_scope(
    $t,
    $did,
    'atproto include:app.bsky.authManageNotifications?aud=did:web:api.bsky.app#bsky_appview',
  );
  $t->get_ok('/xrpc/app.bsky.notification.getPreferences' => _oauth_headers(
    $notifications_include->{access_token},
    'GET',
    $config->{base_url} . '/xrpc/app.bsky.notification.getPreferences',
  ))->status_is(200)
    ->json_has('/preferences');
  $t->get_ok('/xrpc/app.bsky.actor.getPreferences' => _oauth_headers(
    $notifications_include->{access_token},
    'GET',
    $config->{base_url} . '/xrpc/app.bsky.actor.getPreferences',
  ))->status_is(403)
    ->json_like('/message' => qr/rpc:app\.bsky\.actor\.getPreferences\?aud=did:web:api\.bsky\.app#bsky_appview/);

  $t->get_ok("/xrpc/com.atproto.server.getServiceAuth?aud=$chat_aud&lxm=chat.bsky.convo.getMessages" => _oauth_headers(
    $transition_generic->{access_token},
    'GET',
    $config->{base_url} . '/xrpc/com.atproto.server.getServiceAuth',
  ))->status_is(403)
    ->json_like('/message' => qr/rpc:chat\.bsky\.convo\.getMessages\?aud=did:web:api\.bsky\.chat#bsky_chat/);

  my $transition_chat = _oauth_tokens_for_scope($t, $did, 'atproto transition:chat.bsky');
  $t->get_ok("/xrpc/com.atproto.server.getServiceAuth?aud=$chat_aud&lxm=chat.bsky.convo.getMessages" => _oauth_headers(
    $transition_chat->{access_token},
    'GET',
    $config->{base_url} . '/xrpc/com.atproto.server.getServiceAuth',
  ))->status_is(200)
    ->json_has('/token');

  $t->post_ok('/xrpc/com.atproto.server.createAppPassword' => _oauth_headers(
    $transition_generic->{access_token},
    'POST',
    $config->{base_url} . '/xrpc/com.atproto.server.createAppPassword',
  ) => json => { name => 'oauth-unsupported' })->status_is(403)
    ->json_is('/message' => 'OAuth credentials are not supported for this endpoint');

  $t->get_ok('/xrpc/com.atproto.server.getAccountInviteCodes' => _oauth_headers(
    $transition_generic->{access_token},
    'GET',
    $config->{base_url} . '/xrpc/com.atproto.server.getAccountInviteCodes',
  ))->status_is(403)
    ->json_is('/message' => 'OAuth credentials are not supported for this endpoint');

  $t->post_ok('/xrpc/com.atproto.identity.updateHandle' => _oauth_headers(
    $atproto_only->{access_token},
    'POST',
    $config->{base_url} . '/xrpc/com.atproto.identity.updateHandle',
  ) => json => { handle => 'alice-renamed' })->status_is(403)
    ->json_like('/message' => qr/identity:handle/);

  my $identity_handle = _oauth_tokens_for_scope($t, $did, 'atproto identity:handle');
  $t->post_ok('/xrpc/com.atproto.identity.updateHandle' => _oauth_headers(
    $identity_handle->{access_token},
    'POST',
    $config->{base_url} . '/xrpc/com.atproto.identity.updateHandle',
  ) => json => { handle => 'alice-renamed' })->status_is(200)
    ->json_is({});

  $t->post_ok('/xrpc/com.atproto.identity.requestPlcOperationSignature' => _oauth_headers(
    $identity_handle->{access_token},
    'POST',
    $config->{base_url} . '/xrpc/com.atproto.identity.requestPlcOperationSignature',
  ) => json => {})->status_is(403)
    ->json_like('/message' => qr/identity:\*/);

  my $identity_all = _oauth_tokens_for_scope($t, $did, 'atproto identity:*');
  $t->post_ok('/xrpc/com.atproto.identity.requestPlcOperationSignature' => _oauth_headers(
    $identity_all->{access_token},
    'POST',
    $config->{base_url} . '/xrpc/com.atproto.identity.requestPlcOperationSignature',
  ) => json => {})->status_is(200)
    ->json_is({});

  my $plc_token = $app->store->latest_action_token(
    did     => $did,
    purpose => 'plc_operation',
  );
  ok($plc_token && $plc_token->{token}, 'identity:* oauth token can request a PLC operation token');

  $t->post_ok('/xrpc/com.atproto.identity.signPlcOperation' => _oauth_headers(
    $identity_handle->{access_token},
    'POST',
    $config->{base_url} . '/xrpc/com.atproto.identity.signPlcOperation',
  ) => json => {
    token => $plc_token->{token},
  })->status_is(403)
    ->json_like('/message' => qr/identity:\*/);

  $t->post_ok('/xrpc/com.atproto.identity.signPlcOperation' => _oauth_headers(
    $identity_all->{access_token},
    'POST',
    $config->{base_url} . '/xrpc/com.atproto.identity.signPlcOperation',
  ) => json => {
    token => $plc_token->{token},
  })->status_is(400)
    ->json_is('/error' => 'InvalidRequest');
}

done_testing;

sub _oauth_tokens_for_scope ($t, $identifier, $scope) {
  my $code_verifier  = 'verifier-' . _random_hex(24);
  my $code_challenge = base64url_encode(sha256($code_verifier));
  my $state          = 'state-' . _random_hex(12);
  my $par_url        = $config->{base_url} . '/oauth/par';
  my $token_url      = $config->{base_url} . '/oauth/token';

  $t->post_ok('/oauth/par' => {
    DPoP => _dpop_jwt($client_jwk, $client_private, 'POST', $par_url),
  } => form => {
    client_id             => $client_metadata->{client_id},
    response_type         => 'code',
    redirect_uri          => $client_metadata->{redirect_uris}[0],
    scope                 => $scope,
    state                 => $state,
    login_hint            => $identifier,
    code_challenge        => $code_challenge,
    code_challenge_method => 'S256',
    client_assertion_type => 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer',
    client_assertion      => _client_assertion($client_metadata->{client_id}, $par_url, $client_jwk, $client_private),
  })->status_is(201)
    ->json_has('/request_uri');

  my $request_uri = $t->tx->res->json->{request_uri};

  $t->post_ok('/oauth/authorize' => form => {
    request_uri => $request_uri,
    identifier  => $identifier,
    password    => 'password123',
    decision    => 'approve',
  })->status_is(302);

  my $callback = Mojo::URL->new($t->tx->res->headers->location);
  my $code = $callback->query->param('code');

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
  })->status_is(200)
    ->json_has('/access_token');

  return $t->tx->res->json;
}

sub _oauth_headers ($access_token, $method, $url) {
  my $dpop_url = Mojo::URL->new($url);
  $dpop_url->query(undef);
  return {
    Authorization => "DPoP $access_token",
    DPoP          => _dpop_jwt($client_jwk, $client_private, $method, $dpop_url->to_string, ath => $access_token),
  };
}

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
