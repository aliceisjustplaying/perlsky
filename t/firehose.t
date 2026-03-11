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
use ATProto::PDS::Repo::CAR qw(read_car);
use ATProto::PDS::Repo::DagCbor qw(decode_dag_cbor);
use ATProto::PDS::EventStream qw(decode_frame);

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $tmp  = tempdir(CLEANUP => 1);

my $app = ATProto::PDS->new(
  project_root => $root,
  settings => {
    base_url              => 'http://127.0.0.1:7755',
    service_handle_domain => 'example.test',
    service_did_method    => 'did:web',
    jwt_secret            => 'firehose-secret',
    admin_password        => 'admin-secret',
    data_dir              => File::Spec->catdir($tmp, 'data'),
    db_path               => File::Spec->catfile($tmp, 'perlsky.sqlite'),
  },
);

my $t  = Test::Mojo->new($app);
my $ws = Test::Mojo->new($app);

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'alice.example.test',
  email    => 'alice@example.test',
  password => 'hunter22',
})->status_is(200);

my $session = $t->tx->res->json;
my $did     = $session->{did};
my $access  = $session->{accessJwt};

my $bootstrap = Test::Mojo->new($app);
$bootstrap->websocket_ok('/xrpc/com.atproto.sync.subscribeRepos?cursor=0');

$bootstrap->message_ok('bootstrap identity event arrived');
my $identity = decode_frame($bootstrap->message->[1]);
is($identity->{header}{t}, '#identity', 'bootstrap frame starts with identity');
is($identity->{body}{did}, $did, 'identity event identifies the account');
is($identity->{body}{handle}, 'alice.example.test', 'identity event carries the handle');

$bootstrap->message_ok('bootstrap account event arrived');
my $account_evt = decode_frame($bootstrap->message->[1]);
is($account_evt->{header}{t}, '#account', 'bootstrap account event follows identity');
ok($account_evt->{body}{active}, 'bootstrap account event marks the account active');

$bootstrap->message_ok('bootstrap commit event arrived');
my $bootstrap_commit = decode_frame($bootstrap->message->[1]);
is($bootstrap_commit->{header}{t}, '#commit', 'bootstrap commit event is emitted');
is_deeply($bootstrap_commit->{body}{ops}, [], 'bootstrap commit contains no record ops');
ok(!defined $bootstrap_commit->{body}{since}, 'bootstrap commit since is null');

$bootstrap->message_ok('bootstrap sync event arrived');
my $bootstrap_sync = decode_frame($bootstrap->message->[1]);
is($bootstrap_sync->{header}{t}, '#sync', 'bootstrap sync event is emitted');
is($bootstrap_sync->{body}{did}, $did, 'bootstrap sync identifies the account');
is($bootstrap_sync->{body}{rev}, $bootstrap_commit->{body}{rev}, 'bootstrap sync rev matches the bootstrap commit');
my $bootstrap_sync_car = read_car($bootstrap_sync->{body}{blocks});
is(scalar @{ $bootstrap_sync_car->{blocks} }, 1, 'bootstrap sync CAR contains only the commit block');
is($bootstrap_sync_car->{roots}[0]->to_string, $bootstrap_commit->{body}{commit}->to_string, 'bootstrap sync CAR roots the bootstrap commit');
$bootstrap->finish_ok;

my $baseline_seq = $app->store->latest_event_seq;
my $prior_head = $app->store->get_latest_commit($did);
my $prior_rev = $prior_head->{rev};

$ws->websocket_ok('/xrpc/com.atproto.sync.subscribeRepos');
is($ws->message, undef, 'no backlog is emitted when no cursor is supplied');

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'firehose',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'hello firehose',
    createdAt => '2026-03-10T00:00:00Z',
  },
})->status_is(200);
my $first_result = $t->tx->res->json;

$ws->message_ok('received a firehose frame')
  ->message_like({binary => qr/.+/}, 'firehose frame is binary');

