use v5.34;
use warnings;

use Config ();
use File::Path qw(remove_tree);
use File::Spec;
use FindBin qw($Bin);
use JSON::PP qw(decode_json);
use MIME::Base64 qw(decode_base64);
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

use Test::Mojo;
use Crypt::PK::ECC;
use ATProto::PDS;

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $tmp  = File::Spec->catdir($root, 'data', 'tmp-tests', 'server-auth');
remove_tree($tmp) if -d $tmp;

my $config = {
  base_url              => 'http://127.0.0.1:7755',
  service_did_method    => 'did:web',
  service_handle_domain => 'localhost',
  jwt_secret            => 'test-secret',
  data_dir              => $tmp,
  db_path               => File::Spec->catfile($tmp, 'perlsky.sqlite'),
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
  ->json_is('/handle' => 'alice.localhost')
  ->json_like('/did' => qr/\Adid:web:/)
  ->json_has('/accessJwt')
  ->json_has('/refreshJwt');

my $created = $t->tx->res->json;
my $access  = $created->{accessJwt};
my $refresh = $created->{refreshJwt};
my $did     = $created->{did};
my ($account_id) = $did =~ /:users:([^:]+)\z/;

$t->get_ok('/xrpc/com.atproto.server.getSession' => { Authorization => "Bearer $access" })
  ->status_is(200)
  ->json_is('/handle' => 'alice.localhost')
  ->json_is('/email' => 'alice@example.com');

$t->get_ok("/xrpc/com.atproto.identity.resolveHandle?handle=alice.localhost")
  ->status_is(200)
  ->json_is('/did' => $did);

$t->get_ok("/users/$account_id/did.json")
  ->status_is(200)
  ->json_is('/id' => $did)
  ->json_is('/alsoKnownAs/0' => 'at://alice.localhost');

$t->post_ok('/xrpc/com.atproto.server.createAppPassword' => { Authorization => "Bearer $access" } => json => {
  name => 'phone',
})->status_is(200)
  ->json_is('/name' => 'phone')
  ->json_has('/password');

my $app_password = $t->tx->res->json->{password};

$t->post_ok('/xrpc/com.atproto.server.createAppPassword' => { Authorization => "Bearer $access" } => json => {
  name       => 'desktop',
  privileged => JSON::PP::true,
})->status_is(200)
  ->json_is('/name' => 'desktop')
  ->json_is('/privileged' => JSON::PP::true)
  ->json_has('/password');

my $privileged_app_password = $t->tx->res->json->{password};

$t->get_ok('/xrpc/com.atproto.server.listAppPasswords' => { Authorization => "Bearer $access" })
  ->status_is(200);

my %listed_password = map { $_->{name} => $_ } @{ $t->tx->res->json->{passwords} || [] };
is($listed_password{phone}{privileged}, 0, 'standard app password is listed as non-privileged');
is($listed_password{desktop}{privileged}, 1, 'privileged app password is listed as privileged');

$t->post_ok('/xrpc/com.atproto.server.createSession' => json => {
  identifier => 'alice.localhost',
  password   => $app_password,
})->status_is(200)
  ->json_is('/did' => $did);

my $app_session = $t->tx->res->json;
my (undef, $app_claims_b64, undef) = split /\./, $app_session->{accessJwt}, 3;
my $app_claims = decode_json(_b64url_decode($app_claims_b64));
is($app_claims->{scope}, 'app_password', 'app password login issues an app password-scoped access token');

$t->post_ok('/xrpc/com.atproto.server.createSession' => json => {
  identifier => 'alice.localhost',
  password   => $privileged_app_password,
})->status_is(200)
  ->json_is('/did' => $did);

my $privileged_app_session = $t->tx->res->json;
is(
  _jwt_claims($privileged_app_session->{accessJwt})->{scope},
  'app_password_privileged',
  'privileged app password login preserves privileged scope',
);

$t->get_ok('/xrpc/com.atproto.server.getSession' => { Authorization => "Bearer $app_session->{accessJwt}" })
  ->status_is(200)
  ->json_is('/did' => $did);

$t->get_ok('/xrpc/com.atproto.server.getServiceAuth?aud=did:web:api.bsky.app&lxm=com.atproto.server.createaccount' => {
  Authorization => "Bearer $app_session->{accessJwt}",
})->status_is(400)
  ->json_is('/error' => 'InvalidToken');

$t->get_ok('/xrpc/com.atproto.server.getServiceAuth?aud=did:web:api.bsky.app&lxm=com.atproto.server.createaccount' => {
  Authorization => "Bearer $privileged_app_session->{accessJwt}",
})->status_is(200)
  ->json_has('/token');

$t->post_ok('/xrpc/com.atproto.server.createAppPassword' => { Authorization => "Bearer $app_session->{accessJwt}" } => json => {
  name => 'nested',
})->status_is(400)
  ->json_is('/error' => 'InvalidToken');

$t->get_ok('/xrpc/com.atproto.server.getAccountInviteCodes' => { Authorization => "Bearer $app_session->{accessJwt}" })
  ->status_is(400)
  ->json_is('/error' => 'InvalidToken');

$t->post_ok('/xrpc/com.atproto.server.revokeAppPassword' => { Authorization => "Bearer $access" } => json => {
  name => 'phone',
})->status_is(200);

$t->post_ok('/xrpc/com.atproto.server.refreshSession' => { Authorization => "Bearer $app_session->{refreshJwt}" } => json => {})
  ->status_is(401)
  ->json_is('/error' => 'ExpiredToken');

$t->get_ok('/xrpc/com.atproto.server.listAppPasswords' => { Authorization => "Bearer $access" })
  ->status_is(200);

my %remaining_password = map { $_->{name} => $_ } @{ $t->tx->res->json->{passwords} || [] };
ok(!exists $remaining_password{phone}, 'revoked app password is removed from listing');
is($remaining_password{desktop}{privileged}, 1, 'remaining privileged app password stays privileged');

$t->post_ok('/xrpc/com.atproto.server.refreshSession' => { Authorization => "Bearer $refresh" } => json => {})
  ->status_is(200)
  ->json_has('/accessJwt')
  ->json_has('/refreshJwt');

my $refreshed = $t->tx->res->json;

$t->get_ok('/xrpc/com.atproto.server.getSession' => { Authorization => "Bearer $access" })
  ->status_is(200)
  ->json_is('/did' => $did);

$t->post_ok('/xrpc/com.atproto.server.refreshSession' => { Authorization => "Bearer $refresh" } => json => {})
  ->status_is(200)
  ->json_has('/refreshJwt');

my $reused_refresh = $t->tx->res->json;
is(
  _jwt_claims($reused_refresh->{refreshJwt})->{jti},
  _jwt_claims($refreshed->{refreshJwt})->{jti},
  'refresh reuse during grace period returns the same successor refresh session',
);

$t->get_ok('/xrpc/com.atproto.server.getSession' => { Authorization => "Bearer $refresh" })
  ->status_is(401)
  ->json_is('/error' => 'InvalidToken');

$t->get_ok('/xrpc/com.atproto.server.getSession' => { Authorization => "Bearer $refreshed->{refreshJwt}" })
  ->status_is(401)
  ->json_is('/error' => 'InvalidToken');

$t->get_ok('/xrpc/com.atproto.server.getSession' => { Authorization => "Bearer $refreshed->{accessJwt}" })
  ->status_is(200)
  ->json_is('/did' => $did);

$t->post_ok('/xrpc/com.atproto.server.deleteSession' => { Authorization => "Bearer $refreshed->{refreshJwt}" } => json => {})
  ->status_is(200);

$t->get_ok('/xrpc/com.atproto.server.getSession' => { Authorization => "Bearer $refreshed->{accessJwt}" })
  ->status_is(401)
  ->json_is('/error' => 'ExpiredToken');

$t->post_ok('/xrpc/com.atproto.server.createSession' => json => {
  identifier => 'alice.localhost',
  password   => 'password123',
})->status_is(200)
  ->json_is('/did' => $did);

my $replacement_access = $t->tx->res->json->{accessJwt};

$t->get_ok('/xrpc/com.atproto.server.getServiceAuth?aud=did:web:api.bsky.app&lxm=com.atproto.server.createAppPassword' => {
  Authorization => "Bearer $replacement_access",
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest');

$t->get_ok('/xrpc/com.atproto.server.getServiceAuth?aud=did:web:api.bsky.app&lxm=app.bsky.actor.getPreferences' => {
  Authorization => "Bearer $replacement_access",
})->status_is(200)
  ->json_has('/token');

my ($header_b64, $claims_b64, $sig_b64) = split /\./, $t->tx->res->json->{token}, 3;
my $header = decode_json(_b64url_decode($header_b64));
my $claims = decode_json(_b64url_decode($claims_b64));
is($header->{alg}, 'ES256K', 'service auth uses ES256K');
is($claims->{iss}, $did, 'service auth issuer is the account DID');
is($claims->{aud}, 'did:web:api.bsky.app', 'service auth audience matches request');
is($claims->{lxm}, 'app.bsky.actor.getPreferences', 'service auth binds the requested method');

my $account = $t->app->store->get_account_by_did($did);
my $pk = Crypt::PK::ECC->new;
$pk->import_key_raw($account->{public_key}, 'secp256k1');
ok(
  $pk->verify_message_rfc7518(_b64url_decode($sig_b64), "$header_b64.$claims_b64", 'SHA256'),
  'service auth signature verifies',
);

done_testing;

sub _b64url_decode {
  my ($text) = @_;
  my $copy = $text;
  $copy =~ tr/-_/+\//;
  my $pad = length($copy) % 4;
  $copy .= '=' x (4 - $pad) if $pad;
  return decode_base64($copy);
}

sub _jwt_claims {
  my ($jwt) = @_;
  my (undef, $claims_b64, undef) = split /\./, ($jwt // q()), 3;
  return {} unless defined $claims_b64 && length $claims_b64;
  return decode_json(_b64url_decode($claims_b64));
}
