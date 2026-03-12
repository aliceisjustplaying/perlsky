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
    jwt_secret                 => 'password-reset-secret',
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

$t->post_ok('/xrpc/com.atproto.server.requestPasswordReset' => json => {
  email => 'missing@example.test',
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest')
  ->json_is('/message' => 'account does not have an email address');

$t->post_ok('/xrpc/com.atproto.server.requestPasswordReset' => json => {
  email => 'alice@example.test',
})->status_is(200)
  ->json_is({});

my $token = $app->store->latest_action_token(
  purpose => 'password_reset',
);
ok($token && $token->{token}, 'requestPasswordReset issues a password reset token');

$t->post_ok('/xrpc/com.atproto.server.resetPassword' => json => {
  token    => $token->{token},
  password => 'new-hunter22',
})->status_is(200)
  ->json_is({});

$t->post_ok('/xrpc/com.atproto.server.createSession' => json => {
  identifier => 'alice.example.test',
  password   => 'hunter22',
})->status_is(401)
  ->json_is('/error' => 'AuthRequired');

$t->post_ok('/xrpc/com.atproto.server.createSession' => json => {
  identifier => 'alice.example.test',
  password   => 'new-hunter22',
})->status_is(200)
  ->json_has('/accessJwt');

done_testing;
