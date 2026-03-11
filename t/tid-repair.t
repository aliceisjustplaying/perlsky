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
use ATProto::PDS::Util::TID qw(is_valid_tid next_tid repair_tid);

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $tmp  = tempdir(CLEANUP => 1);

my $legacy_tid = '3mgqt45pjds0s';
is(repair_tid($legacy_tid), '3mgqt45pjds2s', 'legacy zero-padded TID repairs losslessly');
ok(!is_valid_tid($legacy_tid), 'legacy zero-padded TID is invalid');
ok(is_valid_tid(repair_tid($legacy_tid)), 'repaired legacy TID is valid');

my $next = next_tid($legacy_tid);
ok(is_valid_tid($next), 'next_tid emits a valid TID after an invalid predecessor');
ok($next gt repair_tid($legacy_tid), 'next_tid stays monotonic across repaired predecessor');

my $app = ATProto::PDS->new(
  project_root => $root,
  settings     => {
    base_url              => 'http://127.0.0.1:7755',
    service_handle_domain => 'example.test',
    service_did_method    => 'did:web',
    jwt_secret            => 'tid-repair-secret',
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
my $account = $app->store->get_account_by_did($did);

my $post_rkey  = '3mgqt45piek0s';
my $reply_rkey = '3mgqt45pjds0s';

$app->repo_manager->apply_writes($account, [
  {
    action     => 'create',
    collection => 'app.bsky.feed.post',
    rkey       => $post_rkey,
    record     => {
      '$type'   => 'app.bsky.feed.post',
      text      => 'legacy tid root',
      createdAt => '2026-03-11T02:00:00Z',
    },
  },
  {
    action     => 'create',
    collection => 'app.bsky.feed.post',
    rkey       => $reply_rkey,
    record     => {
      '$type'   => 'app.bsky.feed.post',
      text      => 'legacy tid reply',
      createdAt => '2026-03-11T02:00:01Z',
      reply     => {
        root   => { uri => "at://$did/app.bsky.feed.post/$post_rkey" },
        parent => { uri => "at://$did/app.bsky.feed.post/$post_rkey" },
      },
    },
  },
]);

ok($app->store->get_record($did, 'app.bsky.feed.post', $post_rkey), 'legacy root post exists before repair');
ok($app->store->get_record($did, 'app.bsky.feed.post', $reply_rkey), 'legacy reply post exists before repair');

my $repair = $app->repo_manager->repair_invalid_tids($account);
ok($repair->{changed}, 'repair migrates the repo');
is($repair->{repaired_paths}, 2, 'repair updated both legacy TID record keys');

my $fixed_post_rkey  = repair_tid($post_rkey);
my $fixed_reply_rkey = repair_tid($reply_rkey);
ok($app->store->get_record($did, 'app.bsky.feed.post', $fixed_post_rkey), 'root post moved to repaired rkey');
ok($app->store->get_record($did, 'app.bsky.feed.post', $fixed_reply_rkey), 'reply post moved to repaired rkey');
ok(!$app->store->get_record($did, 'app.bsky.feed.post', $post_rkey), 'old root post rkey no longer exists');
ok(!$app->store->get_record($did, 'app.bsky.feed.post', $reply_rkey), 'old reply post rkey no longer exists');

my $reply = $app->store->get_record($did, 'app.bsky.feed.post', $fixed_reply_rkey);
is(
  $reply->{value}{reply}{root}{uri},
  "at://$did/app.bsky.feed.post/$fixed_post_rkey",
  'repair rewrites self-referential root URIs',
);
is(
  $reply->{value}{reply}{parent}{uri},
  "at://$did/app.bsky.feed.post/$fixed_post_rkey",
  'repair rewrites self-referential parent URIs',
);

my $latest = $app->store->get_latest_commit($did);
ok(is_valid_tid($latest->{rev}), 'latest repo rev is valid after repair');

done_testing;
