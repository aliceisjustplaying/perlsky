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
    jwt_secret                 => 'invite-admin-secret',
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

my $alice  = $t->tx->res->json;
my $did    = $alice->{did};
my $access = $alice->{accessJwt};

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'bob.example.test',
  email    => 'bob@example.test',
  password => 'hunter22',
})->status_is(200);

my $bob = $t->tx->res->json;

$t->post_ok('/xrpc/com.atproto.server.createInviteCodes' => {
  Authorization => $admin_auth,
} => json => {
  codeCount => 2,
  useCount  => 3,
})->status_is(200)
  ->json_is('/codes/0/account' => 'admin');

my @admin_codes = @{ $t->tx->res->json->{codes}[0]{codes} || [] };
is(scalar @admin_codes, 2, 'admin createInviteCodes returns the requested number of codes');

$app->store->create_invite_code(
  code        => 'perlsky-audit-used',
  for_account => 'admin',
  created_by  => 'admin',
  use_count   => 2,
  created_at  => 4_102_444_700,
);
$app->store->create_invite_code(
  code        => 'perlsky-audit-unused',
  for_account => 'admin',
  created_by  => 'admin',
  use_count   => 1,
  created_at  => 4_102_444_800,
);
$app->store->create_invite_code(
  code        => 'perlsky-audit-tie-b',
  for_account => 'admin',
  created_by  => 'admin',
  use_count   => 1,
  created_at  => 4_102_444_850,
);
$app->store->create_invite_code(
  code        => 'perlsky-audit-tie-a',
  for_account => 'admin',
  created_by  => 'admin',
  use_count   => 1,
  created_at  => 4_102_444_850,
);
$app->store->record_invite_code_use(
  code    => 'perlsky-audit-used',
  used_by => $did,
  used_at => 4_102_444_900,
);
$app->store->record_invite_code_use(
  code    => 'perlsky-audit-used',
  used_by => $bob->{did},
  used_at => 4_102_445_000,
);

$t->get_ok('/xrpc/com.atproto.admin.getInviteCodes?sort=recent&limit=2' => {
  Authorization => $admin_auth,
})->status_is(200)
  ->json_is('/codes/0/code' => 'perlsky-audit-tie-a')
  ->json_is('/codes/1/code' => 'perlsky-audit-tie-b')
  ->json_has('/cursor');

my $recent_cursor = $t->tx->res->json->{cursor};
$t->get_ok("/xrpc/com.atproto.admin.getInviteCodes?sort=recent&limit=2&cursor=$recent_cursor" => {
  Authorization => $admin_auth,
})->status_is(200)
  ->json_is('/codes/0/code' => 'perlsky-audit-unused')
  ->json_is('/codes/1/code' => 'perlsky-audit-used')
  ->json_has('/cursor');

$t->get_ok('/xrpc/com.atproto.admin.getInviteCodes?sort=usage&limit=20' => {
  Authorization => $admin_auth,
})->status_is(200)
  ->json_is('/codes/0/code' => 'perlsky-audit-used')
  ->json_is('/codes/0/available' => 2)
  ->json_is('/codes/0/uses/0/usedBy' => $bob->{did})
  ->json_is('/codes/0/uses/1/usedBy' => $did)
  ->json_has('/cursor');

my $usage_codes = $t->tx->res->json->{codes} || [];
ok(
  scalar(grep { ($_->{code} // q()) eq 'perlsky-audit-unused' } @$usage_codes),
  'usage invite-code listing includes the unused seeded code',
);

$t->get_ok('/xrpc/com.atproto.admin.getInviteCodes?sort=bogus&limit=2' => {
  Authorization => $admin_auth,
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest')
  ->json_is('/message' => 'unknown sort method: bogus');

$t->get_ok('/xrpc/com.atproto.admin.getInviteCodes?sort=recent&limit=2&cursor=bogus' => {
  Authorization => $admin_auth,
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest')
  ->json_is('/message' => 'Malformed cursor');

$t->post_ok('/xrpc/com.atproto.admin.disableInviteCodes' => {
  Authorization => $admin_auth,
} => json => {
  accounts => ['admin'],
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest');

$t->post_ok('/xrpc/com.atproto.admin.disableInviteCodes' => {
  Authorization => $admin_auth,
} => json => {
  codes => [$admin_codes[0]],
})->status_is(200)
  ->content_is(q());

ok($app->store->get_invite_code($admin_codes[0])->{disabled}, 'disableInviteCodes marks the requested code disabled');

$t->post_ok('/xrpc/com.atproto.server.createInviteCodes' => {
  Authorization => $admin_auth,
} => json => {
  codeCount => 2,
  useCount  => 1,
})->status_is(200)
  ->json_is('/codes/0/account' => 'admin');

my @recent_batch_codes = @{ $t->tx->res->json->{codes}[0]{codes} || [] };
is(
  $app->store->get_invite_code($recent_batch_codes[0])->{created_at},
  $app->store->get_invite_code($recent_batch_codes[1])->{created_at},
  'createInviteCodes assigns one created_at across a batch',
);

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

$t->post_ok('/xrpc/com.atproto.admin.disableAccountInvites' => {
  Authorization => $admin_auth,
} => json => {
  account => $did,
  note    => 'paused for audit',
})->status_is(200)
  ->content_is(q());

$t->post_ok('/xrpc/com.atproto.admin.disableAccountInvites' => {
  Authorization => $admin_auth,
} => json => {
  account => 'did:web:missing.test',
  note    => 'ignored',
})->status_is(200)
  ->content_is(q());

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.admin.getAccountInfo')->query(
  did => $did,
) => {
  Authorization => $admin_auth,
})->status_is(200)
  ->json_is('/invitesDisabled' => JSON::PP::true)
  ->json_hasnt('/inviteNote');

$t->post_ok('/xrpc/com.atproto.server.createInviteCode' => {
  Authorization => "Bearer $access",
} => json => {
  useCount => 1,
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest');

$t->post_ok('/xrpc/com.atproto.admin.enableAccountInvites' => {
  Authorization => $admin_auth,
} => json => {
  account => $did,
})->status_is(200)
  ->content_is(q());

$t->post_ok('/xrpc/com.atproto.admin.enableAccountInvites' => {
  Authorization => $admin_auth,
} => json => {
  account => 'did:web:missing.test',
  note    => 'ignored',
})->status_is(200)
  ->content_is(q());

$t->post_ok('/xrpc/com.atproto.server.createInviteCode' => {
  Authorization => "Bearer $access",
} => json => {
  useCount => 1,
})->status_is(200)
  ->json_like('/code' => qr/\Aperlsky-/);

my $user_code = $t->tx->res->json->{code};

$t->post_ok('/xrpc/com.atproto.admin.disableInviteCodes' => {
  Authorization => $admin_auth,
} => json => {
  codes => [$user_code],
})->status_is(200)
  ->content_is(q());

my ($disabled_row) = grep { $_->{code} eq $user_code } @{ $app->store->list_invite_codes_for_account($did) || [] };
ok($disabled_row && $disabled_row->{disabled}, 'disableInviteCodes disables the requested invite code');

$t->post_ok('/xrpc/com.atproto.admin.disableInviteCodes' => {
  Authorization => $admin_auth,
} => json => {
  accounts => ['admin'],
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest');

done_testing;
