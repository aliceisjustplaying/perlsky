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
use ATProto::PDS::Repo::CAR qw(read_car);

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
    db_path               => File::Spec->catfile($tmp, 'perlsky.sqlite'),
  },
);

my $t = Test::Mojo->new($app);
my $admin_auth = 'Basic YWRtaW46YWRtaW4tc2VjcmV0';

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'alice.example.test',
  email    => 'alice@example.test',
  password => 'hunter22',
})->status_is(200);

my $session = $t->tx->res->json;
my $did     = $session->{did};
my $access  = $session->{accessJwt};

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
my $blocks_car = read_car($t->tx->res->body);
is_deeply($blocks_car->{roots}, [], 'sync.getBlocks returns a rootless CAR');
ok(
  scalar(grep { $_->{cid}->to_string eq $latest->{cid} } @{ $blocks_car->{blocks} || [] }),
  'sync.getBlocks returns the requested repo-scoped block',
);

$t->post_ok('/xrpc/com.atproto.repo.uploadBlob' => {
  Authorization => "Bearer $access",
  'Content-Type' => 'text/plain',
} => 'blob-bytes')->status_is(200);

my $blob = $t->tx->res->json->{blob};
my $blob_cid = $blob->{ref}{'$link'};

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'com.example.record',
  rkey       => 'missing-blob-ref',
  record     => {
    '$type' => 'com.example.record',
    note    => 'blob reference for sync/blob surface listing',
    image   => $blob,
  },
})->status_is(200);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.getBlob')->query(
  did => $did,
  cid => $blob_cid,
))->status_is(200)
  ->header_is('X-Content-Type-Options' => 'nosniff')
  ->header_like('Content-Disposition' => qr/\Aattachment; filename="/)
  ->header_is('Content-Security-Policy' => "default-src 'none'; sandbox")
  ->content_type_is('text/plain')
  ->content_is('blob-bytes');

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'bob.example.test',
  email    => 'bob@example.test',
  password => 'hunter22',
})->status_is(200);

my $second = $t->tx->res->json;
my $second_did = $second->{did};
my $second_access = $second->{accessJwt};

$t->post_ok('/xrpc/com.atproto.repo.uploadBlob' => {
  Authorization => "Bearer $second_access",
  'Content-Type' => 'text/plain',
} => 'blob-bytes')->status_is(200)
  ->json_is('/blob/ref/$link' => $blob_cid);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.listBlobs')->query(
  did => $did,
))->status_is(200)
  ->json_is('/cids/0' => $blob_cid);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.listBlobs')->query(
  did => $second_did,
))->status_is(200)
  ->json_is('/cids' => []);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.getBlocks')->query(
  did  => $second_did,
  cids => $latest->{cid},
))->status_is(400)
  ->json_is('/error' => 'InvalidRequest')
  ->json_like('/message' => qr/\Q$latest->{cid}\E/);

$t->post_ok('/xrpc/com.atproto.repo.uploadBlob' => {
  Authorization => "Bearer $access",
  'Content-Type' => 'text/plain',
} => 'blob-two')->status_is(200);

my $blob_two_cid = $t->tx->res->json->{blob}{ref}{'$link'};
my @sorted_blob_cids = sort ($blob_cid, $blob_two_cid);

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'com.example.record',
  rkey       => 'second-sync-blob-ref',
  record     => {
    '$type' => 'com.example.record',
    note    => 'second blob reference for sync/blob surface listing',
    image   => {
      '$type'    => 'blob',
      ref        => { '$link' => $blob_two_cid },
      mimeType   => 'text/plain',
      size       => length('blob-two'),
    },
  },
})->status_is(200);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.listBlobs')->query(
  did   => $did,
  limit => 1,
))->status_is(200)
  ->json_is('/cids/0' => $sorted_blob_cids[0])
  ->json_is('/cursor' => $sorted_blob_cids[0]);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.listBlobs')->query(
  did    => $did,
  limit  => 1,
  cursor => $sorted_blob_cids[0],
))->status_is(200)
  ->json_is('/cids/0' => $sorted_blob_cids[1]);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.getBlob')->query(
  did => $second_did,
  cid => $blob_cid,
))->status_is(400)
  ->json_is('/error' => 'InvalidRequest');

my @since_sorted_blob_cids = sort ($blob_cid, $blob_two_cid);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.listBlobs')->query(
  did   => $did,
  since => $latest->{rev},
))->status_is(200)
  ->json_is('/cids/0' => $since_sorted_blob_cids[0])
  ->json_is('/cids/1' => $since_sorted_blob_cids[1]);

done_testing;
