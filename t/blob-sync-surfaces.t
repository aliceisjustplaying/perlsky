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
    jwt_secret            => 'blob-sync-surface-secret',
    admin_password        => 'admin-secret',
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

my $session = $t->tx->res->json;
my $did     = $session->{did};
my $access  = $session->{accessJwt};

my $blob_tx = $t->ua->build_tx(
  POST => '/xrpc/com.atproto.repo.uploadBlob' => {
    Authorization => "Bearer $access",
    'Content-Type' => 'image/png',
  } => 'blob-bytes',
);
$t->request_ok($blob_tx)->status_is(200);

my $blob = $t->tx->res->json->{blob};
my $blob_cid = $blob->{ref}{'$link'};

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'com.example.attach',
  record     => {
    '$type' => 'com.example.attach',
    blob    => $blob,
  },
})->status_is(200);

$t->get_ok('/xrpc/com.atproto.sync.listBlobs?did=' . $did)
  ->status_is(200)
  ->json_is('/cids/0', $blob_cid);

$t->get_ok('/xrpc/com.atproto.sync.getBlob?did=' . $did . '&cid=' . $blob_cid)
  ->status_is(200);
is($t->tx->res->body, 'blob-bytes', 'blob bytes are served back');
like($t->tx->res->headers->content_type // '', qr{image/png}, 'blob content type preserved');

$t->get_ok('/xrpc/com.atproto.sync.getLatestCommit?did=' . $did)
  ->status_is(200)
  ->json_has('/cid');

my $commit_cid = $t->tx->res->json->{cid};

$t->get_ok('/xrpc/com.atproto.sync.getBlocks?did=' . $did . '&cids=' . $commit_cid)
  ->status_is(200);
like($t->tx->res->headers->content_type // '', qr{application/vnd\.ipld\.car}, 'block export is a CAR');

$t->get_ok('/xrpc/com.atproto.sync.getBlocks?did=' . $did)
  ->status_is(400)
  ->json_is('/error', 'InvalidRequest')
  ->json_is('/message', 'At least one CID is required');

$t->get_ok('/xrpc/com.atproto.sync.getBlocks?did=' . $did . '&cids=bafyreifakecidmismatch')
  ->status_is(400)
  ->json_is('/error', 'InvalidRequest')
  ->json_is('/message', 'Could not find cids: bafyreifakecidmismatch');

$t->get_ok('/xrpc/com.atproto.sync.listBlobs?did=did:web:missing.test')
  ->status_is(400)
  ->json_is('/error', 'RepoNotFound');

$t->get_ok('/xrpc/com.atproto.sync.getBlob?did=did:web:missing.test&cid=' . $blob_cid)
  ->status_is(400)
  ->json_is('/error', 'RepoNotFound');

$t->get_ok('/xrpc/com.atproto.sync.getBlocks?did=did:web:missing.test&cids=' . $commit_cid)
  ->status_is(400)
  ->json_is('/error', 'RepoNotFound');

done_testing;
