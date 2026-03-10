use v5.34;
use warnings;

use Config ();
use File::Spec;
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
use ATProto::PDS::Config qw(load_config);

my $root   = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $config = load_config(File::Spec->catfile($root, 'etc', 'perlsky.example.json'));
my $t      = Test::Mojo->new(
  ATProto::PDS->new(
    project_root => $root,
    settings     => $config,
  ),
);

$t->get_ok('/_health')
  ->status_is(200)
  ->json_is('/service' => 'perlsky')
  ->json_has('/ok');

$t->get_ok('/xrpc/com.atproto.server.describeServer')
  ->status_is(200)
  ->json_is('/availableUserDomains/0' => 'localhost')
  ->json_like('/did' => qr/\Adid:web:/);

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'routeprobe.localhost',
  email    => 'routeprobe@example.com',
  password => 'hunter42',
})->status_is(200);

my $routeprobe_did = $t->tx->res->json->{did};

$t->get_ok('/.well-known/atproto-did' => { Host => 'routeprobe.localhost' })
  ->status_is(200)
  ->content_type_like(qr{text/plain})
  ->content_is($routeprobe_did);

$t->get_ok('/.well-known/atproto-did' => { Host => 'missing.localhost' })
  ->status_is(404);

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => json => {})
  ->status_is(404)
  ->json_is('/error' => 'RepoNotFound');

$t->websocket_ok('/xrpc/com.atproto.sync.subscribeRepos')
  ->finish_ok;

done_testing;
