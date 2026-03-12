use v5.34;
use warnings;
use Config ();
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use IO::Socket::INET;
use POSIX qw(WNOHANG);
use Test::More;
use Time::HiRes qw(sleep time);

BEGIN {
  require lib;
  my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
  lib->import(
    File::Spec->catdir($root, 'lib'),
    File::Spec->catdir($root, 'local', 'lib', 'perl5'),
    File::Spec->catdir($root, 'local', 'lib', 'perl5', $Config::Config{archname}),
  );
}

use JSON::PP qw(decode_json);
use Test::Mojo;
use ATProto::PDS;

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $tmp  = tempdir(CLEANUP => 1);
my @children;

END {
  local $?;
  for my $child (reverse @children) {
    next unless $child->{pid};
    next unless kill 0, $child->{pid};
    kill 'TERM', $child->{pid};
    for (1 .. 40) {
      last if waitpid($child->{pid}, WNOHANG) == $child->{pid};
      sleep 0.1;
    }
    kill 'KILL', $child->{pid} if kill 0, $child->{pid};
    waitpid($child->{pid}, 0);
  }
  $? = 0;
}

sub free_port {
  my $sock = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Proto     => 'tcp',
    Listen    => 5,
    ReuseAddr => 1,
  ) or die "unable to allocate a port: $!";
  my $port = $sock->sockport;
  close $sock;
  return $port;
}

sub slurp {
  my ($path) = @_;
  open my $fh, '<', $path or die "open($path): $!";
  local $/;
  return <$fh>;
}

sub spawn_plc_mock {
  my ($ready_file, $log_file) = @_;
  my $pid = fork;
  die "fork failed: $!" unless defined $pid;

  if ($pid == 0) {
    open STDOUT, '>', $log_file or die "open($log_file): $!";
    open STDERR, '>&', \*STDOUT or die "dup stdout failed";
    chdir $root or die "chdir($root): $!";
    $ENV{PERLSKY_READY_FILE} = $ready_file;
    $ENV{PERLSKY_PLC_PORT}   = free_port();
    $ENV{PERLSKY_PLC_HOST}   = '127.0.0.1';
    exec 'fnm', 'exec', '--using=20', '--', 'node',
      File::Spec->catfile($root, 'tools', 'differential', 'plc-mock.cjs');
    die "exec failed: $!";
  }

  push @children, { pid => $pid };
  return $pid;
}

sub wait_for_ready {
  my ($path, $timeout) = @_;
  $timeout //= 20;
  my $deadline = time + $timeout;
  while (time < $deadline) {
    if (-f $path) {
      return decode_json(slurp($path));
    }
    sleep 0.1;
  }
  die "timed out waiting for $path";
}

my $plc_ready = File::Spec->catfile($tmp, 'plc.ready.json');
my $plc_log   = File::Spec->catfile($tmp, 'plc.log');
spawn_plc_mock($plc_ready, $plc_log);
my $plc = wait_for_ready($plc_ready);

my $app = ATProto::PDS->new(
  project_root => $root,
  settings     => {
    base_url                     => 'http://127.0.0.1:7755',
    service_handle_domain        => 'test',
    service_did_method           => 'did:web',
    account_did_method           => 'did:plc',
    plc_url                      => $plc->{origin},
    plc_rotation_private_key_hex => ('11' x 32),
    jwt_secret                   => 'plc-secret',
    admin_password               => 'admin-secret',
    db_path                      => File::Spec->catfile($tmp, 'plc.sqlite'),
    data_dir                     => File::Spec->catdir($tmp, 'data'),
  },
);

my $t = Test::Mojo->new($app);

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'alice.test',
  email    => 'alice@test.com',
  password => 'hunter22',
})->status_is(200);

my $created = $t->tx->res->json;
my $did     = $created->{did};
my $access  = $created->{accessJwt};

$t->post_ok('/xrpc/com.atproto.server.createAppPassword' => {
  Authorization => "Bearer $access",
} => json => {
  name => 'plc-helper',
})->status_is(200)
  ->json_like('/password' => qr/\w/);

my $app_password = $t->tx->res->json->{password};

$t->post_ok('/xrpc/com.atproto.server.createSession' => json => {
  identifier => 'alice.test',
  password   => $app_password,
})->status_is(200);

my $app_password_access = $t->tx->res->json->{accessJwt};

like($did, qr/\Adid:plc:/, 'createAccount returns a did:plc identifier');
is($created->{didDoc}{id}, $did, 'didDoc matches the created did');
is($created->{didDoc}{alsoKnownAs}[0], 'at://alice.test', 'didDoc carries the handle');
like($created->{didDoc}{verificationMethod}[0]{type}, qr/Secp256k1/, 'didDoc uses a secp256k1 verification method');

