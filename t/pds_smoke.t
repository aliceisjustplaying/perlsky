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
use ATProto::PDS::Repo::CAR qw(read_car);

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $tmp  = tempdir(CLEANUP => 1);

my $app = ATProto::PDS->new(
  project_root => $root,
  settings => {
    base_url              => 'http://127.0.0.1:7755',
    service_handle_domain => 'example.test',
    service_did_method    => 'did:web',
    jwt_secret            => 'smoke-secret',
    admin_password        => 'admin-secret',
    db_path               => File::Spec->catfile($tmp, 'perlsky.sqlite'),
  },
);

my $t = Test::Mojo->new($app);

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'alice.example.test',
  email    => 'alice@example.test',
  password => 'hunter22',
})->status_is(200);

my $created = $t->tx->res->json;
ok($created->{accessJwt}, 'account creation returns access token');
ok($created->{refreshJwt}, 'account creation returns refresh token');
is($created->{handle}, 'alice.example.test', 'account creation returns normalized handle');

my $access = $created->{accessJwt};
my $did    = $created->{did};

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'bob.example.test',
  email    => 'bob@example.test',
  password => 'hunter23',
})->status_is(200);

my $bob_created = $t->tx->res->json;
my $bob_did     = $bob_created->{did};

$t->get_ok('/xrpc/com.atproto.server.getSession' => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/did', $did);

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.graph.follow',
  rkey       => 'follow-bob',
  record     => {
    '$type'   => 'app.bsky.graph.follow',
    subject   => $bob_did,
    createdAt => '2026-03-10T00:00:00Z',
  },
})->status_is(200)
  ->json_is('/uri', "at://$did/app.bsky.graph.follow/follow-bob");

$t->get_ok("/xrpc/app.bsky.actor.getProfile?actor=$did" => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/did', $did)
  ->json_is('/followsCount', 1)
  ->json_is('/postsCount', 0)
  ->json_hasnt('/followersCount')
  ->json_hasnt('/viewer/knownFollowers');

$t->get_ok("/xrpc/app.bsky.actor.getProfile?actor=$bob_did" => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/did', $bob_did)
  ->json_is('/viewer/following', "at://$did/app.bsky.graph.follow/follow-bob")
  ->json_hasnt('/followersCount');

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'hello from perl',
    createdAt => '2026-03-10T00:00:00Z',
  },
})->status_is(200)
  ->json_has('/uri')
  ->json_has('/cid');
my $record_cid = $t->tx->res->json->{cid};

$t->get_ok('/xrpc/com.atproto.repo.listRecords' => form => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
})->status_is(200)
  ->json_is('/records/0/value/text', 'hello from perl');

$t->get_ok("/xrpc/app.bsky.feed.getAuthorFeed?actor=$did&limit=10" => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/feed/0/post/record/text', 'hello from perl')
  ->json_hasnt('/feed/0/post/bookmarkCount')
  ->json_hasnt('/feed/0/post/replyCount')
  ->json_hasnt('/feed/0/post/likeCount')
  ->json_hasnt('/feed/0/post/repostCount')
  ->json_hasnt('/feed/0/post/quoteCount');

$t->get_ok('/xrpc/com.atproto.sync.getLatestCommit' => form => {
  did => $did,
})->status_is(200)
  ->json_has('/cid')
  ->json_has('/rev');
my $latest_commit_cid = $t->tx->res->json->{cid};

$t->get_ok('/xrpc/com.atproto.sync.getRepo' => form => {
  did => $did,
})->status_is(200);

like($t->tx->res->headers->content_type // '', qr{application/vnd\.ipld\.car}, 'repo export is served as CAR');
my $repo_car = read_car($t->tx->res->body);
is($repo_car->{roots}[0]->to_string, $latest_commit_cid, 'repo export roots the latest commit');
ok(
  scalar(grep { $_->{cid}->to_string eq $record_cid } @{ $repo_car->{blocks} || [] }),
  'repo export includes the created record block',
);

done_testing;
