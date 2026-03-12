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
my $bypass_tmp = tempdir(CLEANUP => 1);

my $app = ATProto::PDS->new(
  project_root => $root,
  settings => {
    base_url              => 'http://127.0.0.1:7755',
    service_handle_domain => 'example.test',
    service_did_method    => 'did:web',
    jwt_secret            => 'email-confirm-secret',
    testing_auto_confirm_email => 0,
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

$t->post_ok('/xrpc/com.atproto.server.createAppPassword' => {
  Authorization => "Bearer $alice->{accessJwt}",
} => json => {
  name => 'email-helper',
})->status_is(200)
  ->json_like('/password' => qr/\w/);

my $alice_app_password = $t->tx->res->json->{password};

$t->post_ok('/xrpc/com.atproto.server.createSession' => json => {
  identifier => 'alice.example.test',
  password   => $alice_app_password,
})->status_is(200);

my $alice_app_session = $t->tx->res->json;

ok(!$alice->{emailConfirmed}, 'new account email stays unconfirmed when testing auto-confirm is disabled');

$t->post_ok('/xrpc/com.atproto.server.requestEmailUpdate' => {
  Authorization => "Bearer $alice->{accessJwt}",
} => json => {})->status_is(200);
ok(!$t->tx->res->json->{tokenRequired}, 'unconfirmed email does not require an update token');

$t->post_ok('/xrpc/com.atproto.server.requestEmailConfirmation' => {
  Authorization => "Bearer $alice->{accessJwt}",
} => json => {})->status_is(200);

$t->post_ok('/xrpc/com.atproto.server.requestEmailConfirmation' => {
  Authorization => "Bearer $alice_app_session->{accessJwt}",
} => json => {})->status_is(400)
  ->json_is('/error' => 'InvalidToken')
  ->json_is('/message' => 'Bad token scope');

my $token = $app->store->latest_action_token(
  did     => $alice->{did},
  purpose => 'email_confirm',
);
ok($token, 'email confirmation token was created');

$t->post_ok('/xrpc/com.atproto.server.requestEmailUpdate' => {
  Authorization => "Bearer $alice_app_session->{accessJwt}",
} => json => {})->status_is(400)
  ->json_is('/error' => 'InvalidToken')
  ->json_is('/message' => 'Bad token scope');

$t->post_ok('/xrpc/com.atproto.server.confirmEmail' => json => {
  email => 'ALICE@example.test',
  token => $token->{token},
})->status_is(401)
  ->json_is('/error' => 'AuthRequired');

$app->store->update_account(
  $alice->{did},
  email => 'alice+new@example.test',
);

$t->post_ok('/xrpc/com.atproto.server.confirmEmail' => {
  Authorization => "Bearer $alice->{accessJwt}",
} => json => {
  email => 'ALICE@example.test',
  token => $token->{token},
})->status_is(400)
  ->json_is('/error' => 'InvalidEmail');

$t->post_ok('/xrpc/com.atproto.server.confirmEmail' => {
  Authorization => "Bearer $alice_app_session->{accessJwt}",
} => json => {
  email => 'ALICE@example.test',
  token => $token->{token},
})->status_is(400)
  ->json_is('/error' => 'InvalidToken')
  ->json_is('/message' => 'Bad token scope');

ok(
  !defined $app->store->get_account_by_did($alice->{did})->{email_confirmed_at},
  'stale confirmation tokens cannot confirm a changed email address',
);

$t->post_ok('/xrpc/com.atproto.server.updateEmail' => {
  Authorization => "Bearer $alice->{accessJwt}",
} => json => {
  email => 'not-an-email',
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest')
  ->json_is('/message' => 'This email address is not supported, please use a different email.');

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'bob.example.test',
  email    => 'bob@example.test',
  password => 'hunter22',
})->status_is(200);
my $bob = $t->tx->res->json;

$t->post_ok('/xrpc/com.atproto.server.requestEmailConfirmation' => {
  Authorization => "Bearer $bob->{accessJwt}",
} => json => {})->status_is(200);

my $bob_token = $app->store->latest_action_token(
  did     => $bob->{did},
  purpose => 'email_confirm',
);
ok($bob_token, 'case-insensitive confirmation flow also issues a token');

$t->post_ok('/xrpc/com.atproto.server.confirmEmail' => {
  Authorization => "Bearer $bob->{accessJwt}",
} => json => {
  email => 'BOB@example.test',
  token => $bob_token->{token},
})->status_is(200)
  ->content_is(q());

ok(
  defined $app->store->get_account_by_did($bob->{did})->{email_confirmed_at},
  'email confirmation accepts case-insensitive email matches',
);

my $bypass_app = ATProto::PDS->new(
  project_root => $root,
  settings => {
    base_url              => 'http://127.0.0.1:7755',
    service_handle_domain => 'example.test',
    service_did_method    => 'did:web',
    jwt_secret            => 'email-confirm-bypass-secret',
    testing_auto_confirm_email => 0,
    testing_allow_unauthenticated_email_confirm => 1,
    data_dir              => $bypass_tmp,
    db_path               => File::Spec->catfile($bypass_tmp, 'perlsky.sqlite'),
  },
);
my $bypass_t = Test::Mojo->new($bypass_app);

$bypass_t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'carol.example.test',
  email    => 'carol@example.test',
  password => 'hunter22',
})->status_is(200);
my $carol = $bypass_t->tx->res->json;

$bypass_t->post_ok('/xrpc/com.atproto.server.requestEmailConfirmation' => {
  Authorization => "Bearer $carol->{accessJwt}",
} => json => {})->status_is(200);
my $carol_token = $bypass_app->store->latest_action_token(
  did     => $carol->{did},
  purpose => 'email_confirm',
);
ok($carol_token, 'testing bypass app also issues a confirmation token');

$bypass_t->post_ok('/xrpc/com.atproto.server.confirmEmail' => json => {
  email => 'carol@example.test',
  token => $carol_token->{token},
})->status_is(200)
  ->content_is(q());

$bypass_t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'noemail.example.test',
  password => 'hunter22',
})->status_is(200);
my $noemail = $bypass_t->tx->res->json;

$bypass_t->post_ok('/xrpc/com.atproto.server.requestEmailConfirmation' => {
  Authorization => "Bearer $noemail->{accessJwt}",
} => json => {})->status_is(400)
  ->json_is('/error' => 'InvalidRequest')
  ->json_is('/message' => 'account does not have an email address');

$bypass_t->post_ok('/xrpc/com.atproto.server.requestEmailUpdate' => {
  Authorization => "Bearer $noemail->{accessJwt}",
} => json => {})->status_is(400)
  ->json_is('/error' => 'InvalidRequest')
  ->json_is('/message' => 'account does not have an email address');

$bypass_t->post_ok('/xrpc/com.atproto.server.requestAccountDelete' => {
  Authorization => "Bearer $noemail->{accessJwt}",
} => json => {})->status_is(400)
  ->json_is('/error' => 'InvalidRequest')
  ->json_is('/message' => 'account does not have an email address');

done_testing;
