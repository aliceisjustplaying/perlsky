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
use JSON::PP ();
use Mojo::URL;
use ATProto::PDS;

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $tmp  = tempdir(CLEANUP => 1);

my $app = ATProto::PDS->new(
  project_root => $root,
  settings => {
    base_url              => 'http://127.0.0.1:7755',
    service_handle_domain => 'example.test',
    service_did_method    => 'did:web',
    jwt_secret            => 'surface-secret',
    admin_password        => 'admin-secret',
    data_dir              => File::Spec->catdir($tmp, 'data'),
    db_path               => File::Spec->catfile($tmp, 'perlds.sqlite'),
  },
);

my $t = Test::Mojo->new($app);

for my $endpoint (@{ $app->endpoint_catalog }) {
  ok($app->api_registry->handler_for($endpoint->{id}), "$endpoint->{id} has a handler");
}

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.lexicon.resolveLexicon')->query(
  nsid => 'com.atproto.server.createSession',
))->status_is(200)
  ->json_is('/schema/id' => 'com.atproto.server.createSession')
  ->json_has('/cid')
  ->json_has('/uri');

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.temp.checkHandleAvailability')->query(
  handle => 'alice.example.test',
))->status_is(200)
  ->json_is('/handle' => 'alice.example.test')
  ->json_has('/result');

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'alice.example.test',
  email    => 'alice@example.test',
  password => 'hunter22',
})->status_is(200);

my $session = $t->tx->res->json;
my $did     = $session->{did};
my $access  = $session->{accessJwt};

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.temp.checkHandleAvailability')->query(
  handle => 'alice.example.test',
))->status_is(200)
  ->json_has('/result/suggestions/0/handle');

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => { Authorization => "Bearer $access" } => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'hello-world',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'hello surface',
    createdAt => '2026-03-10T00:00:00Z',
  },
})->status_is(200);

my $record = $t->tx->res->json;
my $record_uri = $record->{uri};
my $record_cid = $record->{cid};

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.listReposByCollection')->query(
  collection => 'app.bsky.feed.post',
))->status_is(200)
  ->json_is('/repos/0/did' => $did);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.getLatestCommit')->query(
  did => $did,
))->status_is(200);

my $latest = $t->tx->res->json;

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.getBlocks')->query(
  did  => $did,
  cids => $latest->{cid},
))->status_is(200)
  ->content_type_like(qr{application/vnd\.ipld\.car})
  ->content_like(qr/.+/s);

$t->post_ok('/xrpc/com.atproto.repo.uploadBlob' => {
  Authorization => "Bearer $access",
  'Content-Type' => 'text/plain',
} => 'blob-bytes')->status_is(200);

my $blob = $t->tx->res->json->{blob};
my $blob_cid = $blob->{ref}{'$link'};

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.getBlob')->query(
  did => $did,
  cid => $blob_cid,
))->status_is(200)
  ->content_type_is('text/plain')
  ->content_is('blob-bytes');

$t->get_ok('/xrpc/com.atproto.server.checkAccountStatus' => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_has('/activated')
  ->json_has('/repoCommit')
  ->json_has('/repoRev')
  ->json_has('/repoBlocks')
  ->json_has('/indexedRecords')
  ->json_has('/expectedBlobs')
  ->json_has('/importedBlobs');

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.admin.getAccountInfo')->query(
  did => $did,
) => {
  Authorization => 'Bearer admin-secret',
})->status_is(200)
  ->json_is('/handle' => 'alice.example.test');

$t->post_ok('/xrpc/com.atproto.admin.updateSubjectStatus' => {
  Authorization => 'Bearer admin-secret',
} => json => {
  subject  => { uri => $record_uri, cid => $record_cid },
  takedown => { applied => JSON::PP::true },
})->status_is(200);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.label.queryLabels')->query(
  uriPatterns => $record_uri,
))->status_is(200)
  ->json_is('/labels/0/val' => '!hide')
  ->json_is('/labels/0/uri' => $record_uri);

done_testing;
