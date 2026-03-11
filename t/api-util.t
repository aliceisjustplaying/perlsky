use v5.34;
use warnings;

use Config ();
use File::Spec;
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

use ATProto::PDS::API::Util qw(flatten_params resolve_did_account resolve_repo);

{
  package ApiUtilTestStore;

  sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
  }

  sub get_account_by_handle {
    my ($self, $handle) = @_;
    return $self->{accounts_by_handle}{$handle};
  }

  sub get_account_by_did {
    my ($self, $did) = @_;
    return $self->{accounts_by_did}{$did};
  }

  sub list_accounts {
    my ($self) = @_;
    return $self->{list_accounts} // [];
  }
}

{
  package ApiUtilTestContext;

  sub new {
    my ($class, $store) = @_;
    return bless { store => $store }, $class;
  }

  sub store {
    my ($self) = @_;
    return $self->{store};
  }
}

is_deeply(
  [ flatten_params('a', ['b', 'c'], 'd') ],
  ['a', 'b', 'c', 'd'],
  'flatten_params flattens repeated query-style values',
);

my $store = ApiUtilTestStore->new(
  accounts_by_handle => {
    'alice.test' => { did => 'did:plc:alice', handle => 'alice.test' },
  },
  accounts_by_did => {
    'did:plc:alice' => { did => 'did:plc:alice', handle => 'alice.test' },
  },
  list_accounts => [
    { did => 'did:plc:alice', handle => 'alice.test' },
  ],
);

my $c = ApiUtilTestContext->new($store);

is(resolve_repo($c, 'alice.test')->{did}, 'did:plc:alice', 'resolve_repo finds handles directly');
is(resolve_repo($c, 'did:plc:alice')->{handle}, 'alice.test', 'resolve_repo finds plain DIDs directly');
is(resolve_did_account($c, 'did%3Aplc%3Aalice')->{handle}, 'alice.test', 'resolve_did_account accepts percent-encoded DIDs');
is(resolve_repo($c, undef), undef, 'resolve_repo returns undef for empty input');

done_testing;
