use v5.34;
use warnings;

use Config ();
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use JSON::PP ();
use Mojo::IOLoop;
use Time::HiRes qw(sleep time);
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
use ATProto::PDS::EventStream qw(decode_frame);
use ATProto::PDS::Identity qw(service_did);

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $tmp  = tempdir(CLEANUP => 1);

my $app = ATProto::PDS->new(
  project_root => $root,
  settings => {
    base_url              => 'http://127.0.0.1:7755',
    service_handle_domain => 'example.test',
    service_did_method    => 'did:web',
    jwt_secret            => 'labels-secret',
    admin_password        => 'admin-secret',
    data_dir              => File::Spec->catdir($tmp, 'data'),
    db_path               => File::Spec->catfile($tmp, 'perlsky.sqlite'),
  },
);

my $service_did = service_did($app->settings);
my $t = Test::Mojo->new($app);
my $ws = Test::Mojo->new($app);
my $admin_auth = 'Basic YWRtaW46YWRtaW4tc2VjcmV0';

sub ws_quiet_ok {
  my ($ws, $desc, $timeout) = @_;
  $timeout //= 0.1;
  my $deadline = time + $timeout;
  while (time < $deadline) {
    Mojo::IOLoop->one_tick;
    if (@{ $ws->{messages} || [] }) {
      $ws->message(shift @{ $ws->{messages} });
      fail($desc);
      diag('unexpected websocket frame arrived while the stream was expected to stay quiet');
      return;
    }
    sleep 0.01;
  }
  pass($desc);
  return;
}

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'alice.example.test',
  email    => 'alice@example.test',
  password => 'hunter22',
})->status_is(200);

my $created = $t->tx->res->json;
my $did     = $created->{did};
my $access  = $created->{accessJwt};

$ws->websocket_ok('/xrpc/com.atproto.label.subscribeLabels');
ws_quiet_ok($ws, 'label stream stays quiet without a backlog');

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'labeled-post',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'record moderation target',
    createdAt => '2026-03-10T00:00:00Z',
  },
})->status_is(200)
  ->json_is('/uri', "at://$did/app.bsky.feed.post/labeled-post");

my $record_uri = $t->tx->res->json->{uri};
my $record_cid = $t->tx->res->json->{cid};

$t->post_ok('/xrpc/com.atproto.admin.updateSubjectStatus' => {
  Authorization => $admin_auth,
} => json => {
  subject  => { uri => $record_uri, cid => $record_cid },
  takedown => { applied => JSON::PP::true },
})->status_is(200);

$ws->message_ok('received a record label frame')
  ->message_like({binary => qr/.+/}, 'record label frame is binary');

my $record_frame = decode_frame($ws->message->[1]);
is($record_frame->{body}{labels}[0]{uri}, $record_uri, 'record label targets the record URI');
is($record_frame->{body}{labels}[0]{cid}, $record_cid, 'record label carries the record CID');
is($record_frame->{body}{labels}[0]{val}, '!hide', 'record takedown emits !hide');
ok(!$record_frame->{body}{labels}[0]{neg}, 'record takedown frame is a positive label');

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.label.queryLabels')->query(
  uriPatterns => $record_uri,
  sources     => $service_did,
))->status_is(200)
  ->json_is('/labels/0/uri', $record_uri)
  ->json_is('/labels/0/cid', $record_cid)
  ->json_is('/labels/0/val', '!hide');

$t->post_ok('/xrpc/com.atproto.admin.updateSubjectStatus' => {
  Authorization => $admin_auth,
} => json => {
  subject  => { uri => $record_uri, cid => $record_cid },
  takedown => { applied => JSON::PP::false },
})->status_is(200);

$ws->message_ok('received a record label negation frame')
  ->message_like({binary => qr/.+/}, 'record negation frame is binary');

