use v5.34;
use warnings;

use Config ();
use File::Path qw(remove_tree);
use File::Spec;
use FindBin qw($Bin);
use IO::Socket::INET;
use Mojo::Server::Daemon;
use Mojolicious;
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
use ATProto::PDS::Repo::CAR qw(read_car);

my @mock_pids;
END {
  my $status = $?;
  kill 'TERM', @mock_pids if @mock_pids;
  waitpid($_, 0) for @mock_pids;
  $? = $status;
}

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $tmp  = File::Spec->catdir($root, 'data', 'tmp-tests', 'repo-api');
remove_tree($tmp) if -d $tmp;

my $appview_app = Mojolicious->new;
$appview_app->routes->any('/xrpc/*nsid')->to(cb => sub {
  my ($c) = @_;
  return $c->render(text => 'ok') if ($c->stash('nsid') // q()) eq 'ready';
  if (($c->stash('nsid') // q()) eq 'com.atproto.repo.getRecord') {
    $c->res->headers->header('ETag' => 'W/"remote-record"');
    return $c->render(json => {
      uri   => 'at://did:plc:by3jhwdqgbtrcc7q4tkkv3cf/app.bsky.feed.post/3mgsm5nr5i22a',
      cid   => 'bafyreifakedremote',
      value => {
        '$type'   => 'app.bsky.feed.post',
        text      => 'remote record from appview fallback',
        createdAt => '2026-03-11T22:00:00Z',
      },
    });
  }
  $c->render(status => 404, json => {
    error => 'NotFound',
  });
});

my $appview_url = _start_mock_server($appview_app);

my $t = Test::Mojo->new(ATProto::PDS->new(
  project_root => $root,
  settings     => {
    base_url              => 'http://127.0.0.1:7755',
    service_did_method    => 'did:web',
    service_handle_domain => 'localhost',
    jwt_secret            => 'repo-secret',
    data_dir              => $tmp,
    db_path               => File::Spec->catfile($tmp, 'perlsky.sqlite'),
    bsky_appview_url      => $appview_url,
  },
));

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'repo-owner',
  email    => 'repo@example.com',
  password => 'password123',
})->status_is(200);

my $session = $t->tx->res->json;
my $did     = $session->{did};
my $access  = $session->{accessJwt};
my $refresh = $session->{refreshJwt};

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => { Authorization => "Bearer $access" } => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'first-post',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'hello from perl',
    createdAt => '2026-03-10T00:00:00Z',
  },
})->status_is(200)
  ->json_like('/cid' => qr/\Ab/);

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => { Authorization => "Bearer $access" } => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'first-post',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'duplicate create should fail',
    createdAt => '2026-03-10T00:00:30Z',
  },
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest');

$t->post_ok('/xrpc/com.atproto.repo.putRecord' => { Authorization => "Bearer $access" } => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'first-post',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'hello from updated perl',
    createdAt => '2026-03-10T00:02:00Z',
  },
})->status_is(200)
  ->json_is('/uri' => "at://$did/app.bsky.feed.post/first-post")
  ->json_like('/cid' => qr/\Ab/);
my $updated_cid = $t->tx->res->json->{cid};

$t->post_ok('/xrpc/com.atproto.repo.putRecord' => { Authorization => "Bearer $access" } => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'created-via-put',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'put created this record',
    createdAt => '2026-03-10T00:02:30Z',
  },
})->status_is(200)
  ->json_is('/uri' => "at://$did/app.bsky.feed.post/created-via-put")
  ->json_like('/cid' => qr/\Ab/);

$t->get_ok("/xrpc/com.atproto.sync.getLatestCommit?did=$did")
  ->status_is(200)
  ->json_like('/cid' => qr/\Ab/)
  ->json_has('/rev');
my $pre_noop_commit = $t->tx->res->json;

