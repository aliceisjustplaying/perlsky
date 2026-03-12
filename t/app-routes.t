use v5.34;
use warnings;

use Config ();
use File::Path qw(remove_tree);
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

my $root   = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $tmp    = File::Spec->catdir($root, 'data', 'tmp-tests', 'app-routes');
remove_tree($tmp) if -d $tmp;
my $config = {
  host                  => '127.0.0.1',
  port                  => 7755,
  base_url              => 'http://127.0.0.1:7755',
  hostname              => 'localhost',
  service_did_method    => 'did:web',
  service_handle_domain => 'localhost',
  invite_code_required  => 0,
  jwt_secret            => 'test-secret',
  admin_password        => 'admin-secret',
  data_dir              => $tmp,
  db_path               => File::Spec->catfile($tmp, 'perlsky.sqlite'),
};
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

$t->get_ok('/xrpc/_health')
  ->status_is(200)
  ->json_is('/service' => 'perlsky')
  ->json_has('/ok');

$t->get_ok('/xrpc/com.atproto.server.describeServer')
  ->status_is(200)
  ->json_is('/availableUserDomains/0' => 'localhost')
  ->json_like('/did' => qr/\Adid:web:/);

$t->get_ok('/.well-known/oauth-protected-resource')
  ->status_is(200)
  ->json_is('/resource' => 'http://127.0.0.1:7755')
  ->json_is('/authorization_servers/0' => 'http://127.0.0.1:7755');

$t->get_ok('/.well-known/oauth-authorization-server')
  ->status_is(200)
  ->json_is('/issuer' => 'http://127.0.0.1:7755')
  ->json_is('/authorization_endpoint' => 'http://127.0.0.1:7755/oauth/authorize')
  ->json_is('/token_endpoint' => 'http://127.0.0.1:7755/oauth/token')
  ->json_is('/pushed_authorization_request_endpoint' => 'http://127.0.0.1:7755/oauth/par');

my $suffix = time . int(rand(1_000_000));
my $routeprobe_handle = "routeprobe-$suffix.localhost";

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => $routeprobe_handle,
  email    => "routeprobe-$suffix\@example.com",
  password => 'hunter42',
})->status_is(200);

my $routeprobe_did = $t->tx->res->json->{did};

$t->get_ok('/.well-known/atproto-did' => { Host => $routeprobe_handle })
  ->status_is(200)
  ->content_type_like(qr{text/plain})
  ->content_is($routeprobe_did);

$t->get_ok('/.well-known/atproto-did' => { Host => 'missing.localhost' })
  ->status_is(404);

$t->get_ok("/_allow-cert?domain=$routeprobe_handle")
  ->status_is(200)
  ->content_is('ok');

$t->get_ok('/_allow-cert?domain=localhost')
  ->status_is(200)
  ->content_is('ok');

$t->get_ok('/_allow-cert?domain=example.com')
  ->status_is(403);

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => json => {
  repo       => $routeprobe_did,
  collection => 'app.bsky.feed.post',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'auth required',
    createdAt => '2026-03-10T00:00:00Z',
  },
})->status_is(401)
  ->json_is('/error' => 'AuthRequired');

$t->websocket_ok('/xrpc/com.atproto.sync.subscribeRepos')
  ->finish_ok;

done_testing;