my $record_neg = decode_frame($ws->message->[1]);
is($record_neg->{body}{labels}[0]{uri}, $record_uri, 'record negation targets the same record URI');
is($record_neg->{body}{labels}[0]{cid}, $record_cid, 'record negation keeps the record CID');
ok($record_neg->{body}{labels}[0]{neg}, 'record restore emits a negation label');

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.label.queryLabels')->query(
  uriPatterns => $record_uri,
  sources     => $service_did,
))->status_is(200)
  ->json_is('/labels/0/uri', $record_uri)
  ->json_is('/labels/0/cid', $record_cid)
  ->json_is('/labels/0/val', '!hide')
  ->json_is('/labels/0/neg', JSON::PP::true);

my $blob_tx = $t->ua->build_tx(
  POST => '/xrpc/com.atproto.repo.uploadBlob' => {
    Authorization => "Bearer $access",
    'Content-Type' => 'image/png',
  } => 'blob-bytes',
);
$t->request_ok($blob_tx)->status_is(200);

my $blob_cid = $t->tx->res->json->{blob}{ref}{'$link'};

$t->post_ok('/xrpc/com.atproto.admin.updateSubjectStatus' => {
  Authorization => $admin_auth,
} => json => {
  subject  => { did => $did, cid => $blob_cid },
  takedown => { applied => JSON::PP::true },
})->status_is(200);

$ws->message_ok('received a blob label frame')
  ->message_like({binary => qr/.+/}, 'blob label frame is binary');

my $blob_frame = decode_frame($ws->message->[1]);
is($blob_frame->{body}{labels}[0]{uri}, "at://$did", 'blob label targets the repo URI');
is($blob_frame->{body}{labels}[0]{cid}, $blob_cid, 'blob label carries the blob CID');
is($blob_frame->{body}{labels}[0]{val}, '!hide', 'blob takedown emits !hide');
ok(!$blob_frame->{body}{labels}[0]{neg}, 'blob takedown frame is a positive label');

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.label.queryLabels')->query(
  uriPatterns => "at://$did",
  sources     => $service_did,
))->status_is(200)
  ->json_is('/labels/0/uri', "at://$did")
  ->json_is('/labels/0/cid', $blob_cid)
  ->json_is('/labels/0/val', '!hide');

$t->post_ok('/xrpc/com.atproto.admin.updateSubjectStatus' => {
  Authorization => $admin_auth,
} => json => {
  subject  => { did => $did, cid => $blob_cid },
  takedown => { applied => JSON::PP::false },
})->status_is(200);

$ws->message_ok('received a blob label negation frame')
  ->message_like({binary => qr/.+/}, 'blob negation frame is binary');

my $blob_neg = decode_frame($ws->message->[1]);
is($blob_neg->{body}{labels}[0]{uri}, "at://$did", 'blob negation targets the repo URI');
is($blob_neg->{body}{labels}[0]{cid}, $blob_cid, 'blob negation keeps the blob CID');
ok($blob_neg->{body}{labels}[0]{neg}, 'blob restore emits a negation label');

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.label.queryLabels')->query(
  uriPatterns => "at://$did",
  sources     => $service_did,
))->status_is(200)
  ->json_is('/labels/0/uri', "at://$did")
  ->json_is('/labels/0/cid', $blob_cid)
  ->json_is('/labels/0/val', '!hide')
  ->json_is('/labels/0/neg', JSON::PP::true);

$t->post_ok('/xrpc/com.atproto.admin.updateSubjectStatus' => {
  Authorization => $admin_auth,
} => json => {
  subject  => { did => $did },
  takedown => { applied => JSON::PP::true },
})->status_is(200);

$ws->message_ok('received a label frame')
  ->message_like({binary => qr/.+/}, 'label frame is binary');

my $frame = decode_frame($ws->message->[1]);
is($frame->{header}{t}, '#labels', 'frame type is labels');
is($frame->{body}{labels}[0]{ver}, 1, 'label frame advertises version 1');
is($frame->{body}{labels}[0]{src}, $service_did, 'label source is the local service DID');
is($frame->{body}{labels}[0]{uri}, "at://$did", 'repo labels target the repo URI');
is($frame->{body}{labels}[0]{val}, '!hide', 'repo takedown emits !hide');
like($frame->{body}{labels}[0]{cts}, qr/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, 'label frame carries an ISO8601 timestamp');
ok(!$frame->{body}{labels}[0]{neg}, 'takedown frame is a positive label');

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.label.queryLabels')->query(
  uriPatterns => "at://$did",
  sources     => $service_did,
))->status_is(200)
  ->json_has('/labels/0');