my $decoded = decode_frame($ws->message->[1]);
is($decoded->{header}{op}, 1, 'frame is an event message');
is($decoded->{header}{t}, '#commit', 'frame type is commit');
is($decoded->{body}{repo}, $did, 'commit identifies repo');
ok($decoded->{body}{commit}->isa('ATProto::PDS::Repo::CID'), 'commit field is decoded as CID');
ok(length($decoded->{body}{blocks} // q()) > 0, 'blocks field contains raw bytes');
is($decoded->{body}{seq}, $baseline_seq + 1, 'sequence advances from prior high water mark');
is($decoded->{body}{ops}[0]{path}, 'app.bsky.feed.post/firehose', 'operation path is preserved');
is($decoded->{body}{ops}[0]{action}, 'create', 'operation action is preserved');
is($decoded->{body}{since}, $prior_rev, 'first emitted commit advertises the previous rev');
is($decoded->{body}{prevData}->to_string, $prior_head->{root_cid}, 'first emitted commit advertises the previous data root');
ok(!$decoded->{body}{rebase}, 'commit event is not marked as a rebase');
ok(!$decoded->{body}{tooBig}, 'commit event is not marked as too big');
like($decoded->{body}{time}, qr/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, 'commit event time is ISO8601');

my $initial_car = read_car($decoded->{body}{blocks});
my $initial_commit_block = (grep { $_->{cid}->to_string eq $decoded->{body}{commit}->to_string } @{ $initial_car->{blocks} })[0];
ok($initial_commit_block, 'initial commit block is present in emitted CAR');
ok(
  scalar(grep { $_->{cid}->to_string eq $first_result->{cid} } @{ $initial_car->{blocks} || [] }),
  'initial firehose CAR includes the created record block',
);
my $initial_commit = decode_dag_cbor($initial_commit_block->{bytes});
is($initial_commit->{did}, $did, 'initial commit block belongs to the repo');
is($initial_commit->{rev}, $decoded->{body}{rev}, 'initial commit block rev matches the event');

my $initial_rev = $decoded->{body}{rev};

$ws->finish_ok;

my $replay = Test::Mojo->new($app);
$replay->websocket_ok("/xrpc/com.atproto.sync.subscribeRepos?cursor=$baseline_seq");

$replay->message_ok('replayed event after the cursor');
my $replayed = decode_frame($replay->message->[1]);
is($replayed->{body}{seq}, $baseline_seq + 1, 'cursor replay is exclusive');
$replay->finish_ok;

my $follow = Test::Mojo->new($app);
$follow->websocket_ok('/xrpc/com.atproto.sync.subscribeRepos');
my $first_head = $app->store->get_latest_commit($did);
$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'firehose-second',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'follow-up firehose',
    createdAt => '2026-03-10T00:00:01Z',
  },
})->status_is(200);
my $second_result = $t->tx->res->json;

$follow->message_ok('received a second firehose frame')
  ->message_like({binary => qr/.+/}, 'second firehose frame is binary');

my $second = decode_frame($follow->message->[1]);
is($second->{body}{ops}[0]{path}, 'app.bsky.feed.post/firehose-second', 'second operation path is preserved');
is($second->{body}{since}, $initial_rev, 'subsequent commit advertises the previous rev');
is($second->{body}{prevData}->to_string, $first_head->{root_cid}, 'subsequent commit advertises the previous data root');
ok(!$second->{body}{rebase}, 'subsequent commit is not marked as a rebase');
ok(!$second->{body}{tooBig}, 'subsequent commit is not marked as too big');
like($second->{body}{time}, qr/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, 'subsequent commit time is ISO8601');

my $second_car = read_car($second->{body}{blocks});
my $second_commit_block = (grep { $_->{cid}->to_string eq $second->{body}{commit}->to_string } @{ $second_car->{blocks} })[0];
ok($second_commit_block, 'second commit block is present in emitted CAR');
ok(
  scalar(grep { $_->{cid}->to_string eq $second_result->{cid} } @{ $second_car->{blocks} || [] }),
  'second firehose CAR includes the new record block',
);
my $second_commit = decode_dag_cbor($second_commit_block->{bytes});
is($second_commit->{did}, $did, 'subsequent commit block belongs to the repo');
is($second_commit->{rev}, $second->{body}{rev}, 'subsequent commit block rev matches the event');
$follow->finish_ok;

my $update_watch = Test::Mojo->new($app);
$update_watch->websocket_ok('/xrpc/com.atproto.sync.subscribeRepos');
my $second_head = $app->store->get_latest_commit($did);
$t->post_ok('/xrpc/com.atproto.repo.putRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'firehose-second',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'follow-up firehose edited',
    createdAt => '2026-03-10T00:00:01Z',
  },
})->status_is(200);
my $updated_result = $t->tx->res->json;

$update_watch->message_ok('received an update firehose frame')
  ->message_like({binary => qr/.+/}, 'update firehose frame is binary');

my $updated = decode_frame($update_watch->message->[1]);
is($updated->{header}{t}, '#commit', 'update frame is a commit');
is($updated->{body}{ops}[0]{action}, 'update', 'update commit reports an update op');
is($updated->{body}{ops}[0]{path}, 'app.bsky.feed.post/firehose-second', 'update operation path is preserved');
is($updated->{body}{ops}[0]{cid}->to_string, $updated_result->{cid}, 'update op exposes the replacement record CID');
is($updated->{body}{ops}[0]{prev}->to_string, $second_result->{cid}, 'update op exposes the previous record CID');
is($updated->{body}{since}, $second->{body}{rev}, 'update commit advertises the prior rev');
is($updated->{body}{prevData}->to_string, $second_head->{root_cid}, 'update commit advertises the previous data root');

my $updated_car = read_car($updated->{body}{blocks});
ok(
  scalar(grep { $_->{cid}->to_string eq $updated_result->{cid} } @{ $updated_car->{blocks} || [] }),
  'update firehose CAR includes the replacement record block',
);
ok(
  !scalar(grep { $_->{cid}->to_string eq $second_result->{cid} } @{ $updated_car->{blocks} || [] }),
  'update firehose CAR does not resend the superseded record block',
);
$update_watch->finish_ok;

