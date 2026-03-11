use v5.34;
use warnings;

use Config ();
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use JSON::PP ();
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
use Mojo::URL;
use ATProto::PDS;
use ATProto::PDS::Repo::CAR qw(read_car);

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $tmp  = tempdir(CLEANUP => 1);

my $app = ATProto::PDS->new(
  project_root => $root,
  settings => {
    base_url              => 'http://127.0.0.1:7755',
    service_handle_domain => 'example.test',
    service_did_method    => 'did:web',
    jwt_secret            => 'moderation-secret',
    admin_password        => 'admin-secret',
    data_dir              => File::Spec->catdir($tmp, 'data'),
    db_path               => File::Spec->catfile($tmp, 'perlsky.sqlite'),
  },
);

my $t = Test::Mojo->new($app);
my $admin_auth = 'Basic YWRtaW46YWRtaW4tc2VjcmV0';

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'alice.example.test',
  email    => 'alice@example.test',
  password => 'hunter22',
})->status_is(200);

my $session = $t->tx->res->json;
my $did     = $session->{did};
my $access  = $session->{accessJwt};

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'visible-post',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'visible',
    createdAt => '2026-03-10T00:00:00Z',
  },
})->status_is(200)
  ->json_is('/uri', "at://$did/app.bsky.feed.post/visible-post");

my $record_cid = $t->tx->res->json->{cid};

$t->post_ok('/xrpc/com.atproto.admin.updateSubjectStatus' => {
  Authorization => $admin_auth,
} => json => {
  subject  => { uri => "at://$did/app.bsky.feed.post/visible-post", cid => $record_cid },
  takedown => { applied => JSON::PP::true },
})->status_is(200)
  ->json_is('/subject/uri', "at://$did/app.bsky.feed.post/visible-post");

$t->get_ok("/xrpc/com.atproto.repo.getRecord?repo=$did&collection=app.bsky.feed.post&rkey=visible-post")
  ->status_is(404)
  ->json_is('/error', 'RecordNotFound');

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.repo.listRecords')->query(
  repo       => $did,
  collection => 'app.bsky.feed.post',
))->status_is(200)
  ->json_is('/records', []);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.getRecord')->query(
  did        => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'visible-post',
))->status_is(200)
  ->content_type_like(qr{application/vnd\.ipld\.car});
my $sync_record_proof = read_car($t->tx->res->body);
ok(
  scalar(grep { $_->{cid}->to_string eq $record_cid } @{ $sync_record_proof->{blocks} || [] }),
  'sync.getRecord still exposes a proof CAR for taken-down records',
);

$t->post_ok('/xrpc/com.atproto.admin.updateSubjectStatus' => {
  Authorization => $admin_auth,
} => json => {
  subject  => { did => $did },
  takedown => { applied => JSON::PP::true },
})->status_is(200);

$t->post_ok('/xrpc/com.atproto.server.createSession' => json => {
  identifier => 'alice.example.test',
  password   => 'hunter22',
})->status_is(401)
  ->json_is('/error', 'AccountTakedown');

$t->post_ok('/xrpc/com.atproto.server.createSession' => json => {
  identifier      => 'alice.example.test',
  password        => 'hunter22',
  allowTakendown  => JSON::PP::true,
})->status_is(200);

my $takedown_access = $t->tx->res->json->{accessJwt};

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $takedown_access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'blocked-post',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'blocked',
    createdAt => '2026-03-10T00:00:01Z',
  },
})->status_is(400)
  ->json_is('/error', 'InvalidToken')
  ->json_is('/message', 'Bad token scope');

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.repo.listRecords')->query(
  repo       => $did,
  collection => 'app.bsky.feed.post',
))->status_is(400)
  ->json_is('/error', 'InvalidRequest');

$t->post_ok('/xrpc/com.atproto.moderation.createReport' => {
  Authorization => "Bearer $takedown_access",
} => json => {
  reasonType => 'com.atproto.moderation.defs#reasonRude',
  reason     => 'not allowed while takendown',
  subject    => { did => 'did:web:elsewhere.test' },
})->status_is(403)
  ->json_is('/message', 'Report not accepted from takendown account');

$t->post_ok('/xrpc/com.atproto.moderation.createReport' => {
  Authorization => "Bearer $takedown_access",
} => json => {
  reasonType => 'com.atproto.moderation.defs#reasonAppeal',
  reason     => 'please restore',
  subject    => { did => $did },
})->status_is(200)
  ->json_is('/reasonType', 'com.atproto.moderation.defs#reasonAppeal');

$t->post_ok('/xrpc/com.atproto.admin.updateSubjectStatus' => {
  Authorization => $admin_auth,
} => json => {
  subject  => { did => $did },
  takedown => { applied => JSON::PP::false },
})->status_is(200);

my $blob_tx = $t->ua->build_tx(
  POST => '/xrpc/com.atproto.repo.uploadBlob' => {
    Authorization => "Bearer $access",
    'Content-Type' => 'image/png',
  } => 'blob-bytes',
);
$t->request_ok($blob_tx)->status_is(200);

my $blob = $t->tx->res->json->{blob};
my $blob_cid = $blob->{ref}{'$link'};

$t->post_ok('/xrpc/com.atproto.admin.updateSubjectStatus' => {
  Authorization => $admin_auth,
} => json => {
  subject  => { did => $did, cid => $blob_cid },
  takedown => { applied => JSON::PP::true },
})->status_is(200)
  ->json_is('/subject/cid', $blob_cid);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.getBlob')->query(
  did => $did,
  cid => $blob_cid,
))->status_is(404)
  ->json_is('/error', 'BlobNotFound');

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.getBlob')->query(
  did => $did,
  cid => $blob_cid,
) => {
  Authorization => "Bearer $access",
})->status_is(404)
  ->json_is('/error', 'BlobNotFound');

my $blocked_blob_upload = $t->ua->build_tx(
  POST => '/xrpc/com.atproto.repo.uploadBlob' => {
    Authorization => "Bearer $access",
    'Content-Type' => 'image/png',
  } => 'blob-bytes',
);
$t->request_ok($blocked_blob_upload)->status_is(400)
  ->json_is('/error', 'BlobTakenDown');

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'blob-ref',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'blob ref',
    createdAt => '2026-03-10T00:00:02Z',
    embed     => {
      image => $blob,
    },
  },
})->status_is(400)
  ->json_is('/error', 'BlobTakenDown');

$t->get_ok('/xrpc/com.atproto.admin.getSubjectStatus' => {
  Authorization => $admin_auth,
} => form => {
  did  => $did,
  blob => $blob_cid,
})->status_is(200)
  ->json_is('/subject/cid', $blob_cid)
  ->json_is('/takedown/applied', JSON::PP::true);

$t->post_ok('/xrpc/com.atproto.admin.updateSubjectStatus' => {
  Authorization => $admin_auth,
} => json => {
  subject  => { did => $did, cid => $blob_cid },
  takedown => { applied => JSON::PP::false },
})->status_is(200)
  ->json_is('/subject/cid', $blob_cid)
  ->json_is('/takedown/applied', JSON::PP::false);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.getBlob')->query(
  did => $did,
  cid => $blob_cid,
))->status_is(200);
is($t->tx->res->body, 'blob-bytes', 'restored blob is served again');

done_testing;
