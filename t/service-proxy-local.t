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

use ATProto::PDS::ServiceProxy;

{
  package LocalTestStore;

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

  sub get_record {
    my ($self, $did, $collection, $rkey) = @_;
    return $self->{records}{"$did|$collection|$rkey"};
  }
}

{
  package LocalTestContext;

  sub new {
    my ($class, $store) = @_;
    return bless { store => $store }, $class;
  }

  sub store {
    my ($self) = @_;
    return $self->{store};
  }
}

my $proxy = ATProto::PDS::ServiceProxy->new;
my $did   = 'did:plc:alice';

my $store = LocalTestStore->new(
  accounts_by_did => {
    $did => {
      did    => $did,
      handle => 'alice.test',
    },
  },
  accounts_by_handle => {
    'alice.test' => {
      did    => $did,
      handle => 'alice.test',
    },
  },
  records => {
    "$did|app.bsky.feed.post|present-post" => {
      collection => 'app.bsky.feed.post',
      rkey       => 'present-post',
      cid        => 'bafyreitest',
      value      => { text => 'hello' },
    },
  },
);

my $c = LocalTestContext->new($store);

my $resolved = $proxy->_resolve_local_post_uri($c, "at://$did/app.bsky.feed.post/present-post");
is($resolved->[0]{did}, $did, 'local post lookup returns the local account');
is($resolved->[1]{rkey}, 'present-post', 'local post lookup returns the local record');

eval { $proxy->_resolve_local_post_uri($c, "at://$did/app.bsky.feed.post/missing-post") };
my $missing = $@;
is(ref($missing), 'HASH', 'missing local post throws an xrpc error');
is($missing->{status}, 404, 'missing local post returns 404');
is($missing->{error}, 'RecordNotFound', 'missing local post returns RecordNotFound');

eval { $proxy->_resolve_local_post_uri($c, "at://$did/app.bsky.feed.repost/not-a-post") };
my $wrong_collection = $@;
is(ref($wrong_collection), 'HASH', 'non-post local URI throws an xrpc error');
is($wrong_collection->{status}, 404, 'non-post local URI returns 404');
is($wrong_collection->{error}, 'RecordNotFound', 'non-post local URI returns RecordNotFound');

is(
  $proxy->_resolve_local_post_uri($c, 'at://did:plc:bob/app.bsky.feed.post/remote-post'),
  undef,
  'remote posts still fall back to upstream handling',
);

done_testing;