$t->post_ok('/xrpc/com.atproto.repo.putRecord' => { Authorization => "Bearer $access" } => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'first-post',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'hello from updated perl',
    createdAt => '2026-03-10T00:02:00Z',
  },
})->status_is(200)
  ->json_is('/uri' => "at://$did/app.bsky.feed.post/first-post")
  ->json_is('/cid' => $updated_cid);
my $noop_put = $t->tx->res->json;
ok(!exists($noop_put->{commit}), 'identical putRecord omits commit on no-op');

$t->get_ok("/xrpc/com.atproto.sync.getLatestCommit?did=$did")
  ->status_is(200)
  ->json_is('/cid' => $pre_noop_commit->{cid})
  ->json_is('/rev' => $pre_noop_commit->{rev});

$t->get_ok("/xrpc/com.atproto.repo.getRecord?repo=$did&collection=app.bsky.feed.post&rkey=created-via-put")
  ->status_is(200)
  ->json_is('/value/text' => 'put created this record');

$t->get_ok('/xrpc/com.atproto.repo.getRecord?repo=did:plc:by3jhwdqgbtrcc7q4tkkv3cf&collection=app.bsky.feed.post&rkey=3mgsm5nr5i22a')
  ->status_is(200)
  ->header_is('ETag' => 'W/"remote-record"')
  ->json_is('/value/text' => 'remote record from appview fallback');

$t->get_ok("/xrpc/com.atproto.sync.getLatestCommit?did=$did")
  ->status_is(200)
  ->json_like('/cid' => qr/\Ab/)
  ->json_has('/rev');
my $pre_refresh_attempt_commit = $t->tx->res->json;

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => { Authorization => "Bearer $refresh" } => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'refresh-post',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'refresh tokens are not access tokens',
    createdAt => '2026-03-10T00:01:00Z',
  },
})->status_is(401)
  ->json_is('/error' => 'InvalidToken');

$t->get_ok("/xrpc/com.atproto.repo.getRecord?repo=$did&collection=app.bsky.feed.post&rkey=refresh-post")
  ->status_is(404)
  ->json_is('/error' => 'RecordNotFound');

$t->get_ok("/xrpc/com.atproto.sync.getLatestCommit?did=$did")
  ->status_is(200)
  ->json_is('/cid' => $pre_refresh_attempt_commit->{cid})
  ->json_is('/rev' => $pre_refresh_attempt_commit->{rev});

$t->get_ok("/xrpc/com.atproto.repo.getRecord?repo=$did&collection=app.bsky.feed.post&rkey=first-post")
  ->status_is(200)
  ->json_is('/value/text' => 'hello from updated perl');

$t->get_ok("/xrpc/com.atproto.repo.listRecords?repo=$did&collection=app.bsky.feed.post")
  ->status_is(200)
  ->json_is('/records/0/value/text' => 'put created this record')
  ->json_is('/records/1/value/text' => 'hello from updated perl');

$t->get_ok('/xrpc/com.atproto.repo.listRecords?repo=Repo-Owner.Localhost&collection=app.bsky.feed.post')
  ->status_is(200)
  ->json_is('/records/0/value/text' => 'put created this record')
  ->json_is('/records/1/value/text' => 'hello from updated perl');

$t->get_ok("/xrpc/com.atproto.sync.getLatestCommit?did=$did")
  ->status_is(200)
  ->json_like('/cid' => qr/\Ab/)
  ->json_has('/rev');
my $latest_commit_cid = $t->tx->res->json->{cid};

$t->get_ok("/xrpc/com.atproto.sync.getRecord?did=$did&collection=app.bsky.feed.post&rkey=first-post")
  ->status_is(200)
  ->content_type_like(qr{application/vnd\.ipld\.car});
my $record_proof = read_car($t->tx->res->body);
is($record_proof->{roots}[0]->to_string, $latest_commit_cid, 'sync.getRecord roots the latest commit');
ok(
  scalar(grep { $_->{cid}->to_string eq $updated_cid } @{ $record_proof->{blocks} || [] }),
  'sync.getRecord proof includes the current record block',
);