$t->get_ok('/xrpc/com.atproto.identity.resolveDid' => form => {
  did => $did,
})->status_is(200)
  ->json_is('/didDoc/id', $did)
  ->json_is('/didDoc/alsoKnownAs/0', 'at://alice.test');

$t->get_ok('/xrpc/com.atproto.identity.getRecommendedDidCredentials' => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/alsoKnownAs/0', 'at://alice.test')
  ->json_like('/verificationMethods/atproto' => qr/\Adid:key:/)
  ->json_like('/rotationKeys/0' => qr/\Adid:key:/)
  ->json_is('/services/atproto_pds/endpoint', 'http://127.0.0.1:7755');

$t->post_ok('/xrpc/com.atproto.identity.updateHandle' => {
  Authorization => "Bearer $access",
} => json => {
  handle => 'alice-renamed.test',
})->status_is(200);

$t->post_ok('/xrpc/com.atproto.identity.requestPlcOperationSignature' => {
  Authorization => "Bearer $app_password_access",
})->status_is(400)
  ->json_is('/error', 'InvalidToken')
  ->json_is('/message', 'Bad token scope');

$t->get_ok('/xrpc/com.atproto.identity.resolveHandle' => form => {
  handle => 'alice-renamed.test',
})->status_is(200)
  ->json_is('/did', $did);

$t->get_ok('/xrpc/com.atproto.identity.resolveDid' => form => {
  did => $did,
})->status_is(200)
  ->json_is('/didDoc/alsoKnownAs/0', 'at://alice-renamed.test');

$t->post_ok('/xrpc/com.atproto.identity.requestPlcOperationSignature' => {
  Authorization => "Bearer $access",
})->status_is(200);

my $token = $app->store->latest_action_token(
  did     => $did,
  purpose => 'plc_operation',
);
ok($token && $token->{token}, 'requestPlcOperationSignature issues a PLC email token');

$t->post_ok('/xrpc/com.atproto.identity.signPlcOperation' => {
  Authorization => "Bearer $app_password_access",
} => json => {
  token => 'plc-token',
})->status_is(400)
  ->json_is('/error', 'InvalidToken')
  ->json_is('/message', 'Bad token scope');

$t->post_ok('/xrpc/com.atproto.identity.signPlcOperation' => {
  Authorization => "Bearer $access",
} => json => {})->status_is(400)
  ->json_is('/error', 'InvalidRequest');

$t->post_ok('/xrpc/com.atproto.identity.signPlcOperation' => {
  Authorization => "Bearer $access",
} => json => {
  token        => $token->{token},
  rotationKeys => [
    'did:key:zQ3shokFTS3brHcDQrn82RUDfCZESWL1ZdCEJwekUDPQiYBme',
    'did:key:zQ3shjyJXUaRJC2GC43mX8aPrUhoTdoiongXhZjsdTzPKYZUM',
  ],
})->status_is(200);

my $signed = $t->tx->res->json->{operation};
is($signed->{type}, 'plc_operation', 'signPlcOperation returns a PLC operation');
is($signed->{alsoKnownAs}[0], 'at://alice-renamed.test', 'signed operation preserves the current handle');
is_deeply(
  $signed->{rotationKeys},
  [
    'did:key:zQ3shokFTS3brHcDQrn82RUDfCZESWL1ZdCEJwekUDPQiYBme',
    'did:key:zQ3shjyJXUaRJC2GC43mX8aPrUhoTdoiongXhZjsdTzPKYZUM',
  ],
  'signed operation applies the requested rotation keys and keeps the server rotation key',
);
ok(length($signed->{sig} // q()) > 10, 'signed operation contains a signature');
like($signed->{prev} // q(), qr/\Ab/, 'signed operation references the prior PLC op by CID');

$t->post_ok('/xrpc/com.atproto.identity.submitPlcOperation' => {
  Authorization => "Bearer $access",
} => json => {
  operation => {
    %{$signed},
    alsoKnownAs => ['at://alice-signed.test'],
  },
})->status_is(400)
  ->json_is('/error', 'InvalidRequest');

$t->post_ok('/xrpc/com.atproto.identity.submitPlcOperation' => {
  Authorization => "Bearer $access",
} => json => {
  operation => $signed,
})->status_is(200);

$t->get_ok('/xrpc/com.atproto.identity.resolveHandle' => form => {
  handle => 'alice-renamed.test',
})->status_is(200)
  ->json_is('/did', $did);

$t->get_ok('/xrpc/com.atproto.identity.resolveDid' => form => {
  did => $did,
})->status_is(200)
  ->json_is('/didDoc/alsoKnownAs/0', 'at://alice-renamed.test');

done_testing;
