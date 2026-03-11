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
    $self->{list_accounts_calls}++;
    return $self->{list_accounts} // [];
  }

  sub all_records_for_did {
    my ($self, $did) = @_;
    $self->{all_records_for_did_calls}{$did}++;
    return $self->{all_records_for_did}{$did} // [];
  }

  sub latest_event_seq {
    my ($self) = @_;
    $self->{latest_event_seq_calls}++;
    return $self->{latest_event_seq} // 0;
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

  sub config_value {
    my ($self, $name, $default) = @_;
    return $default;
  }

  sub stash {
    my ($self, @args) = @_;
    $self->{stash} //= {};
    return $self->{stash}{$args[0]} if @args == 1;
    if (@args == 2) {
      $self->{stash}{$args[0]} = $args[1];
      return $self;
    }
    die 'unsupported stash arity';
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

my $resolved_by_handle = $proxy->_resolve_local_post_uri($c, 'at://alice.test/app.bsky.feed.post/present-post');
is($resolved_by_handle->[0]{did}, $did, 'handle-form local post lookup returns the local account');
is($resolved_by_handle->[1]{rkey}, 'present-post', 'handle-form local post lookup returns the local record');

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

my $cache_store = LocalTestStore->new(
  latest_event_seq => 1,
  list_accounts => [
    {
      did    => $did,
      handle => 'alice.test',
    },
  ],
  all_records_for_did => {
    $did => [
      {
        collection => 'app.bsky.feed.post',
        rkey       => 'cached-post',
        cid        => 'bafyreicached',
        value      => { text => 'cached' },
      },
    ],
  },
);

my $cached_proxy = ATProto::PDS::ServiceProxy->new;
my $first_cache_context = LocalTestContext->new($cache_store);
my $second_cache_context = LocalTestContext->new($cache_store);
my $third_cache_context = LocalTestContext->new($cache_store);

my $first_index = $cached_proxy->_local_post_index($first_cache_context);
is($cache_store->{list_accounts_calls}, 1, 'first local post index build scans accounts once');
is($cache_store->{all_records_for_did_calls}{$did}, 1, 'first local post index build scans records once');

my $second_index = $cached_proxy->_local_post_index($second_cache_context);
is($cache_store->{latest_event_seq_calls}, 2, 'subsequent requests still check the latest event seq');
is($cache_store->{list_accounts_calls}, 1, 'unchanged event seq reuses the cached global post index');
is($cache_store->{all_records_for_did_calls}{$did}, 1, 'unchanged event seq avoids rescanning records');
is($second_index, $first_index, 'unchanged event seq returns the cached index reference');

$cache_store->{latest_event_seq} = 2;
my $third_index = $cached_proxy->_local_post_index($third_cache_context);
is($cache_store->{list_accounts_calls}, 2, 'new events invalidate the cached global post index');
is($cache_store->{all_records_for_did_calls}{$did}, 2, 'new events trigger a rebuild scan');
isnt($third_index, $first_index, 'new events rebuild the cached index');

done_testing;
