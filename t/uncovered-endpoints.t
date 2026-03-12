use v5.34;
use warnings;

use Config ();
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use MIME::Base64 qw(encode_base64);
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
  settings     => {
    base_url                   => 'http://127.0.0.1:7755',
    service_handle_domain      => 'example.test',
    service_did_method         => 'did:web',
    jwt_secret                 => 'uncovered-endpoints-secret',
    admin_password             => 'admin-secret',
    self_service_invite_codes  => 1,
    testing_auto_confirm_email => 1,
    data_dir                   => $tmp,
    db_path                    => File::Spec->catfile($tmp, 'perlsky.sqlite'),
  },
);

my $t = Test::Mojo->new($app);
my $admin_auth = 'Basic ' . encode_base64('admin:admin-secret', q());

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'alice.example.test',
  email    => 'alice@example.test',
  password => 'hunter22',
})->status_is(200);

my $created = $t->tx->res->json;
my $did     = $created->{did};
my $access  = $created->{accessJwt};

$t->post_ok('/xrpc/com.atproto.server.reserveSigningKey' => json => {})
  ->status_is(200)
  ->json_like('/signingKey' => qr/\Adid:key:/);

my $reserved_signing_key = $t->tx->res->json->{signingKey};

$t->post_ok('/xrpc/com.atproto.server.reserveSigningKey' => json => {
  did => 'did:plc:reserved-target',
})->status_is(200)
  ->json_like('/signingKey' => qr/\Adid:key:/);

my $reserved = $app->store->get_reserved_signing_key('did:plc:reserved-target');
ok($reserved && $reserved->{signing_key_did}, 'reserveSigningKey persists a reserved key for an explicit DID');
is($reserved->{signing_key_did}, $t->tx->res->json->{signingKey}, 'stored reserved key matches the returned signing key');

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'describe-repo',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'describe repo',
    createdAt => '2026-03-12T00:00:00Z',
  },
})->status_is(200)
  ->json_is('/uri' => "at://$did/app.bsky.feed.post/describe-repo");

$t->get_ok("/xrpc/com.atproto.repo.describeRepo?repo=$did")
  ->status_is(200)
  ->json_is('/did' => $did)
  ->json_is('/handle' => 'alice.example.test')
  ->json_is('/handleIsCorrect' => JSON::PP::true);

ok(
  scalar(grep { $_ eq 'app.bsky.feed.post' } @{ $t->tx->res->json->{collections} || [] }),
  'describeRepo lists created collections',
);

my $account = $app->store->get_account_by_did($did);
my $broken_doc = {
  %{ $account->{did_doc} || {} },
  alsoKnownAs => ['at://wrong.example.test'],
};
$app->store->update_account($did, did_doc => $broken_doc);

$t->get_ok("/xrpc/com.atproto.repo.describeRepo?repo=$did")
  ->status_is(200)
  ->json_is('/handleIsCorrect' => JSON::PP::false)
  ->json_is('/didDoc/alsoKnownAs/0' => 'at://wrong.example.test');

my $before_admin_handle_seq = $app->store->latest_event_seq;
{
  no warnings 'redefine';
  local *ATProto::PDS::API::Admin::resolve_handle_to_did = sub {
    my ($config, $handle) = @_;
    return $handle eq 'alice.external.test' ? $did : undef;
  };

  $t->post_ok('/xrpc/com.atproto.admin.updateAccountHandle' => {
    Authorization => $admin_auth,
  } => json => {
    did    => $did,
    handle => 'alice.external.test',
  })->status_is(200)
    ->json_is({});
}

my $handle_event = $app->store->list_events_from($before_admin_handle_seq + 1, limit => 1)->[0];
is($handle_event->{type}, 'identity', 'admin.updateAccountHandle appends an identity event');
is($handle_event->{payload}{handle}, 'alice.external.test', 'identity event carries the updated handle');

$t->post_ok('/xrpc/com.atproto.admin.updateAccountSigningKey' => {
  Authorization => $admin_auth,
} => json => {
  did        => $did,
  signingKey => $reserved_signing_key,
})->status_is(200)
  ->json_is({});

