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

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'bob.example.test',
  email    => 'bob@example.test',
  password => 'hunter22',
})->status_is(200);
my $bob = $t->tx->res->json;

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
    handle => $bob->{handle},
  })->status_is(400)
    ->json_is('/error' => 'InvalidRequest')
    ->json_is('/message' => 'Handle already taken: bob.example.test');

  $t->post_ok('/xrpc/com.atproto.admin.updateAccountHandle' => {
    Authorization => $admin_auth,
  } => json => {
    did    => $did,
    handle => 'alice.external.test',
  })->status_is(200)
    ->content_is(q());
}

my $handle_event = $app->store->list_events_from($before_admin_handle_seq + 1, limit => 1)->[0];
is($handle_event->{type}, 'identity', 'admin.updateAccountHandle appends an identity event');
is($handle_event->{payload}{handle}, 'alice.external.test', 'identity event carries the updated handle');

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.admin.getAccountInfos')->query(
  dids => [ $did, 'did:web:example.test:users:missing' ],
) => {
  Authorization => $admin_auth,
})->status_is(200)
  ->json_is('/infos/0/did' => $did)
  ->json_is('/infos/0/handle' => 'alice.external.test');

is(scalar @{ $t->tx->res->json->{infos} || [] }, 1, 'getAccountInfos returns only existing accounts');

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.admin.getAccountInfo')->query(
  did => 'did:web:missing.test',
) => {
  Authorization => $admin_auth,
})->status_is(400)
  ->json_is('/error' => 'NotFound')
  ->json_is('/message' => 'Account not found');

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.admin.searchAccounts')->query(
  email => 'ALICE@EXAMPLE.TEST',
) => {
  Authorization => $admin_auth,
})->status_is(200)
  ->json_is('/accounts/0/did' => $did);

$t->post_ok('/xrpc/com.atproto.admin.updateAccountEmail' => {
  Authorization => $admin_auth,
} => json => {
  account => $did,
  email   => 'Alice+Admin@Example.Test',
})->status_is(200)
  ->content_is(q());

$account = $app->store->get_account_by_did($did);
is($account->{email}, 'alice+admin@example.test', 'admin.updateAccountEmail normalizes email');
ok(!defined($account->{email_confirmed_at}), 'admin.updateAccountEmail clears email confirmation state');

$t->post_ok('/xrpc/com.atproto.admin.updateAccountEmail' => {
  Authorization => $admin_auth,
} => json => {
  account => 'did:web:missing.test',
  email   => 'missing@example.test',
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest')
  ->json_is('/message' => 'Account does not exist: did:web:missing.test');

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.admin.getAccountInfo')->query(
  did => $did,
) => {
  Authorization => $admin_auth,
})->status_is(200)
  ->json_is('/email' => 'alice+admin@example.test');

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.admin.getSubjectStatus')->query(
  did => $did,
) => {
  Authorization => $admin_auth,
})->status_is(200)
  ->json_is('/subject/did' => $did)
  ->json_is('/subject/$type' => 'com.atproto.admin.defs#repoRef')
  ->json_is('/takedown/applied' => JSON::PP::false)
  ->json_is('/deactivated/applied' => JSON::PP::false);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.admin.getSubjectStatus')->query(
  did => 'did:web:missing.test',
) => {
  Authorization => $admin_auth,
})->status_is(400)
  ->json_is('/error' => 'NotFound')
  ->json_is('/message' => 'Subject not found');

