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

use Mojo::Server::Daemon;
use Mojo::UserAgent;
use Mojolicious;
use Test::Mojo;
use ATProto::PDS;

my @mock_pids;
END {
  my $status = $?;
  kill 'TERM', @mock_pids if @mock_pids;
  waitpid($_, 0) for @mock_pids;
  $? = $status;
}

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $tmp  = File::Spec->catdir($root, 'data', 'tmp-tests', 'remote-handle-resolution');
remove_tree($tmp) if -d $tmp;

my $remote_handle = 'alice.mosphere.at';
my $remote_did    = 'did:plc:pkktelaqretqiz2bddzzlv3t';

my $appview_app = Mojolicious->new;
$appview_app->routes->get('/ready')->to(cb => sub {
  my ($c) = @_;
  $c->render(text => 'ok');
});
$appview_app->routes->get('/xrpc/com.atproto.identity.resolveHandle')->to(cb => sub {
  my ($c) = @_;
  my $handle = lc($c->param('handle') // '');
  return $c->render(json => { did => $remote_did }) if $handle eq $remote_handle;
  $c->render(status => 404, json => {
    error   => 'HandleNotFound',
    message => "No DID found for handle $handle",
  });
});

my $appview_url = _start_mock_server($appview_app);

my $app = ATProto::PDS->new(
  project_root => $root,
  settings     => {
    base_url              => 'http://127.0.0.1:7755',
    service_did_method    => 'did:web',
    service_handle_domain => 'perlsky.example.test',
    jwt_secret            => 'remote-handle-secret',
    data_dir              => $tmp,
    db_path               => File::Spec->catfile($tmp, 'perlsky.sqlite'),
    bsky_appview_url      => $appview_url,
  },
);
my $t = Test::Mojo->new($app);

$t->get_ok("/xrpc/com.atproto.identity.resolveHandle?handle=$remote_handle")
  ->status_is(200)
  ->json_is('/did' => $remote_did);

$t->get_ok('/xrpc/com.atproto.identity.resolveHandle?handle=missing.example.test')
  ->status_is(404)
  ->json_is('/error' => 'HandleNotFound');

done_testing;

sub _start_mock_server {
  my ($mock_app) = @_;
  my $port = _find_free_port();
  my $pid = fork();
  die 'fork failed' unless defined $pid;

  if ($pid == 0) {
    my $daemon = Mojo::Server::Daemon->new(
      app    => $mock_app,
      listen => ["http://127.0.0.1:$port"],
      silent => 1,
    );
    $daemon->run;
    exit 0;
  }

  push @mock_pids, $pid;
  my $url = "http://127.0.0.1:$port";
  _wait_for_ready($url);
  return $url;
}

sub _wait_for_ready {
  my ($base_url) = @_;
  my $ua = Mojo::UserAgent->new(max_redirects => 0);
  for (1 .. 100) {
    my $ok = eval {
      my $tx = $ua->get("$base_url/ready");
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
  ) or die "unable to allocate port: $!";
  my $port = $sock->sockport;
  close $sock;
  return $port;
}