my ($repo_label) = grep {
  ($_->{uri} // q()) eq "at://$did"
    && !defined $_->{cid}
    && ($_->{val} // q()) eq '!hide'
    && !$_->{neg}
} @{ $t->tx->res->json->{labels} };
ok($repo_label, 'repo query includes the positive repo label itself');
is($repo_label->{src}, $service_did, 'repo label query preserves the local label source');

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.label.queryLabels')->query(
  uriPatterns => "at://$did*",
  sources     => 'did:web:other.example',
))->status_is(200)
  ->json_is('/labels', []);

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'bob.example.test',
  email    => 'bob@example.test',
  password => 'hunter22',
})->status_is(200);

my $bob_did = $t->tx->res->json->{did};

$t->post_ok('/xrpc/com.atproto.admin.updateSubjectStatus' => {
  Authorization => $admin_auth,
} => json => {
  subject  => { did => $bob_did },
  takedown => { applied => JSON::PP::true },
})->status_is(200);

$ws->message_ok('received bob label frame')
  ->message_like({binary => qr/.+/}, 'bob label frame is binary');

my $bob_frame = decode_frame($ws->message->[1]);
is($bob_frame->{body}{labels}[0]{uri}, "at://$bob_did", 'second repo takedown streams immediately');

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.label.queryLabels')->query([
  uriPatterns => $record_uri,
  uriPatterns => "at://$bob_did",
  limit       => 1,
]))->status_is(200)
  ->json_has('/cursor')
  ->json_is('/labels/0/src', $service_did);

my $first_page = $t->tx->res->json;
my $cursor = $t->tx->res->json->{cursor};

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.label.queryLabels')->query([
  uriPatterns => $record_uri,
  uriPatterns => "at://$bob_did",
  cursor      => $cursor,
  limit       => 1,
]))->status_is(200)
  ->json_has('/labels/0');

my $second_page = $t->tx->res->json;
isnt(
  join("\0", map { defined $_ ? $_ : q() } @{$second_page->{labels}[0]}{qw(uri cid neg)}),
  join("\0", map { defined $_ ? $_ : q() } @{$first_page->{labels}[0]}{qw(uri cid neg)}),
  'cursor pagination does not repeat the same label',
);
is_deeply(
  [ sort map { $_->{uri} } @{ $first_page->{labels} }, @{ $second_page->{labels} } ],
  [ sort $record_uri, "at://$bob_did" ],
  'cursor pagination covers the expected label subjects without overlap',
);

$t->post_ok('/xrpc/com.atproto.admin.updateSubjectStatus' => {
  Authorization => $admin_auth,
} => json => {
  subject  => { did => $did },
  takedown => { applied => JSON::PP::false },
})->status_is(200);

$ws->message_ok('received a label negation frame')
  ->message_like({binary => qr/.+/}, 'negation frame is binary');

my $neg = decode_frame($ws->message->[1]);
is($neg->{header}{t}, '#labels', 'negation frame type is labels');
is($neg->{body}{labels}[0]{ver}, 1, 'negation frame keeps label version metadata');
is($neg->{body}{labels}[0]{uri}, "at://$did", 'negation targets the same repo URI');
is($neg->{body}{labels}[0]{val}, '!hide', 'negation is for !hide');
like($neg->{body}{labels}[0]{cts}, qr/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, 'negation frame carries an ISO8601 timestamp');
ok($neg->{body}{labels}[0]{neg}, 'restore emits a negation label');

my $label_latest = $app->store->latest_event_seq;

my $exclusive = Test::Mojo->new($app);
$exclusive->websocket_ok("/xrpc/com.atproto.label.subscribeLabels?cursor=$label_latest");
ws_quiet_ok($exclusive, 'label cursor replay is exclusive');
$exclusive->finish_ok;

