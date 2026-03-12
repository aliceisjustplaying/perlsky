use v5.34;
use warnings;

use Config ();
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
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
  settings => {
    base_url                     => 'http://127.0.0.1:7755',
    service_handle_domain        => 'example.test',
    service_did_method           => 'did:web',
    jwt_secret                   => 'account-self-service-secret',
    admin_password               => 'admin-secret',
    testing_auto_confirm_email   => 1,
    data_dir                     => $tmp,
    db_path                      => File::Spec->catfile($tmp, 'perlsky.sqlite'),
  },
);

my $t = Test::Mojo->new($app);
my $admin_auth = 'Basic YWRtaW46YWRtaW4tc2VjcmV0';

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'alice.example.test',
  email    => 'alice@example.test',
  password => 'hunter22',
})->status_is(200);

my $created = $t->tx->res->json;
my $access  = $created->{accessJwt};
my $did     = $created->{did};

$t->get_ok('/xrpc/com.atproto.admin.getAccountInfo' => {
  Authorization => $admin_auth,
} => form => {
  did => $did,
})->status_is(200)
  ->json_is('/did', $did)
  ->json_is('/handle', 'alice.example.test');

$t->post_ok('/xrpc/com.atproto.identity.updateHandle' => {
  Authorization => "Bearer $access",
} => json => {
  handle => 'alice-renamed.example.test',
})->status_is(200);

$t->post_ok('/xrpc/com.atproto.identity.refreshIdentity' => json => {
  identifier => 'alice-renamed.example.test',
})->status_is(200)
  ->json_is('/did', $did)
  ->json_is('/handle', 'alice-renamed.example.test');

$t->post_ok('/xrpc/com.atproto.server.requestEmailUpdate' => {
  Authorization => "Bearer $access",
} => json => {})->status_is(200);
ok($t->tx->res->json->{tokenRequired}, 'confirmed email requires update token');

my $email_update = $app->store->latest_action_token(
  did     => $did,
  purpose => 'email_update',
);

$t->post_ok('/xrpc/com.atproto.server.updateEmail' => {
  Authorization => "Bearer $access",
} => json => {
  email => 'alice+new@example.test',
  token => $email_update->{token},
})->status_is(200);

$t->post_ok('/xrpc/com.atproto.server.requestEmailConfirmation' => {
  Authorization => "Bearer $access",
} => json => {})->status_is(200);

my $email_confirm = $app->store->latest_action_token(
  did     => $did,
  purpose => 'email_confirm',
);

$t->post_ok('/xrpc/com.atproto.server.confirmEmail' => {
  Authorization => "Bearer $access",
} => json => {
  email => 'alice+new@example.test',
  token => $email_confirm->{token},
})->status_is(200);

done_testing;
