use v5.34;
use warnings;

use Config ();
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
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
my $config = File::Spec->catfile($root, 'etc', 'perlsky.example.json');
my $t = Test::Mojo->new(ATProto::PDS->new(
  project_root => $root,
  settings     => {
    base_url              => 'http://127.0.0.1:7755',
    service_did_method    => 'did:web',
    service_handle_domain => 'localhost',
    jwt_secret            => 'test-secret',
  },
));

$t->get_ok('/_health')
  ->status_is(200)
  ->json_has('/ok');

$t->get_ok('/xrpc/_health')
  ->status_is(200)
  ->json_has('/ok');

$t->get_ok('/xrpc/com.atproto.server.describeServer')
  ->status_is(200)
  ->json_is('/did' => 'did:web:127.0.0.1%3A7755')
  ->json_is('/availableUserDomains/0' => 'localhost');

$t->get_ok('/xrpc/com.atproto.identity.resolveHandle?handle=localhost')
  ->status_is(200)
  ->json_is('/did' => 'did:web:127.0.0.1%3A7755');

$t->get_ok('/xrpc/com.atproto.identity.resolveHandle?handle=not_a_handle')
  ->status_is(400)
  ->json_is('/error' => 'InvalidRequest');

$t->get_ok('/xrpc/com.atproto.identity.resolveDid?did=did:web:127.0.0.1%3A7755')
  ->status_is(200)
  ->json_is('/didDoc/id' => 'did:web:127.0.0.1%3A7755');

$t->post_ok('/xrpc/com.atproto.server.createSession' => json => { identifier => 'alice', password => 'pw' })
  ->status_is(401)
  ->json_is('/error' => 'AuthenticationRequired');

my $tmp = tempdir(CLEANUP => 1);
my $fresh = Test::Mojo->new(ATProto::PDS->new(
  project_root => $root,
  settings     => {
    base_url              => 'http://127.0.0.1:7755',
    service_did_method    => 'did:web',
    service_handle_domain => 'localhost',
    jwt_secret            => 'test-secret',
    data_dir              => $tmp,
    db_path               => File::Spec->catfile($tmp, 'perlsky.sqlite'),
  },
));

$fresh->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'alice.localhost',
  email    => 'alice@example.test',
  password => 'hunter22',
})->status_is(200);

my $user_did = $fresh->tx->res->json->{did};

$fresh->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'toolong.localhost',
  email    => 'toolong@example.test',
  password => ('x' x 257),
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest')
  ->json_is('/message' => 'Password too long. Maximum length is 256 characters.');

$fresh->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'bademail.localhost',
  email    => 'not-an-email',
  password => 'hunter22',
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest')
  ->json_is('/message' => 'This email address is not supported, please use a different email.');

$fresh->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'dupemail.localhost',
  email    => 'ALICE@example.test',
  password => 'hunter22',
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest')
  ->json_is('/message' => 'Email already taken: ALICE@example.test');

$fresh->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'ALICE.localhost',
  email    => 'another@example.test',
  password => 'hunter22',
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest')
  ->json_is('/message' => 'Handle already taken: alice.localhost');

$fresh->get_ok("/xrpc/com.atproto.identity.resolveHandle?handle=alice.localhost")
  ->status_is(200)
  ->json_is('/did' => $user_did);

$fresh->get_ok("/xrpc/com.atproto.identity.resolveDid?did=$user_did")
  ->status_is(400)
  ->json_is('/error' => 'InvalidRequest');

$fresh->get_ok("/xrpc/com.atproto.identity.resolveIdentity?identifier=$user_did")
  ->status_is(400)
  ->json_is('/error' => 'InvalidRequest');

$fresh->get_ok('/xrpc/com.atproto.identity.resolveIdentity?identifier=alice.localhost')
  ->status_is(400)
  ->json_is('/error' => 'InvalidRequest');

my $missing_secret_error = eval {
  ATProto::PDS->new(
    project_root => $root,
    settings     => {
      base_url              => 'http://127.0.0.1:7755',
      service_did_method    => 'did:web',
      service_handle_domain => 'localhost',
    },
  );
  undef;
};
like("$@", qr/jwt_secret must be configured/, 'startup fails closed without jwt_secret');

my $legacy_secret_error = eval {
  ATProto::PDS->new(
    project_root => $root,
    settings     => {
      base_url              => 'http://127.0.0.1:7755',
      service_did_method    => 'did:web',
      service_handle_domain => 'localhost',
      jwt_secret            => 'perlsky-dev-secret',
    },
  );
  undef;
};
like("$@", qr/jwt_secret must not use the legacy perlsky-dev-secret default/, 'startup fails closed on the legacy dev jwt secret');

done_testing;