my $signing_event = $app->store->list_events_from($handle_event->{seq} + 1, limit => 1)->[0];
is($signing_event->{type}, 'identity', 'admin.updateAccountSigningKey appends an identity event');
is($signing_event->{payload}{handle}, 'alice.external.test', 'signing-key identity event keeps the current handle');

$t->post_ok('/xrpc/com.atproto.admin.updateAccountSigningKey' => {
  Authorization => $admin_auth,
} => json => {
  did        => $did,
  signingKey => 'did:key:not-a-real-key',
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest')
  ->json_is('/message' => 'signingKey must be a valid secp256k1 did:key');

$t->post_ok('/xrpc/com.atproto.server.createInviteCodes' => {
  Authorization => $admin_auth,
} => json => {
  codeCount => 2,
  useCount  => 3,
})->status_is(200)
  ->json_is('/codes/0/account' => 'admin');

is(scalar @{ $t->tx->res->json->{codes}[0]{codes} || [] }, 2, 'admin createInviteCodes returns the requested number of codes');

$t->post_ok('/xrpc/com.atproto.server.createInviteCodes' => {
  Authorization => "Bearer $access",
} => json => {
  codeCount   => 2,
  useCount    => 1,
  forAccounts => [$did],
})->status_is(200)
  ->json_is('/codes/0/account' => $did);

$t->post_ok('/xrpc/com.atproto.server.createInviteCodes' => {
  Authorization => "Bearer $access",
} => json => {
  codeCount   => 1,
  useCount    => 1,
  forAccounts => ['did:web:example.test:users:other'],
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest');

$t->post_ok('/xrpc/com.atproto.sync.notifyOfUpdate' => json => {
  hostname => 'crawler.example.test',
})->status_is(200)
  ->json_is({});

$t->get_ok('/xrpc/com.atproto.sync.getHostStatus' => form => {
  hostname => 'crawler.example.test',
})->status_is(200)
  ->json_is('/hostname' => 'crawler.example.test')
  ->json_is('/status' => 'active');

$t->post_ok('/xrpc/com.atproto.admin.updateAccountPassword' => {
  Authorization => $admin_auth,
} => json => {
  did      => $did,
  password => 'new-hunter22',
})->status_is(200)
  ->json_is({});

$t->get_ok('/xrpc/com.atproto.server.getSession' => {
  Authorization => "Bearer $access",
})->status_is(401);

$t->post_ok('/xrpc/com.atproto.server.createSession' => json => {
  identifier => 'alice.external.test',
  password   => 'new-hunter22',
})->status_is(200)
  ->json_has('/accessJwt');

$access = $t->tx->res->json->{accessJwt};

$t->post_ok('/xrpc/com.atproto.server.createAppPassword' => {
  Authorization => "Bearer $access",
} => json => {
  name => 'revoke-me',
})->status_is(200)
  ->json_like('/password' => qr/\w/);

my $app_password = $t->tx->res->json->{password};

$t->post_ok('/xrpc/com.atproto.temp.revokeAccountCredentials' => json => {
  account => $did,
})->status_is(401)
  ->json_is('/error' => 'AuthRequired');

$t->post_ok('/xrpc/com.atproto.temp.revokeAccountCredentials' => {
  Authorization => $admin_auth,
} => json => {
  account => $did,
})->status_is(200)
  ->json_is({});

$t->get_ok('/xrpc/com.atproto.server.getSession' => {
  Authorization => "Bearer $access",
})->status_is(401);

$t->post_ok('/xrpc/com.atproto.server.createSession' => json => {
  identifier => 'alice.example.test',
  password   => $app_password,
})->status_is(401)
  ->json_is('/error' => 'AuthRequired');

$t->post_ok('/xrpc/com.atproto.server.createSession' => json => {
  identifier => 'alice.example.test',
  password   => 'new-hunter22',
})->status_is(401)
  ->json_is('/error' => 'AuthRequired');

done_testing;
