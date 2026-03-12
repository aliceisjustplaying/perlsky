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

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $tmp  = tempdir(CLEANUP => 1);

my $app = ATProto::PDS->new(
  project_root => $root,
  settings => {
    base_url              => 'http://127.0.0.1:7755',
    service_handle_domain => 'example.test',
    service_did_method    => 'did:web',
    jwt_secret            => 'extended-secret',
    admin_password        => 'admin-secret',
    self_service_invite_codes => 1,
    testing_auto_confirm_email => 1,
    data_dir              => $tmp,
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

my $created = $t->tx->res->json;
my $access  = $created->{accessJwt};
my $did     = $created->{did};

$t->post_ok('/xrpc/com.atproto.server.createInviteCode' => {
  Authorization => "Bearer $access",
} => json => {
  useCount => 2,
})->status_is(200)
  ->json_has('/code');

my $invite_code = $t->tx->res->json->{code};

$t->post_ok('/xrpc/com.atproto.server.createInviteCode' => {
  Authorization => "Bearer $access",
} => json => {
  forAccount => 'did:web:example.test:users:someone-else',
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest');

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'apply-update-me',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'before applyWrites update',
    createdAt => '2026-03-11T00:00:00Z',
  },
})->status_is(200)
  ->json_has('/cid');

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'apply-delete-me',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'before applyWrites delete',
    createdAt => '2026-03-11T00:00:01Z',
  },
})->status_is(200);

$t->post_ok('/xrpc/com.atproto.repo.applyWrites' => {
  Authorization => "Bearer $access",
} => json => {
  repo   => $did,
  writes => [
    {
      '$type'     => 'com.atproto.repo.applyWrites#create',
      collection  => 'app.bsky.feed.post',
      value       => {
        '$type'   => 'app.bsky.feed.post',
        text      => 'applyWrites union smoke',
        createdAt => '2026-03-11T00:00:00Z',
      },
    },
    {
      '$type'     => 'com.atproto.repo.applyWrites#update',
      collection  => 'app.bsky.feed.post',
      rkey        => 'apply-update-me',
      value       => {
        '$type'   => 'app.bsky.feed.post',
        text      => 'after applyWrites update',
        createdAt => '2026-03-11T00:00:02Z',
      },
    },
    {
      '$type'     => 'com.atproto.repo.applyWrites#delete',
      collection  => 'app.bsky.feed.post',
      rkey        => 'apply-delete-me',
    },
  ],
})->status_is(200)
  ->json_is('/results/0/$type', 'com.atproto.repo.applyWrites#createResult')
  ->json_has('/results/0/uri')
  ->json_has('/results/0/cid')
  ->json_is('/results/1/$type', 'com.atproto.repo.applyWrites#updateResult')
  ->json_has('/results/1/uri')
  ->json_has('/results/1/cid')
  ->json_is('/results/2/$type', 'com.atproto.repo.applyWrites#deleteResult');

$t->get_ok("/xrpc/com.atproto.repo.getRecord?repo=$did&collection=app.bsky.feed.post&rkey=apply-update-me")
  ->status_is(200)
  ->json_is('/value/text' => 'after applyWrites update');

$t->get_ok("/xrpc/com.atproto.repo.getRecord?repo=$did&collection=app.bsky.feed.post&rkey=apply-delete-me")
  ->status_is(404)
  ->json_is('/error' => 'RecordNotFound');

