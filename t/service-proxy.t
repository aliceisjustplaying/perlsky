use v5.34;
use warnings;

use Config ();
use File::Path qw(remove_tree);
use File::Spec;
use FindBin qw($Bin);
use JSON::PP qw(decode_json);
use MIME::Base64 qw(decode_base64);
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

use Crypt::PK::ECC;
use IO::Socket::INET;
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
my $tmp  = File::Spec->catdir($root, 'data', 'tmp-tests', 'service-proxy');
remove_tree($tmp) if -d $tmp;

my $appview_app = Mojolicious->new;
$appview_app->routes->get('/ready')->to(cb => sub {
  my ($c) = @_;
  $c->render(text => 'ok');
});
$appview_app->routes->any('/xrpc/*nsid')->to(cb => sub {
  my ($c) = @_;
  my $nsid = $c->stash('nsid');
  my %body = (
    nsid => $nsid,
    auth => $c->req->headers->authorization,
  );
  $body{country} = $c->param('countryCode') if defined $c->param('countryCode');
  $body{region}  = $c->param('regionCode')  if defined $c->param('regionCode');
  if ($nsid eq 'app.bsky.actor.getPreferences') {
    $body{preferences} = [{
      '$type' => 'app.bsky.actor.defs#savedFeedsPref',
      pinned  => [],
      saved   => [],
    }];
  }
  $c->render(json => \%body);
});

my $chat_app = Mojolicious->new;
$chat_app->routes->get('/ready')->to(cb => sub {
  my ($c) = @_;
  $c->render(text => 'ok');
});
$chat_app->routes->any('/xrpc/*nsid')->to(cb => sub {
  my ($c) = @_;
  $c->render(json => {
    nsid => $c->stash('nsid'),
    auth => $c->req->headers->authorization,
    logs => [],
  });
});

my $appview_url = _start_mock_server($appview_app);
my $chat_url    = _start_mock_server($chat_app);

my $app = ATProto::PDS->new(
  project_root => $root,
  settings     => {
    base_url              => 'http://127.0.0.1:7755',
    service_did_method    => 'did:web',
    service_handle_domain => 'localhost',
    jwt_secret            => 'proxy-secret',
    data_dir              => $tmp,
    db_path               => File::Spec->catfile($tmp, 'perlsky.sqlite'),
    bsky_appview_url      => $appview_url,
    bsky_appview_did      => 'did:web:appview.test',
    chat_service_url      => $chat_url,
    chat_service_did      => 'did:web:chat.test',
  },
);
my $t = Test::Mojo->new($app);

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'alice',
  email    => 'alice@example.com',
  password => 'password123',
})->status_is(200)
  ->json_has('/accessJwt')
  ->json_has('/did');

my $created = $t->tx->res->json;
my $access  = $created->{accessJwt};
my $did     = $created->{did};
my $account = $app->store->get_account_by_did($did);

$t->get_ok('/xrpc/app.bsky.ageassurance.getState?countryCode=GB&regionCode=ENG')
  ->status_is(200)
  ->json_is('/nsid' => 'app.bsky.ageassurance.getState')
  ->json_is('/country' => 'GB')
  ->json_is('/region' => 'ENG');

ok(!defined($t->tx->res->json->{auth}), 'anonymous appview request does not forward auth');

$t->get_ok('/xrpc/app.bsky.actor.getPreferences' => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/preferences/0/$type' => 'app.bsky.actor.defs#savedFeedsPref');

my $appview_auth = _decode_bearer($t->tx->res->json->{auth});
is($appview_auth->{header}{alg}, 'ES256K', 'appview proxy auth uses ES256K');
is($appview_auth->{claims}{iss}, $did, 'appview proxy auth is issued by the account DID');
is($appview_auth->{claims}{aud}, 'did:web:appview.test', 'appview proxy auth targets the appview DID');
is($appview_auth->{claims}{lxm}, 'app.bsky.actor.getPreferences', 'appview proxy auth binds the proxied method');
ok(_verify_es256k($account->{public_key}, $appview_auth->{signing_input}, $appview_auth->{signature}), 'appview proxy auth signature verifies');

$t->get_ok('/xrpc/chat.bsky.convo.getLog' => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/logs' => [])
  ->json_is('/nsid' => 'chat.bsky.convo.getLog');

my $chat_auth = _decode_bearer($t->tx->res->json->{auth});
is($chat_auth->{claims}{aud}, 'did:web:chat.test', 'chat proxy auth targets the chat DID');
is($chat_auth->{claims}{lxm}, 'chat.bsky.convo.getLog', 'chat proxy auth binds the chat method');
ok(_verify_es256k($account->{public_key}, $chat_auth->{signing_input}, $chat_auth->{signature}), 'chat proxy auth signature verifies');

$t->get_ok('/xrpc/app.bsky.actor.getPreferences' => {
  Authorization   => "Bearer $access",
  'Atproto-Proxy' => 'did:web:appview.test#bsky_appview',
})->status_is(200)
  ->json_is('/nsid' => 'app.bsky.actor.getPreferences');

$t->get_ok('/xrpc/example.unsupported.method')
  ->status_is(404)
  ->json_is('/error' => 'UnknownMethod');

done_testing;

sub _decode_bearer {
  my ($header) = @_;
  like($header // q(), qr/\ABearer\s+/, 'upstream request includes bearer auth');
  my ($token) = $header =~ /\ABearer\s+(.+)\z/;
  my ($header_b64, $claims_b64, $sig_b64) = split /\./, $token, 3;
  return {
    header        => decode_json(_b64url_decode($header_b64)),
    claims        => decode_json(_b64url_decode($claims_b64)),
    signature     => _b64url_decode($sig_b64),
    signing_input => "$header_b64.$claims_b64",
  };
}

sub _b64url_decode {
  my ($text) = @_;
  my $copy = $text;
  $copy =~ tr/-_/+\//;
  my $pad = length($copy) % 4;
  $copy .= '=' x (4 - $pad) if $pad;
  return decode_base64($copy);
}

sub _verify_es256k {
  my ($public_key, $message, $signature) = @_;
  my $pk = Crypt::PK::ECC->new;
  $pk->import_key_raw($public_key, 'secp256k1');
  return $pk->verify_message_rfc7518($signature, $message, 'SHA256');
}

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
    if ($ok) {
      return 1;
    }
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
