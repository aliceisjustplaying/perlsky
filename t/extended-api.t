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

done_testing;