my $replay_start = $app->store->latest_event_seq;
$app->store->append_event(
  did     => $did,
  type    => 'identity',
  payload => { handle => 'alice.example.test' },
);

$t->post_ok('/xrpc/com.atproto.admin.updateSubjectStatus' => {
  Authorization => $admin_auth,
} => json => {
  subject  => { did => $bob_did },
  takedown => { applied => JSON::PP::false },
})->status_is(200);

my $skip_non_label = Test::Mojo->new($app);
$skip_non_label->websocket_ok("/xrpc/com.atproto.label.subscribeLabels?cursor=$replay_start")
  ->message_ok('label replay skips over non-label backlog entries')
  ->message_like({binary => qr/.+/}, 'replayed label frame is binary');

my $replayed_label = decode_frame($skip_non_label->message->[1]);
is($replayed_label->{header}{t}, '#labels', 'replayed backlog frame is labels');
is($replayed_label->{body}{seq}, $replay_start + 2, 'label backlog cursor advances past skipped events');
is($replayed_label->{body}{labels}[0]{uri}, "at://$bob_did", 'replayed label targets the later moderation update');
ok($replayed_label->{body}{labels}[0]{neg}, 'replayed label carries the restore negation');
$skip_non_label->finish_ok;

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.label.queryLabels')->query(
  uriPatterns => "at://$did",
  sources     => $service_did,
))->status_is(200)
  ->json_has('/labels/0');

my ($repo_neg_label) = grep {
  ($_->{uri} // q()) eq "at://$did"
    && !defined $_->{cid}
    && ($_->{val} // q()) eq '!hide'
    && $_->{neg}
} @{ $t->tx->res->json->{labels} };
ok($repo_neg_label, 'repo query includes the negated repo label itself');
is($repo_neg_label->{src}, $service_did, 'negated repo label keeps the local source');

$app->store->dbh->do(q{DELETE FROM events WHERE seq <= ?}, undef, $app->store->latest_event_seq);

$t->post_ok('/xrpc/com.atproto.admin.updateSubjectStatus' => {
  Authorization => $admin_auth,
} => json => {
  subject  => { did => $did },
  takedown => { applied => JSON::PP::true },
})->status_is(200);

my $outdated = Test::Mojo->new($app);
$outdated->websocket_ok('/xrpc/com.atproto.label.subscribeLabels?cursor=1')
  ->message_ok('stale label cursor returns an info frame first');

my $outdated_info = decode_frame($outdated->message->[1]);
is($outdated_info->{header}{t}, '#info', 'stale label cursor yields an info frame');
is($outdated_info->{body}{name}, 'OutdatedCursor', 'stale label cursor is reported as OutdatedCursor');

$outdated->message_ok('stale label cursor then resumes from the oldest retained label event');
my $outdated_label = decode_frame($outdated->message->[1]);
is($outdated_label->{header}{t}, '#labels', 'label stream resumes with a labels frame');
is($outdated_label->{body}{labels}[0]{uri}, "at://$did", 'stale label replay resumes at the retained label event');
is($outdated_label->{body}{labels}[0]{val}, '!hide', 'retained label replay carries the expected moderation label');
$outdated->finish_ok;

$ws->finish_ok;

my $future = Test::Mojo->new($app);
$future->websocket_ok('/xrpc/com.atproto.label.subscribeLabels?cursor=999999999')
  ->message_ok('future label cursor returns an error frame');

my $error = decode_frame($future->message->[1]);
is($error->{header}{op}, -1, 'future cursor frame is an error');
is($error->{body}{error}, 'FutureCursor', 'error type is FutureCursor');
$future->finish_ok;

my $future_edge = Test::Mojo->new($app);
$future_edge->websocket_ok('/xrpc/com.atproto.label.subscribeLabels?cursor=' . ($app->store->latest_event_seq + 1))
  ->message_ok('latest+1 label cursor is rejected as future');

my $future_edge_error = decode_frame($future_edge->message->[1]);
is($future_edge_error->{body}{error}, 'FutureCursor', 'edge future cursor is also rejected');
$future_edge->finish_ok;

done_testing;
