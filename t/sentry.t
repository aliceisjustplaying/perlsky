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
use ATProto::PDS::Sentry;

{
  package SentryTestTx;

  sub new {
    my ($class, $code) = @_;
    return bless { code => $code }, $class;
  }

  sub result {
    my ($self) = @_;
    return bless { code => $self->{code} }, 'SentryTestResult';
  }
}

{
  package SentryTestResult;

  sub code {
    my ($self) = @_;
    return $self->{code};
  }
}

{
  package SentryTestUA;

  sub new {
    my ($class, $sink) = @_;
    return bless { sink => $sink }, $class;
  }

  sub post {
    my ($self, $url, $headers, %rest) = @_;
    push @{ $self->{sink} }, {
      url     => $url,
      headers => $headers,
      payload => $rest{json},
    };
    return SentryTestTx->new(200);
  }
}

my @requests;
my $sentry = ATProto::PDS::Sentry->new(
  dsn         => 'http://public:secret@127.0.0.1:9999/42',
  environment => 'test',
  server_name => 'perlsky.test',
  service     => 'perlsky',
);
$sentry->{ua} = SentryTestUA->new(\@requests);

ok($sentry->enabled, 'sentry client is enabled when a DSN is configured');
ok(
  $sentry->capture_exception(
    message       => 'intentional sentry test failure',
    method        => 'GET',
    nsid          => 'com.atproto.server.describeServer',
    endpoint_type => 'query',
    status        => 500,
    did           => 'did:plc:test',
  ),
  'capture_exception reports success for a 200 response',
);
is(scalar @requests, 1, 'capture_exception submits one store request');
is($requests[0]{url}, 'http://127.0.0.1:9999/api/42/store/', 'dsn is converted into the expected store URL');
like($requests[0]{headers}{'X-Sentry-Auth'}, qr/sentry_key=public/, 'sentry auth header includes the public key');
is($requests[0]{payload}{tags}{nsid}, 'com.atproto.server.describeServer', 'payload includes the nsid tag');
is($requests[0]{payload}{exception}{values}[0]{type}, 'UnhandledXRPCException', 'payload includes exception type');
like($requests[0]{payload}{exception}{values}[0]{value}, qr/intentional sentry test failure/, 'payload includes exception message');
is($requests[0]{payload}{user}{id}, 'did:plc:test', 'payload includes the actor did when available');

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $tmp  = tempdir(CLEANUP => 1);
my $app = ATProto::PDS->new(
  project_root => $root,
  settings     => {
    base_url              => 'http://127.0.0.1:7755',
    service_did_method    => 'did:web',
    service_handle_domain => 'test',
    jwt_secret            => 'sentry-test-secret',
    sentry_dsn            => 'http://public:secret@127.0.0.1:9999/42',
    db_path               => File::Spec->catfile($tmp, 'sentry.sqlite'),
    data_dir              => File::Spec->catdir($tmp, 'data'),
  },
);

my @captured;
{
  no warnings 'redefine';
  local *ATProto::PDS::Sentry::capture_exception = sub {
    my ($self, %args) = @_;
    push @captured, \%args;
    return 1;
  };

  $app->api_registry->register('com.atproto.server.describeServer', sub {
    die "intentional dispatcher sentry failure\n";
  });

  my $t = Test::Mojo->new($app);
  $t->get_ok('/xrpc/com.atproto.server.describeServer')
    ->status_is(500)
    ->json_is('/error' => 'InternalServerError');
}

is(scalar @captured, 1, 'dispatcher reports an unhandled xrpc exception to sentry');
is($captured[0]{nsid}, 'com.atproto.server.describeServer', 'dispatcher passes the xrpc nsid to sentry');
is($captured[0]{endpoint_type}, 'query', 'dispatcher passes the endpoint type to sentry');
like($captured[0]{message}, qr/intentional dispatcher sentry failure/, 'dispatcher passes the exception message to sentry');

done_testing;
