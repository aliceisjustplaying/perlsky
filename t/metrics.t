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

my $access = $t->tx->res->json->{accessJwt};

$t->post_ok('/xrpc/com.atproto.repo.uploadBlob' => {
  Authorization => "Bearer $access",
  'Content-Type' => 'text/plain',
} => 'hello')->status_is(200);

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
  qr/perlds_xrpc_requests_total\{endpoint_type="procedure",method="POST",nsid="com\.atproto\.server\.createAccount",status="200"\} 1\b/,
  'createAccount request counter is exported',
);
like(
  $metrics,
  qr/perlds_xrpc_request_duration_seconds_count\{endpoint_type="procedure",method="POST",nsid="com\.atproto\.server\.createAccount",status="200"\} 1\b/,
  'createAccount latency histogram is exported',
);
like(
  $metrics,
  qr/perlds_subscription_connections_total\{nsid="com\.atproto\.sync\.subscribeRepos"\} 1\b/,
  'subscription open count is exported',
);
like(
  $metrics,
  qr/perlds_subscription_active\{nsid="com\.atproto\.sync\.subscribeRepos"\} 0\b/,
  'subscription active gauge returns to zero after close',
);
like(
  $metrics,
  qr/perlds_blob_ingress_bytes_total\{mime_type="text\/plain"\} 5\b/,
  'blob upload bytes are exported',
);
like(
  $metrics,
  qr/perlds_store_operations_total\{operation="append_event",status="ok"\} [1-9]\d*\b/,
  'store operation counters are exported',
);
like(
  $metrics,
  qr/perlds_build_info\{service="perlds"\} 1\b/,
  'build info metric is exported',
);

done_testing;
