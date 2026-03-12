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

use ATProto::PDS::API::Helpers qw(update_account_email);
use ATProto::PDS::Constants qw(ACTION_TOKEN_EMAIL_CONFIRM ACTION_TOKEN_EMAIL_UPDATE);
use ATProto::PDS::Store::SQLite;

{
  package t::EmailUpdateHelper::Controller;

  sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
  }

  sub store {
    my ($self) = @_;
    return $self->{store};
  }
}

my $tmp = tempdir(CLEANUP => 1);
my $store = ATProto::PDS::Store::SQLite->new(
  path => File::Spec->catfile($tmp, 'perlsky.sqlite'),
)->bootstrap;

my $controller = t::EmailUpdateHelper::Controller->new(store => $store);

my $alice = $store->create_account(
  did                => 'did:web:example.test:users:alice',
  handle             => 'alice.example.test',
  email              => 'alice@example.test',
  email_confirmed_at => time,
);
my $bob = $store->create_account(
  did                => 'did:web:example.test:users:bob',
  handle             => 'bob.example.test',
  email              => 'bob@example.test',
  email_confirmed_at => time,
);

my $confirm_token = $store->create_action_token(
  did     => $alice->{did},
  email   => $alice->{email},
  purpose => ACTION_TOKEN_EMAIL_CONFIRM,
);
my $update_token = $store->create_action_token(
  did     => $alice->{did},
  email   => $alice->{email},
  purpose => ACTION_TOKEN_EMAIL_UPDATE,
);

my $updated = update_account_email($controller, $alice->{did}, 'Alice.New@Example.test');
is($updated->{email}, 'alice.new@example.test', 'email updates are normalized through the shared helper');
ok(!defined $updated->{email_confirmed_at}, 'email updates clear email confirmation');
ok(defined $store->get_action_token($confirm_token->{token})->{consumed_at}, 'email confirmation tokens are revoked after email change');
ok(defined $store->get_action_token($update_token->{token})->{consumed_at}, 'email update tokens are revoked after email change');

my $fresh_token = $store->create_action_token(
  did     => $alice->{did},
  email   => $updated->{email},
  purpose => ACTION_TOKEN_EMAIL_UPDATE,
);

my $error = eval {
  update_account_email($controller, $alice->{did}, $bob->{email});
  undef;
};
my $thrown = $@;
ok(!defined $error, 'duplicate email update does not return a success value');
is(ref($thrown), 'HASH', 'duplicate email update throws an XRPC-style error');
is($thrown->{status}, 400, 'duplicate email update returns a client error');
is($thrown->{error}, 'InvalidRequest', 'duplicate email update uses InvalidRequest');
is($thrown->{message}, 'This email address is already in use, please use a different email.', 'duplicate email update uses the expected reference-style message');

$alice = $store->get_account_by_did($alice->{did});
is($alice->{email}, 'alice.new@example.test', 'duplicate email update leaves the stored email unchanged');
ok(!defined $store->get_action_token($fresh_token->{token})->{consumed_at}, 'failed duplicate update does not revoke unrelated outstanding tokens');

done_testing;
