use v5.34;
use warnings;

use Config ();
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
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

use ATProto::PDS::API::Helpers qw(admin_account_view);
use ATProto::PDS::Store::SQLite;

my $tmp = tempdir(CLEANUP => 1);
my $store = ATProto::PDS::Store::SQLite->new(
  path => File::Spec->catfile($tmp, 'perlsky.sqlite'),
)->bootstrap;

my $creator = $store->create_account(
  did       => 'did:web:example.test:users:creator',
  handle    => 'creator.example.test',
  email     => 'creator@example.test',
  created_at => 1_700_000_000,
);
my $invitee = $store->create_account(
  did                => 'did:web:example.test:users:invitee',
  handle             => 'invitee.example.test',
  email              => 'invitee@example.test',
  email_confirmed_at => 1_700_000_100,
  invites_disabled   => 1,
  created_at         => 1_700_000_050,
);

$store->create_invite_code(
  code        => 'perlsky-first',
  for_account => $invitee->{did},
  created_by  => $creator->{did},
  use_count   => 2,
  created_at  => 1_700_000_150,
);
$store->create_invite_code(
  code        => 'perlsky-second',
  for_account => $invitee->{did},
  created_by  => $creator->{did},
  use_count   => 1,
  created_at  => 1_700_000_151,
);
$store->create_invite_code(
  code        => 'perlsky-parent',
  for_account => $creator->{did},
  created_by  => 'admin',
  use_count   => 1,
  created_at  => 1_700_000_010,
);
$store->record_invite_code_use(
  code    => 'perlsky-parent',
  used_by => $invitee->{did},
  used_at => 1_700_000_020,
);

my $view = admin_account_view($store, $invitee, entryway => 0);

is($view->{did}, $invitee->{did}, 'admin account view keeps the DID');
is($view->{handle}, $invitee->{handle}, 'admin account view keeps the handle');
is($view->{email}, $invitee->{email}, 'admin account view keeps the email');
is($view->{indexedAt}, '2023-11-14T22:14:10Z', 'admin account view uses created_at for indexedAt');
ok($view->{invitesDisabled}, 'admin account view exposes invite disablement');
is($view->{invitedBy}{code}, 'perlsky-parent', 'admin account view includes the invite that created the account');
is($view->{invitedBy}{createdBy}, 'admin', 'admin account view includes invitedBy metadata');
is(scalar @{ $view->{invites} || [] }, 2, 'admin account view includes owned invite codes');
is($view->{invites}[0]{code}, 'perlsky-second', 'admin account view keeps invite ordering');
is($view->{invites}[1]{code}, 'perlsky-first', 'admin account view includes all invites');

my $entryway_view = admin_account_view($store, $invitee, entryway => 1);
ok(!exists $entryway_view->{invitedBy}, 'entryway mode omits invitedBy');
ok(!exists $entryway_view->{invites}, 'entryway mode omits invite lists');
ok(!exists $entryway_view->{invitesDisabled}, 'entryway mode omits invite disablement');

done_testing;