$t->get_ok('/xrpc/com.atproto.admin.getSubjectStatus' => {
  Authorization => $admin_auth,
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest')
  ->json_is('/message' => 'No provided subject');

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.admin.getSubjectStatus')->query(
  blob => 'bafkqaaa',
) => {
  Authorization => $admin_auth,
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest')
  ->json_is('/message' => 'Must provide a did to request blob state');

$t->post_ok('/xrpc/com.atproto.admin.sendEmail' => {
  Authorization => $admin_auth,
} => json => {
  recipientDid => $did,
  content      => 'hello from perlsky',
})->status_is(200)
  ->json_is('/sent' => JSON::PP::true);

my $outbound = $app->store->dbh->selectrow_hashref(
  q{SELECT * FROM outbound_emails WHERE recipient_did = ? ORDER BY id DESC LIMIT 1},
  undef,
  $did,
);
ok($outbound, 'admin.sendEmail logs an outbound email');
is($outbound->{subject}, 'Message via your PDS', 'admin.sendEmail uses the reference default subject');
is($outbound->{recipient_email}, 'alice+admin@example.test', 'admin.sendEmail uses the updated normalized email');

$t->post_ok('/xrpc/com.atproto.admin.updateAccountSigningKey' => {
  Authorization => $admin_auth,
} => json => {
  did        => $did,
  signingKey => $reserved_signing_key,
})->status_is(200)
  ->content_is(q());

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

my $before_missing_delete_seq = $app->store->latest_event_seq;
$t->post_ok('/xrpc/com.atproto.admin.deleteAccount' => {
  Authorization => $admin_auth,
} => json => {
  did => 'did:web:missing.test',
})->status_is(200)
  ->content_is('');

my $missing_delete_event = $app->store->list_events_from($before_missing_delete_seq + 1, limit => 1)->[0];
is($missing_delete_event->{type}, 'account', 'admin.deleteAccount missing DID still appends an account event');
is($missing_delete_event->{did}, 'did:web:missing.test', 'missing delete event identifies the requested DID');
ok(!$missing_delete_event->{payload}{active}, 'missing delete event marks the account inactive');
is($missing_delete_event->{payload}{status}, 'deleted', 'missing delete event reports deleted status');

$t->post_ok('/xrpc/com.atproto.sync.notifyOfUpdate' => json => {
  hostname => 'crawler.example.test',
})->status_is(200)
  ->content_is(q());

$t->get_ok('/xrpc/com.atproto.sync.getHostStatus' => form => {
  hostname => 'crawler.example.test',
})->status_is(200)
  ->json_is('/hostname' => 'crawler.example.test')
  ->json_is('/status' => 'active');

$t->post_ok('/xrpc/com.atproto.admin.sendEmail' => {
  Authorization => $admin_auth,
} => json => {
  recipientDid => $did,
  subject      => 'Hello',
  content      => 'Testing',
})->status_is(200)
  ->json_is('/sent' => JSON::PP::true);

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'noemail.example.test',
  password => 'hunter22',
})->status_is(200);

my $noemail_did = $t->tx->res->json->{did};

$t->post_ok('/xrpc/com.atproto.admin.sendEmail' => {
  Authorization => $admin_auth,
} => json => {
  recipientDid => $noemail_did,
  subject      => 'Hello',
  content      => 'Testing',
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest');

$t->post_ok('/xrpc/com.atproto.admin.sendEmail' => {
  Authorization => $admin_auth,
} => json => {
  recipientDid => 'did:web:example.test:users:missing',
  subject      => 'Hello',
  content      => 'Testing',
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest')
  ->json_is('/message' => 'Recipient not found');

$t->post_ok('/xrpc/com.atproto.admin.updateAccountPassword' => {
  Authorization => $admin_auth,
} => json => {
  did      => $did,
  password => 'short',
})->status_is(200)
  ->content_is(q());

$t->post_ok('/xrpc/com.atproto.server.createSession' => json => {
  identifier => 'alice.external.test',
  password   => 'short',
})->status_is(200)
  ->json_has('/accessJwt');

$t->post_ok('/xrpc/com.atproto.admin.updateAccountPassword' => {
  Authorization => $admin_auth,
} => json => {
  did      => $did,
  password => 'new-hunter22',
})->status_is(200)
  ->content_is(q());

$t->post_ok('/xrpc/com.atproto.admin.updateAccountPassword' => {
  Authorization => $admin_auth,
} => json => {
  did      => 'did:web:missing.test',
  password => 'new-hunter22',
})->status_is(200)
  ->content_is(q());

$t->get_ok('/xrpc/com.atproto.server.getSession' => {
  Authorization => "Bearer $access",
})->status_is(401);

$t->post_ok('/xrpc/com.atproto.server.createSession' => json => {
  identifier => 'alice.external.test',
  password   => 'new-hunter22',
})->status_is(200)
  ->json_has('/accessJwt');

done_testing;
