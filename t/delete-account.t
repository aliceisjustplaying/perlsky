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
  settings     => {
    base_url                   => 'http://127.0.0.1:7755',
    service_handle_domain      => 'example.test',
    service_did_method         => 'did:web',
    jwt_secret                 => 'delete-account-secret',
    testing_auto_confirm_email => 1,
    data_dir                   => $tmp,
    db_path                    => File::Spec->catfile($tmp, 'perlsky.sqlite'),
  },
);

my $t = Test::Mojo->new($app);

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'alice.example.test',
  email    => 'alice@example.test',
  password => 'hunter22',
})->status_is(200);

my $created = $t->tx->res->json;
my $did     = $created->{did};
my $access  = $created->{accessJwt};

$t->post_ok('/xrpc/com.atproto.server.requestAccountDelete' => {
  Authorization => "Bearer $access",
} => json => {})->status_is(200)
  ->json_is({});

my $token = $app->store->latest_action_token(
  did     => $did,
  purpose => 'account_delete',
);
ok($token && $token->{token}, 'requestAccountDelete issues an account delete token');

$t->post_ok('/xrpc/com.atproto.server.deleteAccount' => json => {
  did      => $did,
  password => 'wrong-password',
  token    => $token->{token},
})->status_is(401)
  ->json_is('/error' => 'AuthRequired')
  ->json_is('/message' => 'Invalid did or password');

$t->post_ok('/xrpc/com.atproto.server.deleteAccount' => json => {
  did      => $did,
  password => ('x' x 513),
  token    => $token->{token},
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest')
  ->json_is('/message' => 'Invalid password length.');

$t->post_ok('/xrpc/com.atproto.server.deleteAccount' => json => {
  did      => 'did:web:example.test:users:missing',
  password => 'hunter22',
  token    => $token->{token},
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest')
  ->json_is('/message' => 'account not found');

$t->post_ok('/xrpc/com.atproto.server.deleteAccount' => json => {
  did      => $did,
  password => 'hunter22',
  token    => $token->{token},
})->status_is(200)
  ->json_is({});

ok(defined $app->store->get_account_by_did($did)->{deleted_at}, 'deleteAccount marks the account deleted');

$t->get_ok('/xrpc/com.atproto.server.getSession' => {
  Authorization => "Bearer $access",
})->status_is(401);

$t->post_ok('/xrpc/com.atproto.server.createSession' => json => {
  identifier => 'alice.example.test',
  password   => 'hunter22',
})->status_is(401)
  ->json_is('/error' => 'AuthRequired');

$t->post_ok('/xrpc/com.atproto.server.deleteAccount' => json => {
  did      => $did,
  password => 'hunter22',
  token    => $token->{token},
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest')
  ->json_is('/message' => 'account not found');

done_testing;
