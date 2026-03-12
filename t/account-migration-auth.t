use v5.34;
use warnings;

use Config ();
use File::Path qw(remove_tree);
use File::Spec;
use FindBin qw($Bin);
use IO::Socket::INET;
use Test::More;
use Time::HiRes qw(sleep);

BEGIN {
  require lib;
  my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
  lib->import(
    File::Spec->catdir($root, 'lib'),
    File::Spec->catdir($root, 'local', 'lib', 'perl5'),
    File::Spec->catdir($root, 'local', 'lib', 'perl5', $Config::Config{archname}),
  );
}

use JSON::PP ();
use Mojo::Server::Daemon;
use Mojo::URL;
use Mojo::UserAgent;
use Test::Mojo;
use ATProto::PDS;

my @pids;
END {
  my $status = $?;
  kill 'TERM', @pids if @pids;
  waitpid($_, 0) for @pids;
  $? = $status;
}

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $tmp  = File::Spec->catdir($root, 'data', 'tmp-tests', 'account-migration-auth');
remove_tree($tmp) if -d $tmp;

my $old_port = _find_free_port();
my $old_base = "http://127.0.0.1:$old_port";

my $old_app = ATProto::PDS->new(
  project_root => $root,
  settings     => {
    base_url              => $old_base,
    service_did_method    => 'did:web',
    service_handle_domain => 'old.test',
    jwt_secret            => 'old-migration-secret',
    db_path               => File::Spec->catfile($tmp, 'old.sqlite'),
    data_dir              => File::Spec->catdir($tmp, 'old-data'),
  },
);
my $old_t = Test::Mojo->new($old_app);

$old_t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'alice.old.test',
  email    => 'alice@example.test',
  password => 'password123',
})->status_is(200);
my $alice = $old_t->tx->res->json;

$old_t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'bob.old.test',
  email    => 'bob@example.test',
  password => 'password123',
})->status_is(200);
my $bob = $old_t->tx->res->json;
my $new_service_did = 'did:web:127.0.0.1%3A7755';

$old_t->get_ok(Mojo::URL->new('/xrpc/com.atproto.server.getServiceAuth')->query(
  aud => $new_service_did,
  lxm => 'com.atproto.server.createAccount',
) => {
  Authorization => "Bearer $alice->{accessJwt}",
})->status_is(200)
  ->json_like('/token' => qr/\w/);
my $alice_service_jwt = $old_t->tx->res->json->{token};

$old_t->get_ok(Mojo::URL->new('/xrpc/com.atproto.server.getServiceAuth')->query(
  aud => $new_service_did,
  lxm => 'com.atproto.server.createAccount',
) => {
  Authorization => "Bearer $bob->{accessJwt}",
})->status_is(200)
  ->json_like('/token' => qr/\w/);
my $bob_service_jwt = $old_t->tx->res->json->{token};

_start_daemon($old_app, $old_port);

my $new_app = ATProto::PDS->new(
  project_root => $root,
  settings     => {
    base_url              => 'http://127.0.0.1:7755',
    service_did_method    => 'did:web',
    service_handle_domain => 'new.test',
    jwt_secret            => 'new-migration-secret',
    db_path               => File::Spec->catfile($tmp, 'new.sqlite'),
    data_dir              => File::Spec->catdir($tmp, 'new-data'),
  },
);
my $new_t = Test::Mojo->new($new_app);

$new_t->get_ok('/xrpc/com.atproto.server.describeServer')
  ->status_is(200)
  ->json_is('/did' => $new_service_did);

$new_t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  did      => $alice->{did},
  handle   => 'alice.new.test',
  email    => 'alice@example.test',
  password => 'password123',
})->status_is(401)
  ->json_is('/error' => 'AuthRequired')
  ->json_is('/message' => "Missing auth to create account with did: $alice->{did}");

$new_t->post_ok('/xrpc/com.atproto.server.createAccount' => {
  Authorization => "Bearer $bob_service_jwt",
} => json => {
  did      => $alice->{did},
  handle   => 'alice.new.test',
  email    => 'alice@example.test',
  password => 'password123',
})->status_is(401)
  ->json_is('/error' => 'AuthRequired')
  ->json_is('/message' => "Missing auth to create account with did: $alice->{did}");

$new_t->post_ok('/xrpc/com.atproto.server.createAccount' => {
  Authorization => "Bearer $alice_service_jwt",
} => json => {
  did      => $alice->{did},
  handle   => 'alice.new.test',
  email    => 'alice@example.test',
  password => 'password123',
})->status_is(200)
  ->json_is('/did' => $alice->{did})
  ->json_is('/active' => JSON::PP::false)
  ->json_is('/status' => 'deactivated')
  ->json_is('/didDoc/id' => $alice->{did})
  ->json_is('/didDoc/service/0/serviceEndpoint' => $old_base);

my $migrated = $new_app->store->get_account_by_did($alice->{did});
ok(defined $migrated->{deactivated_at}, 'migration createAccount stores the new account as deactivated');
is($migrated->{did_doc}{service}[0]{serviceEndpoint}, $old_base, 'migration keeps the existing remote DID document until activation');

$new_t->post_ok('/xrpc/com.atproto.server.createSession' => json => {
  identifier => 'alice.new.test',
  password   => 'password123',
})->status_is(200)
  ->json_is('/active' => JSON::PP::false)
  ->json_is('/status' => 'deactivated');

done_testing;

sub _start_daemon {
  my ($app, $port) = @_;
  my $pid = fork();
  die 'fork failed' unless defined $pid;

  if ($pid == 0) {
    my $daemon = Mojo::Server::Daemon->new(
      app    => $app,
      listen => ["http://127.0.0.1:$port"],
      silent => 1,
    );
    $daemon->run;
    exit 0;
  }

  push @pids, $pid;
  _wait_for_health("http://127.0.0.1:$port");
  return;
}

sub _wait_for_health {
  my ($base_url) = @_;
  my $ua = Mojo::UserAgent->new(max_redirects => 0);
  for (1 .. 100) {
    my $ok = eval {
      my $tx = $ua->get("$base_url/_health");
      my $res = $tx->result;
      return ($res->code // 0) == 200;
    };
    return 1 if $ok;
    sleep 0.05;
  }
  die "mock server did not become ready at $base_url";
}

sub _find_free_port {
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