$t->get_ok("/xrpc/com.atproto.sync.getRepoStatus?did=$did")
  ->status_is(200)
  ->json_is('/did' => $did)
  ->json_has('/active');

$t->get_ok('/xrpc/com.atproto.sync.listRepos')
  ->status_is(200)
  ->json_is('/repos/0/did' => $did);

$t->get_ok("/xrpc/com.atproto.sync.getRepo?did=$did")
  ->status_is(200)
  ->content_type_like(qr{application/vnd\.ipld\.car})
  ->content_like(qr/.+/s);

$t->get_ok("/xrpc/com.atproto.sync.getCheckout?did=$did")
  ->status_is(200)
  ->content_type_like(qr{application/vnd\.ipld\.car})
  ->content_like(qr/.+/s);

$t->get_ok("/xrpc/com.atproto.sync.getHead?did=$did")
  ->status_is(200)
  ->json_like('/root' => qr/\Ab/);

$t->post_ok('/xrpc/com.atproto.repo.deleteRecord' => { Authorization => "Bearer $access" } => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'first-post',
})->status_is(200);

$t->get_ok("/xrpc/com.atproto.repo.getRecord?repo=$did&collection=app.bsky.feed.post&rkey=first-post")
  ->status_is(404)
  ->json_is('/error' => 'RecordNotFound');

$t->get_ok("/xrpc/com.atproto.sync.getRecord?did=$did&collection=app.bsky.feed.post&rkey=first-post")
  ->status_is(200)
  ->content_type_like(qr{application/vnd\.ipld\.car});
my $missing_record_proof = read_car($t->tx->res->body);
ok(@{ $missing_record_proof->{blocks} || [] } >= 2, 'missing sync proof still includes commit and MST blocks');
ok(
  !scalar(grep { $_->{cid}->to_string eq $updated_cid } @{ $missing_record_proof->{blocks} || [] }),
  'missing sync proof omits the deleted record block',
);

$t->get_ok("/xrpc/com.atproto.sync.getLatestCommit?did=$did")
  ->status_is(200)
  ->json_like('/cid' => qr/\Ab/)
  ->json_has('/rev');
my $pre_missing_delete_commit = $t->tx->res->json;

$t->post_ok('/xrpc/com.atproto.repo.deleteRecord' => { Authorization => "Bearer $access" } => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'first-post',
})->status_is(200)
  ->json_is({});

$t->get_ok("/xrpc/com.atproto.sync.getLatestCommit?did=$did")
  ->status_is(200)
  ->json_is('/cid' => $pre_missing_delete_commit->{cid})
  ->json_is('/rev' => $pre_missing_delete_commit->{rev});

done_testing;

sub _start_mock_server {
  my ($app) = @_;
  my $listen = IO::Socket::INET->new(
    Listen    => 5,
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Proto     => 'tcp',
    ReuseAddr => 1,
  ) or die "listen socket: $!";
  my $port = $listen->sockport;
  close $listen;

  my $pid = fork();
  die "fork failed: $!" unless defined $pid;
  if ($pid == 0) {
    my $daemon = Mojo::Server::Daemon->new(
      app    => $app,
      listen => ["http://127.0.0.1:$port"],
      silent => 1,
    );
    $daemon->run;
    exit 0;
  }

  push @mock_pids, $pid;
  my $url = "http://127.0.0.1:$port";
  my $ready = 0;
  for (1 .. 50) {
    if (eval {
      require Mojo::UserAgent;
      my $tx = Mojo::UserAgent->new(max_redirects => 0)->get("$url/xrpc/ready");
      ($tx->result->code // 0) == 200;
    }) {
      $ready = 1;
      last;
    }
    select undef, undef, undef, 0.05;
  }
  die "mock server failed to start on $url" unless $ready;
  return $url;
}
