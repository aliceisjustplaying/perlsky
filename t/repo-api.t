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

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $tmp  = File::Spec->catdir($root, 'data', 'tmp-tests', 'repo-api');
remove_tree($tmp) if -d $tmp;

my $t = Test::Mojo->new(ATProto::PDS->new(
  project_root => $root,
  settings     => {
    base_url              => 'http://127.0.0.1:7755',
    service_did_method    => 'did:web',
    service_handle_domain => 'localhost',
    jwt_secret            => 'repo-secret',
    data_dir              => $tmp,
    db_path               => File::Spec->catfile($tmp, 'perlsky.sqlite'),
  },
));

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'repo-owner',
  email    => 'repo@example.com',
  password => 'password123',
})->status_is(200);

my $session = $t->tx->res->json;
my $did     = $session->{did};
my $access  = $session->{accessJwt};
my $refresh = $session->{refreshJwt};

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => { Authorization => "Bearer $access" } => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'first-post',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'hello from perl',
    createdAt => '2026-03-10T00:00:00Z',
  },
})->status_is(200)
  ->json_like('/cid' => qr/\Ab/);

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => { Authorization => "Bearer $refresh" } => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'refresh-post',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'refresh tokens are not access tokens',
    createdAt => '2026-03-10T00:01:00Z',
  },
})->status_is(401)
  ->json_is('/error' => 'InvalidToken');

$t->get_ok("/xrpc/com.atproto.repo.getRecord?repo=$did&collection=app.bsky.feed.post&rkey=first-post")
  ->status_is(200)
  ->json_is('/value/text' => 'hello from perl');

$t->get_ok("/xrpc/com.atproto.repo.listRecords?repo=$did&collection=app.bsky.feed.post")
  ->status_is(200)
  ->json_is('/records/0/value/text' => 'hello from perl');

$t->get_ok("/xrpc/com.atproto.sync.getLatestCommit?did=$did")
  ->status_is(200)
  ->json_like('/cid' => qr/\Ab/)
  ->json_has('/rev');

$t->get_ok("/xrpc/com.atproto.sync.getRepoStatus?did=$did")
  ->status_is(200)
  ->json_is('/did' => $did)
  ->json_has('/active');

$t->get_ok('/xrpc/com.atproto.sync.listRepos')
  ->status_is(200)
  ->json_is('/repos/0/did' => $did);

$t->get_ok("/xrpc/com.atproto.sync.getRepo?did=$did")
  ->status_is(200)
  ->content_type_like(qr{application/vnd\.ipld\.car})
  ->content_like(qr/.+/s);

$t->post_ok('/xrpc/com.atproto.repo.deleteRecord' => { Authorization => "Bearer $access" } => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'first-post',
})->status_is(200);

$t->get_ok("/xrpc/com.atproto.repo.getRecord?repo=$did&collection=app.bsky.feed.post&rkey=first-post")
  ->status_is(404)
  ->json_is('/error' => 'RecordNotFound');

done_testing;
