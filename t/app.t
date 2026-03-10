use v5.34;
use warnings;

use Config ();
use FindBin qw($Bin);
use File::Spec;
use Test2::V0;

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
my $config = File::Spec->catfile($root, 'etc', 'perlds.example.json');
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

$t->get_ok('/xrpc/com.atproto.server.describeServer')
  ->status_is(200)
  ->json_is('/did' => 'did:web:127.0.0.1%3A7755')
  ->json_is('/availableUserDomains/0' => 'localhost');

$t->get_ok('/xrpc/com.atproto.identity.resolveHandle?handle=localhost')
  ->status_is(200)
  ->json_is('/did' => 'did:web:127.0.0.1%3A7755');

$t->get_ok('/xrpc/com.atproto.identity.resolveDid?did=did:web:127.0.0.1%3A7755')
  ->status_is(200)
  ->json_is('/didDoc/id' => 'did:web:127.0.0.1%3A7755');

$t->post_ok('/xrpc/com.atproto.server.createSession' => json => { identifier => 'alice', password => 'pw' })
  ->status_is(401)
  ->json_is('/error' => 'AuthRequired');

done_testing;
