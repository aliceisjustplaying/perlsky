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
    service_handle_domain   => 'pds.example.test',
    jwt_secret              => 'cors-secret',
    db_path                 => File::Spec->catfile($tmp, 'cors.sqlite'),
    data_dir                => File::Spec->catdir($tmp, 'data'),
  },
);

my $t = Test::Mojo->new($app);

$t->get_ok('/xrpc/com.atproto.server.describeServer' => {
  Origin => 'https://bsky.app',
})->status_is(200)
  ->header_is('Access-Control-Allow-Origin' => '*')
  ->header_like('Vary' => qr/\bOrigin\b/, 'origin is included in Vary');

my $tx = $t->ua->build_tx(
  OPTIONS => '/xrpc/com.atproto.server.createSession' => {
    Origin                         => 'https://bsky.app',
    'Access-Control-Request-Method'  => 'POST',
    'Access-Control-Request-Headers' => 'authorization, content-type',
  },
);
$t->ua->start($tx);

is($tx->res->code, 204, 'XRPC preflight succeeds');
is($tx->res->headers->header('Access-Control-Allow-Origin'), '*', 'preflight allows all origins');
like(
  $tx->res->headers->header('Access-Control-Allow-Methods') // q(),
  qr/\bPOST\b/,
  'preflight allows POST',
);
like(
  lc($tx->res->headers->header('Access-Control-Allow-Headers') // q()),
  qr/\bauthorization\b/,
  'preflight echoes requested authorization header',
);
like(
  lc($tx->res->headers->header('Access-Control-Allow-Headers') // q()),
  qr/\bcontent-type\b/,
  'preflight echoes requested content-type header',
);

done_testing;
