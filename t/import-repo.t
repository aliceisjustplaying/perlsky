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
    accepting_imports     => 1,
    jwt_secret            => 'import-secret',
    admin_password        => 'admin-secret',
    data_dir              => File::Spec->catdir($tmp, 'data'),
    db_path               => File::Spec->catfile($tmp, 'perlds.sqlite'),
  },
);

my $t = Test::Mojo->new($app);

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'alice.example.test',
  email    => 'alice@example.test',
  password => 'hunter22',
})->status_is(200);

my $created = $t->tx->res->json;
my $did     = $created->{did};
my $access  = $created->{accessJwt};

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'before-import',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'state before import',
    createdAt => '2026-03-10T00:00:00Z',
  },
})->status_is(200);

$t->get_ok('/xrpc/com.atproto.sync.getRepo' => form => {
  did => $did,
})->status_is(200);
my $snapshot = $t->tx->res->body;

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'after-import',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'state after import',
    createdAt => '2026-03-10T00:00:01Z',
  },
})->status_is(200);

$t->get_ok('/xrpc/com.atproto.repo.listRecords' => form => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
})->status_is(200);
is(scalar @{ $t->tx->res->json->{records} || [] }, 2, 'repo contains the extra write before import');

$t->post_ok('/xrpc/com.atproto.repo.importRepo' => {
  Authorization => "Bearer $access",
  'Content-Type' => 'application/vnd.ipld.car',
} => $snapshot)->status_is(200);

$t->get_ok('/xrpc/com.atproto.repo.listRecords' => form => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
})->status_is(200);

my $records = $t->tx->res->json->{records} || [];
is(scalar @$records, 1, 'importRepo restores the earlier repo snapshot');
is($records->[0]{uri}, "at://$did/app.bsky.feed.post/before-import", 'imported repo keeps the earlier record URI');
is($records->[0]{value}{text}, 'state before import', 'imported repo restores the earlier record body');

done_testing;
