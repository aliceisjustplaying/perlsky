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
    jwt_secret            => 'missing-blob-secret',
    admin_password        => 'admin-secret',
    data_dir              => File::Spec->catdir($tmp, 'data'),
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
    note    => 'blob reference for missing-blob listing',
    image   => $blob,
  },
})->status_is(200);

$t->post_ok('/xrpc/com.atproto.repo.uploadBlob' => {
  Authorization => "Bearer $access",
  'Content-Type' => 'text/plain',
} => 'nested-blob-bytes')->status_is(200);

my $nested_blob = $t->tx->res->json->{blob};
my $nested_blob_cid = $nested_blob->{ref}{'$link'};

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'com.example.record',
  rkey       => 'nested-missing-blob-ref',
  record     => {
    '$type'      => 'com.example.record',
    note         => 'nested blob reference for missing-blob listing',
    attachments  => [{
      kind  => 'image',
      image => $nested_blob,
    }],
  },
})->status_is(200);

my $nested_record_uri = $t->tx->res->json->{uri};

for my $cid ($blob_cid, $nested_blob_cid) {
  $app->store->dbh->do(
    q{DELETE FROM blob_owners WHERE cid = ?},
    undef,
    $cid,
  );
  $app->store->dbh->do(
    q{DELETE FROM blobs WHERE cid = ?},
    undef,
    $cid,
  );
}

my %expected_missing = (
  $blob_cid        => "at://$did/com.example.record/missing-blob-ref",
  $nested_blob_cid => $nested_record_uri,
);
my @missing_cids = sort keys %expected_missing;

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.repo.listMissingBlobs')->query(
  limit => 1,
), {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/blobs/0/cid' => $missing_cids[0])
  ->json_is('/blobs/0/recordUri' => $expected_missing{$missing_cids[0]})
  ->json_is('/cursor' => $missing_cids[0]);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.repo.listMissingBlobs')->query(
  limit  => 1,
  cursor => $missing_cids[0],
), {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/blobs/0/cid' => $missing_cids[1])
  ->json_is('/blobs/0/recordUri' => $expected_missing{$missing_cids[1]})
  ->json_is('/cursor' => $missing_cids[1]);

done_testing;
