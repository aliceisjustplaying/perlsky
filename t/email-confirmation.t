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
    base_url              => 'http://127.0.0.1:7755',
    service_handle_domain => 'example.test',
    service_did_method    => 'did:web',
    jwt_secret            => 'email-confirm-secret',
    data_dir              => $tmp,
    db_path               => File::Spec->catfile($tmp, 'perlsky.sqlite'),
  },
);

my $t = Test::Mojo->new($app);

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'alice.example.test',
  email    => 'alice@example.test',
  password => 'hunter22',
})->status_is(200);
my $alice = $t->tx->res->json;

$app->store->update_account($alice->{did}, email_confirmed_at => undef);

$t->post_ok('/xrpc/com.atproto.server.requestEmailConfirmation' => {
  Authorization => "Bearer $alice->{accessJwt}",
} => json => {})->status_is(200);

my $token = $app->store->latest_action_token(
  did     => $alice->{did},
  purpose => 'email_confirm',
);
ok($token, 'email confirmation token was created');

$app->store->update_account(
  $alice->{did},
  email              => 'alice+new@example.test',
  email_confirmed_at => undef,
);

$t->post_ok('/xrpc/com.atproto.server.confirmEmail' => json => {
  email => 'alice@example.test',
  token => $token->{token},
})->status_is(400)
  ->json_is('/error' => 'InvalidEmail');

ok(
  !defined $app->store->get_account_by_did($alice->{did})->{email_confirmed_at},
  'stale confirmation tokens cannot confirm a changed email address',
);

done_testing;
