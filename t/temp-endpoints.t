use v5.34;
use warnings;

use Config ();
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use MIME::Base64 qw(encode_base64);
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
use ATProto::PDS;

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $tmp  = tempdir(CLEANUP => 1);

my $app = ATProto::PDS->new(
  project_root => $root,
  settings     => {
    base_url                   => 'http://127.0.0.1:7755',
    service_handle_domain      => 'example.test',
    service_did_method         => 'did:web',
    jwt_secret                 => 'temp-endpoints-secret',
    admin_password             => 'admin-secret',
    testing_auto_confirm_email => 1,
    data_dir                   => $tmp,
    db_path                    => File::Spec->catfile($tmp, 'perlsky.sqlite'),
  },
);

my $t = Test::Mojo->new($app);
my $admin_auth = 'Basic ' . encode_base64('admin:admin-secret', q());

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'alice.example.test',
  email    => 'alice@example.test',
  password => 'hunter22',
})->status_is(200);

my $created = $t->tx->res->json;
my $did     = $created->{did};
my $access  = $created->{accessJwt};

$t->post_ok('/xrpc/com.atproto.server.createAppPassword' => {
  Authorization => "Bearer $access",
} => json => {
  name => 'revoke-me',
})->status_is(200)
  ->json_like('/password' => qr/\w/);

my $app_password = $t->tx->res->json->{password};

$t->get_ok('/xrpc/com.atproto.temp.checkSignupQueue')
  ->status_is(200)
  ->json_is('/activated' => JSON::PP::true);

$t->get_ok('/xrpc/com.atproto.temp.dereferenceScope?scope=ref:app.bsky.feed.post')
  ->status_is(200)
  ->json_is('/scope' => 'app.bsky.feed.post');

$t->get_ok('/xrpc/com.atproto.temp.dereferenceScope?scope=app.bsky.feed.post')
  ->status_is(400)
  ->json_is('/error' => 'InvalidScopeReference');

$t->get_ok('/xrpc/com.atproto.temp.dereferenceScope?scope=ref:')
  ->status_is(400)
  ->json_is('/error' => 'InvalidScopeReference');

$t->post_ok('/xrpc/com.atproto.temp.requestPhoneVerification' => json => {
  phoneNumber => '+441234567890',
})->status_is(200)
  ->content_is(q());

$t->post_ok('/xrpc/com.atproto.temp.revokeAccountCredentials' => json => {
  account => $did,
})->status_is(401)
  ->json_is('/error' => 'AuthRequired');

$t->post_ok('/xrpc/com.atproto.temp.revokeAccountCredentials' => {
  Authorization => $admin_auth,
} => json => {
  account => $did,
})->status_is(200)
  ->content_is(q());

$t->get_ok('/xrpc/com.atproto.server.getSession' => {
  Authorization => "Bearer $access",
})->status_is(401);

$t->post_ok('/xrpc/com.atproto.server.createSession' => json => {
  identifier => 'alice.example.test',
  password   => $app_password,
})->status_is(401)
  ->json_is('/error' => 'AuthenticationRequired');

$t->post_ok('/xrpc/com.atproto.server.createSession' => json => {
  identifier => 'alice.example.test',
  password   => 'hunter22',
})->status_is(401)
  ->json_is('/error' => 'AuthenticationRequired');

done_testing;