my $delete_watch = Test::Mojo->new($app);
$delete_watch->websocket_ok('/xrpc/com.atproto.sync.subscribeRepos');
my $updated_head = $app->store->get_latest_commit($did);
$t->post_ok('/xrpc/com.atproto.repo.deleteRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'firehose-second',
})->status_is(200);

$delete_watch->message_ok('received a delete firehose frame')
  ->message_like({binary => qr/.+/}, 'delete firehose frame is binary');

my $deleted = decode_frame($delete_watch->message->[1]);
is($deleted->{header}{t}, '#commit', 'delete frame is a commit');
is($deleted->{body}{ops}[0]{action}, 'delete', 'delete commit reports a delete op');
is($deleted->{body}{ops}[0]{path}, 'app.bsky.feed.post/firehose-second', 'delete operation path is preserved');
ok(!defined $deleted->{body}{ops}[0]{cid}, 'delete op omits the deleted record CID');
is($deleted->{body}{ops}[0]{prev}->to_string, $updated_result->{cid}, 'delete op exposes the deleted record CID as prev');
is($deleted->{body}{since}, $updated->{body}{rev}, 'delete commit advertises the prior rev');
is($deleted->{body}{prevData}->to_string, $updated_head->{root_cid}, 'delete commit advertises the previous data root');

my $deleted_car = read_car($deleted->{body}{blocks});
ok(
  !scalar(grep { $_->{cid}->to_string eq $updated_result->{cid} } @{ $deleted_car->{blocks} || [] }),
  'delete firehose CAR does not include the deleted record block',
);
ok(
  !scalar(grep { $_->{cid}->to_string eq $first_result->{cid} } @{ $deleted_car->{blocks} || [] }),
  'delete firehose CAR does not resend unchanged record blocks',
);
$delete_watch->finish_ok;

my $firehose_latest = $app->store->latest_event_seq;
my $exclusive = Test::Mojo->new($app);
$exclusive->websocket_ok("/xrpc/com.atproto.sync.subscribeRepos?cursor=$firehose_latest");
is($exclusive->message, undef, 'repo cursor replay is exclusive at the current latest event');
$exclusive->finish_ok;

my $future = Test::Mojo->new($app);
$future->websocket_ok('/xrpc/com.atproto.sync.subscribeRepos?cursor=999999999')
  ->message_ok('future cursor returns an error frame');

my $error = decode_frame($future->message->[1]);
is($error->{header}{op}, -1, 'future cursor frame is an error');
is($error->{body}{error}, 'FutureCursor', 'error type is FutureCursor');
$future->finish_ok;

my $future_edge = Test::Mojo->new($app);
$future_edge->websocket_ok('/xrpc/com.atproto.sync.subscribeRepos?cursor=' . ($app->store->latest_event_seq + 1))
  ->message_ok('latest+1 repo cursor is rejected as future');

my $future_edge_error = decode_frame($future_edge->message->[1]);
is($future_edge_error->{body}{error}, 'FutureCursor', 'edge future repo cursor is also rejected');
$future_edge->finish_ok;

my $skip_start = $app->store->latest_event_seq;
$app->store->append_event(
  did     => $did,
  type    => 'mystery',
  payload => { ignored => 1 },
);

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'firehose-third',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'skip unknown backlog',
    createdAt => '2026-03-10T00:00:02Z',
  },
})->status_is(200);

my $skip_unknown = Test::Mojo->new($app);
$skip_unknown->websocket_ok("/xrpc/com.atproto.sync.subscribeRepos?cursor=$skip_start")
  ->message_ok('subscription skips unhandled backlog events');

my $skipped = decode_frame($skip_unknown->message->[1]);
is($skipped->{body}{seq}, $skip_start + 2, 'repo backlog advances past skipped events');
is($skipped->{body}{ops}[0]{path}, 'app.bsky.feed.post/firehose-third', 'repo replay reaches the later commit');
$skip_unknown->finish_ok;

my $outdated_floor = $app->store->latest_event_seq;
$app->store->dbh->do(q{DELETE FROM events WHERE seq <= ?}, undef, $outdated_floor);

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'firehose-fourth',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'outdated cursor replay',
    createdAt => '2026-03-10T00:00:03Z',
  },
})->status_is(200);

my $outdated = Test::Mojo->new($app);
$outdated->websocket_ok('/xrpc/com.atproto.sync.subscribeRepos?cursor=1')
  ->message_ok('stale repo cursor returns an info frame first');

my $outdated_info = decode_frame($outdated->message->[1]);
is($outdated_info->{header}{op}, 1, 'outdated cursor info is a message frame');
is($outdated_info->{header}{t}, '#info', 'stale repo cursor yields an info frame');
is($outdated_info->{body}{name}, 'OutdatedCursor', 'stale repo cursor is reported as OutdatedCursor');

$outdated->message_ok('stale repo cursor then resumes from the oldest retained event');
my $outdated_commit = decode_frame($outdated->message->[1]);
is($outdated_commit->{header}{t}, '#commit', 'repo stream resumes with the retained commit event');
is($outdated_commit->{body}{ops}[0]{path}, 'app.bsky.feed.post/firehose-fourth', 'repo replay resumes at the retained commit');
$outdated->finish_ok;

done_testing;
