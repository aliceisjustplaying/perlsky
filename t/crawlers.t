use v5.34;
use warnings;
use Config ();
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use IO::Socket::INET;
use JSON::PP qw(decode_json);
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

use Mojo::URL;
use Mojo::UserAgent;
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

sub spawn_crawler_mock {
  my ($ready_file, $log_file, $port) = @_;
  my $pid = fork;
  die "fork failed: $!" unless defined $pid;

  if ($pid == 0) {
    open STDOUT, '>', $log_file or die "open($log_file): $!";
    open STDERR, '>&', \*STDOUT or die "dup stdout failed";
    chdir $root or die "chdir($root): $!";
    $ENV{PERLDS_READY_FILE}   = $ready_file;
    $ENV{PERLDS_CRAWLER_PORT} = $port;
    $ENV{PERLDS_CRAWLER_HOST} = '127.0.0.1';
    exec 'fnm', 'exec', '--using=20', '--', 'node',
      File::Spec->catfile($root, 'tools', 'differential', 'crawler-mock.cjs');
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

sub crawler_state {
  my ($origin) = @_;
  my $res = Mojo::UserAgent->new(max_redirects => 0)->get("$origin/requests")->result;
  die "crawler state fetch failed for $origin" unless $res->is_success;
  return $res->json || {};
}

sub wait_for_requests {
  my ($origin, $minimum, $timeout) = @_;
  $minimum //= 1;
  $timeout //= 10;
  my $deadline = time + $timeout;
  while (time < $deadline) {
    my $state = eval { crawler_state($origin) };
    if ($state && (($state->{count} // 0) >= $minimum)) {
      return $state;
    }
    sleep 0.1;
  }
  die "timed out waiting for crawler requests at $origin";
}

my $crawler_port  = free_port();
my $crawler_ready = File::Spec->catfile($tmp, 'crawler.ready.json');
my $crawler_log   = File::Spec->catfile($tmp, 'crawler.log');
spawn_crawler_mock($crawler_ready, $crawler_log, $crawler_port);
my $crawler = wait_for_ready($crawler_ready);

my $app = ATProto::PDS->new(
  project_root => $root,
  settings     => {
    base_url                => 'http://127.0.0.1:7755',
    service_handle_domain   => 'test',
    service_did_method      => 'did:web',
    jwt_secret              => 'crawl-secret',
    admin_password          => 'admin-secret',
    crawlers                => [$crawler->{origin}],
    crawler_notify_interval => 3600,
    db_path                 => File::Spec->catfile($tmp, 'crawlers.sqlite'),
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
my $access  = $created->{accessJwt};
my $did     = $created->{did};

my $state = wait_for_requests($crawler->{origin});
is($state->{requests}[0]{body}{hostname}, '127.0.0.1', 'crawl requests use the public hostname without the port');

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'crawler-test',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'crawler notification test',
    createdAt => '2026-03-10T00:00:00Z',
  },
})->status_is(200);

sleep 0.5;
$state = crawler_state($crawler->{origin});
is($state->{count}, 1, 'crawler notifications are throttled inside the configured interval');

my $crawler_url = Mojo::URL->new($crawler->{origin});
my $crawler_host = lc($crawler_url->host // '127.0.0.1');
$crawler_host .= ':' . $crawler_url->port if defined($crawler_url->port) && $crawler_url->port != 80;

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.getHostStatus')->query(
  hostname => $crawler_host,
))->status_is(200)
  ->json_is('/hostname', $crawler_host)
  ->json_is('/status', 'active');

done_testing;
