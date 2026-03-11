use v5.34;
use warnings;

use Config ();
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use Mojo::Util qw(url_escape);
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
  settings     => {
    base_url                => 'http://127.0.0.1:7755',
    service_did_method      => 'did:web',
    service_handle_domain   => 'test',
    jwt_secret              => 'metrics-secret',
    admin_password          => 'admin-secret',
    metrics_token           => 'metrics-token',
    db_path                 => File::Spec->catfile($tmp, 'metrics.sqlite'),
    data_dir                => File::Spec->catdir($tmp, 'data'),
  },
);

my $t = Test::Mojo->new($app);

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'alice.test',
  email    => 'alice@test.com',
  password => 'hunter22',
})->status_is(200);

my $created = $t->tx->res->json;
my $access = $created->{accessJwt};
my $did = $created->{did};

$t->post_ok('/xrpc/com.atproto.repo.uploadBlob' => {
  Authorization => "Bearer $access",
  'Content-Type' => 'text/plain',
} => 'hello')->status_is(200);

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'metrics-root',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'metrics root',
    createdAt => '2026-03-11T19:00:00Z',
  },
})->status_is(200);

my $root_post = $t->tx->res->json;

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'metrics-reply',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'metrics reply',
    reply     => {
      root   => { uri => $root_post->{uri}, cid => $root_post->{cid} },
      parent => { uri => $root_post->{uri}, cid => $root_post->{cid} },
    },
    createdAt => '2026-03-11T19:01:00Z',
  },
})->status_is(200);

$t->get_ok("/xrpc/app.bsky.actor.getProfile?actor=$did" => {
  Authorization => "Bearer $access",
})->status_is(200);

$t->get_ok("/xrpc/app.bsky.feed.getAuthorFeed?actor=$did&limit=10" => {
  Authorization => "Bearer $access",
})->status_is(200);

$t->get_ok('/xrpc/app.bsky.feed.getPostThread?uri=' . url_escape('at://' . $did . '/app.bsky.feed.post/metrics-reply') => {
  Authorization => "Bearer $access",
})->status_is(200);

$t->post_ok('/xrpc/com.atproto.server.createSession' => json => {
  identifier => 'alice.test',
  password   => 'wrong-password',
})->status_is(401)
  ->json_is('/error' => 'AuthRequired');

$t->get_ok('/xrpc/example.unsupported.method')
  ->status_is(404)
  ->json_is('/error' => 'UnknownMethod');

$app->api_registry->register('com.atproto.server.describeServer', sub {
  die "forced metrics failure\n";
});

$t->get_ok('/xrpc/com.atproto.server.describeServer')
  ->status_is(500)
  ->json_is('/error' => 'InternalServerError');

$t->websocket_ok('/xrpc/com.atproto.sync.subscribeRepos')
  ->finish_ok;

$t->get_ok('/metrics')
  ->status_is(401)
  ->content_is('metrics authorization required');

$t->get_ok('/metrics' => {
  Authorization => 'Bearer metrics-token',
})->status_is(200)
  ->header_like('Content-Type' => qr{text/plain; version=0\.0\.4}, 'metrics use Prometheus exposition format');

my $metrics = $t->tx->res->body;

like(
  $metrics,
  qr/perlsky_xrpc_requests_total\{endpoint_type="procedure",method="POST",nsid="com\.atproto\.server\.createAccount",status="200"\} 1\b/,
  'createAccount request counter is exported',
);
like(
  $metrics,
  qr/perlsky_xrpc_request_duration_seconds_count\{endpoint_type="procedure",method="POST",nsid="com\.atproto\.server\.createAccount",status="200"\} 1\b/,
  'createAccount latency histogram is exported',
);
like(
  $metrics,
  qr/perlsky_xrpc_errors_total\{endpoint_type="procedure",error="AuthRequired",method="POST",nsid="com\.atproto\.server\.createSession",status="401"\} 1\b/,
  'handled XRPC errors are exported with their error code',
);
like(
  $metrics,
  qr/perlsky_xrpc_errors_total\{endpoint_type="unknown",error="UnknownMethod",method="GET",nsid="example\.unsupported\.method",status="404"\} 1\b/,
  'unknown-method XRPC errors are exported',
);
like(
  $metrics,
  qr/perlsky_xrpc_errors_total\{endpoint_type="query",error="InternalServerError",method="GET",nsid="com\.atproto\.server\.describeServer",status="500"\} 1\b/,
  'internal XRPC failures are exported as 500 errors',
);
like(
  $metrics,
  qr/perlsky_xrpc_unhandled_exceptions_total\{endpoint_type="query",method="GET",nsid="com\.atproto\.server\.describeServer"\} 1\b/,
  'unhandled XRPC exceptions are exported separately',
);
like(
  $metrics,
  qr/perlsky_subscription_connections_total\{nsid="com\.atproto\.sync\.subscribeRepos"\} 1\b/,
  'subscription open count is exported',
);
like(
  $metrics,
  qr/perlsky_subscription_active\{nsid="com\.atproto\.sync\.subscribeRepos"\} 0\b/,
  'subscription active gauge returns to zero after close',
);
like(
  $metrics,
  qr/perlsky_blob_ingress_bytes_total\{mime_type="text\/plain"\} 5\b/,
  'blob upload bytes are exported',
);
like(
  $metrics,
  qr/perlsky_store_operations_total\{operation="append_event",status="ok"\} [1-9]\d*\b/,
  'store operation counters are exported',
);
like(
  $metrics,
  qr/perlsky_service_proxy_requests_total\{nsid="app\.bsky\.actor\.getProfile",source="local",status="200"\} 1\b/,
  'local service-proxy request counters are exported',
);
like(
  $metrics,
  qr/perlsky_service_proxy_request_duration_seconds_count\{nsid="app\.bsky\.feed\.getPostThread",source="local",status="200"\} 1\b/,
  'local service-proxy latency histograms are exported',
);
like(
  $metrics,
  qr/perlsky_service_proxy_local_post_index_cache_access_total\{result="rebuild"\} [1-9]\d*\b/,
  'local post-index rebuild counters are exported',
);
like(
  $metrics,
  qr/perlsky_service_proxy_local_post_index_cache_access_total\{result="process_cache_hit"\} [1-9]\d*\b/,
  'local post-index process-cache hits are exported',
);
like(
  $metrics,
  qr/perlsky_service_proxy_local_post_index_entries\{kind="posts"\} 2\b/,
  'local post-index entry gauges are exported',
);
like(
  $metrics,
  qr/perlsky_service_proxy_local_post_resolution_total\{source="index_cache"\} [1-9]\d*\b/,
  'local post-resolution source counters are exported',
);
like(
  $metrics,
  qr/perlsky_service_proxy_profile_record_cache_total\{result="miss"\} [1-9]\d*\b/,
  'profile cache metrics are exported',
);
like(
  $metrics,
  qr/perlsky_repo_resolution_total\{resolver="did_account",source="exact"\} [1-9]\d*\b/,
  'repo-resolution cache metrics are exported',
);
like(
  $metrics,
  qr/perlsky_build_info\{service="perlsky"\} 1\b/,
  'build info metric is exported',
);

done_testing;