$t->post_ok('/xrpc/com.atproto.repo.applyWrites' => {
  Authorization => "Bearer $access",
} => json => {
  repo   => $did,
  writes => [
    {
      '$type'     => 'com.atproto.repo.applyWrites#delete',
      collection  => 'app.bsky.feed.post',
      rkey        => 'missing-rkey-ok',
    },
  ],
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest');

$t->get_ok('/xrpc/com.atproto.server.getAccountInviteCodes' => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/codes/0/code', $invite_code);

$t->get_ok('/xrpc/com.atproto.admin.getAccountInfo' => {
  Authorization => $admin_auth,
} => form => {
  did => $did,
})->status_is(200)
  ->json_is('/did', $did)
  ->json_is('/handle', 'alice.example.test');

$t->post_ok('/xrpc/com.atproto.temp.addReservedHandle' => {
  Authorization => $admin_auth,
} => json => {
  handle => 'reserved.example.test',
})->status_is(200);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.temp.checkHandleAvailability')->query(
  handle => 'reserved.example.test',
))->status_is(200)
  ->json_is('/available', JSON::PP::false);

$t->post_ok('/xrpc/com.atproto.identity.updateHandle' => {
  Authorization => "Bearer $access",
} => json => {
  handle => 'alice-renamed.example.test',
})->status_is(200);

$t->post_ok('/xrpc/com.atproto.identity.refreshIdentity' => json => {
  identifier => 'alice-renamed.example.test',
})->status_is(200)
  ->json_is('/did', $did)
  ->json_is('/handle', 'alice-renamed.example.test');

$t->post_ok('/xrpc/com.atproto.server.requestEmailUpdate' => {
  Authorization => "Bearer $access",
} => json => {})->status_is(200);
ok($t->tx->res->json->{tokenRequired}, 'confirmed email requires update token');

my $email_update = $app->store->latest_action_token(
  did     => $did,
  purpose => 'email_update',
);

$t->post_ok('/xrpc/com.atproto.server.updateEmail' => {
  Authorization => "Bearer $access",
} => json => {
  email => 'alice+new@example.test',
  token => $email_update->{token},
})->status_is(200);

$t->post_ok('/xrpc/com.atproto.server.requestEmailConfirmation' => {
  Authorization => "Bearer $access",
} => json => {})->status_is(200);

my $email_confirm = $app->store->latest_action_token(
  did     => $did,
  purpose => 'email_confirm',
);

$t->post_ok('/xrpc/com.atproto.server.confirmEmail' => {
  Authorization => "Bearer $access",
} => json => {
  email => 'alice+new@example.test',
  token => $email_confirm->{token},
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

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'com.example.attach',
  record     => {
    '$type' => 'com.example.attach',
    blob    => $blob,
  },
})->status_is(200);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.listBlobs')->query(
  did => $did,
))->status_is(200)
  ->json_is('/cids/0', $blob_cid);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.getBlob')->query(
  did => $did,
  cid => $blob_cid,
))->status_is(200);
is($t->tx->res->body, 'blob-bytes', 'blob bytes are served back');
like($t->tx->res->headers->content_type // '', qr{image/png}, 'blob content type preserved');

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.getLatestCommit')->query(
  did => $did,
))->status_is(200)
  ->json_has('/cid');

my $commit_cid = $t->tx->res->json->{cid};

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.getBlocks')->query(
  did  => $did,
  cids => $commit_cid,
))->status_is(200);
like($t->tx->res->headers->content_type // '', qr{application/vnd\.ipld\.car}, 'block export is a CAR');

$t->post_ok('/xrpc/com.atproto.admin.updateSubjectStatus' => {
  Authorization => $admin_auth,
} => json => {
  subject  => { did => $did },
  takedown => { applied => JSON::PP::true, ref => 'unit-test' },
})->status_is(200);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.label.queryLabels')->query(
  uriPatterns => "at://$did*",
))->status_is(200);
ok(
  _find_label($t->tx->res->json->{labels}, val => '!hide'),
  'queryLabels includes the takedown label',
);

$t->get_ok('/xrpc/com.atproto.temp.fetchLabels?limit=10')
  ->status_is(200);
ok(
  _find_label($t->tx->res->json->{labels}, val => '!hide'),
  'fetchLabels includes the takedown label',
);

$t->post_ok('/xrpc/com.atproto.admin.updateSubjectStatus' => {
  Authorization => $admin_auth,
} => json => {
  subject  => { did => $did },
  takedown => { applied => JSON::PP::false, ref => 'unit-test' },
})->status_is(200);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.label.queryLabels')->query(
  uriPatterns => "at://$did*",
))->status_is(200);
ok(
  _find_label($t->tx->res->json->{labels}, val => '!hide', neg => JSON::PP::true),
  'queryLabels includes the negated takedown label',
);

$t->get_ok('/xrpc/com.atproto.temp.fetchLabels?limit=10')
  ->status_is(200);
ok(
  _find_label($t->tx->res->json->{labels}, val => '!hide', neg => JSON::PP::true),
  'fetchLabels includes the negated takedown label',
);

$t->post_ok('/xrpc/com.atproto.sync.requestCrawl' => json => {
  hostname => 'relay.example.test',
})->status_is(200);

$t->get_ok('/xrpc/com.atproto.sync.listHosts')
  ->status_is(200)
  ->json_is('/hosts/0/hostname', 'relay.example.test');

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.getHostStatus')->query(
  hostname => 'relay.example.test',
))->status_is(200)
  ->json_is('/hostname', 'relay.example.test');

done_testing;

sub _find_label {
  my ($labels, %expected) = @_;
  return 0 unless ref($labels) eq 'ARRAY';
  for my $label (@$labels) {
    next unless ref($label) eq 'HASH';
    my $matches = 1;
    for my $key (keys %expected) {
      next if defined($label->{$key}) && "$label->{$key}" eq "$expected{$key}";
      $matches = 0;
      last;
    }
    return 1 if $matches;
  }
  return 0;
}
