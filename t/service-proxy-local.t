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
    $self->{get_account_by_handle_calls}{$handle}++;
    return $self->{accounts_by_handle}{$handle};
  }

  sub get_account_by_did {
    my ($self, $did) = @_;
    $self->{get_account_by_did_calls}{$did}++;
    return $self->{accounts_by_did}{$did};
  }

  sub list_accounts {
    my ($self) = @_;
    $self->{list_accounts_calls}++;
    return $self->{list_accounts} // [];
  }

  sub get_accounts_by_dids {
    my ($self, $dids) = @_;
    $self->{get_accounts_by_dids_calls}++;
    $self->{get_accounts_by_dids_args} = [ @$dids ];
    return [
      map { $self->{accounts_by_did}{$_} }
      grep { defined $self->{accounts_by_did}{$_} } @$dids
    ];
  }

  sub all_records_for_did {
    my ($self, $did) = @_;
    $self->{all_records_for_did_calls}{$did}++;
    return $self->{all_records_for_did}{$did} // [];
  }

  sub list_records_by_collections {
    my ($self, $collections) = @_;
    $self->{list_records_by_collections_calls}++;
    $self->{list_records_by_collections_args} = [ @$collections ];
    my %wanted = map { $_ => 1 } @$collections;
    return [
      grep { $wanted{ $_->{collection} // q() } }
      @{ $self->{list_records_by_collections} // [] }
    ];
  }

  sub count_records_by_collection {
    my ($self, $did, $collection) = @_;
    $self->{count_records_by_collection_calls}{"$did|$collection"}++;
    return $self->{count_records_by_collection}{"$did|$collection"} // 0;
  }

  sub latest_event_seq {
    my ($self) = @_;
    $self->{latest_event_seq_calls}++;
    return $self->{latest_event_seq} // 0;
  }

  sub get_record {
    my ($self, $did, $collection, $rkey) = @_;
    $self->{get_record_calls}{"$did|$collection|$rkey"}++;
    return $self->{records}{"$did|$collection|$rkey"};
  }

  sub get_subject_status {
    my ($self, $key) = @_;
    $self->{get_subject_status_calls}{$key}++;
    return $self->{subject_status}{$key};
  }
}

{
  package LocalTestMetrics;

  sub increment_counter { return 1 }
  sub observe_histogram { return 1 }
  sub set_gauge         { return 1 }
}

{
  package LocalTestApp;

  sub metrics { return bless {}, 'LocalTestMetrics' }
}

{
  package LocalTestContext;

  sub new {
    my ($class, $store) = @_;
    return bless {
      store => $store,
      app   => bless({}, 'LocalTestApp'),
    }, $class;
  }

  sub store {
    my ($self) = @_;
    return $self->{store};
  }

  sub app {
    my ($self) = @_;
    return $self->{app};
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

my $cached_resolved_by_did = $proxy->_resolve_local_post_uri($c, "at://$did/app.bsky.feed.post/present-post");
is($cached_resolved_by_did->[0]{did}, $did, 'repeat local post lookup reuses the cached account resolution');
is($cached_resolved_by_did->[1]{rkey}, 'present-post', 'repeat local post lookup reuses the cached record resolution');
is($store->{get_account_by_did_calls}{$did}, 1, 'repeat did-form local post lookup avoids another account lookup');
is($store->{get_record_calls}{"$did|app.bsky.feed.post|present-post"}, 2, 'repeat did-form local post lookup avoids another record fetch');

my $index_context = LocalTestContext->new($store);
$index_context->stash(local_post_index => {
  posts => {
    "at://$did/app.bsky.feed.post/present-post" => $resolved,
  },
});
my $indexed_resolved = $proxy->_resolve_local_post_uri($index_context, "at://$did/app.bsky.feed.post/present-post");
is($indexed_resolved, $resolved, 'local post lookup can reuse the request local-post index');
is($store->{get_record_calls}{"$did|app.bsky.feed.post|present-post"}, 2, 'indexed local post lookup avoids another record fetch');

$store->{records}{"$did|app.bsky.actor.profile|self"} = {
  collection => 'app.bsky.actor.profile',
  rkey       => 'self',
  cid        => 'bafyreiprofile',
  value      => { displayName => 'Alice Example' },
};
my $profile_first = $proxy->_profile_record_value($c, $store->{accounts_by_did}{$did});
my $profile_second = $proxy->_profile_record_value($c, $store->{accounts_by_did}{$did});
is($profile_first, $profile_second, 'repeat profile lookup reuses the cached profile value');
is($store->{get_record_calls}{"$did|app.bsky.actor.profile|self"}, 1, 'repeat profile lookup avoids another record fetch');

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
  accounts_by_did => {
    $did => {
      did    => $did,
      handle => 'alice.test',
    },
  },
  list_records_by_collections => [
    {
      did        => $did,
      collection => 'app.bsky.feed.post',
      rkey       => 'cached-post',
      cid        => 'bafyreicached',
      value      => { text => 'cached' },
    },
    {
      did        => $did,
      collection => 'app.bsky.actor.profile',
      rkey       => 'self',
      cid        => 'bafyreiprofile',
      value      => { displayName => 'Ignored by local post index' },
    },
  ],
);

my $cached_proxy = ATProto::PDS::ServiceProxy->new;
my $first_cache_context = LocalTestContext->new($cache_store);
my $second_cache_context = LocalTestContext->new($cache_store);
my $third_cache_context = LocalTestContext->new($cache_store);

my $first_index = $cached_proxy->_local_post_index($first_cache_context);
is($cache_store->{list_records_by_collections_calls}, 1, 'first local post index build scans relevant records once');
is($cache_store->{get_accounts_by_dids_calls}, 1, 'first local post index build fetches account metadata once');
is_deeply(
  $cache_store->{list_records_by_collections_args},
  [qw(app.bsky.feed.post app.bsky.feed.like app.bsky.feed.repost)],
  'local post index only requests feed-relevant collections',
);
is_deeply($cache_store->{get_accounts_by_dids_args}, [$did], 'local post index batches account lookup by DID');

my $second_index = $cached_proxy->_local_post_index($second_cache_context);
is($cache_store->{latest_event_seq_calls}, 2, 'subsequent requests still check the latest event seq');
is($cache_store->{list_records_by_collections_calls}, 1, 'unchanged event seq reuses the cached global post index');
is($cache_store->{get_accounts_by_dids_calls}, 1, 'unchanged event seq avoids refetching account metadata');
is($second_index, $first_index, 'unchanged event seq returns the cached index reference');

$cache_store->{latest_event_seq} = 2;
my $third_index = $cached_proxy->_local_post_index($third_cache_context);
is($cache_store->{list_records_by_collections_calls}, 2, 'new events invalidate the cached global post index');
is($cache_store->{get_accounts_by_dids_calls}, 2, 'new events trigger a fresh account batch lookup');
isnt($third_index, $first_index, 'new events rebuild the cached index');

my $follow_store = LocalTestStore->new(
  latest_event_seq => 10,
  list_records_by_collections => [
    {
      did        => $did,
      collection => 'app.bsky.graph.follow',
      rkey       => 'follow-bob',
      cid        => 'bafyreifollow1',
      value      => { subject => 'did:plc:bob' },
    },
    {
      did        => 'did:plc:bob',
      collection => 'app.bsky.graph.follow',
      rkey       => 'follow-alice',
      cid        => 'bafyreifollow2',
      value      => { subject => $did },
    },
  ],
);

my $follow_proxy = ATProto::PDS::ServiceProxy->new;
my $follow_context = LocalTestContext->new($follow_store);
my $follow_index = $follow_proxy->_follow_index($follow_context);
is($follow_store->{list_records_by_collections_calls}, 1, 'first follow index build scans follow records once');
is_deeply(
  $follow_store->{list_records_by_collections_args},
  ['app.bsky.graph.follow'],
  'follow index only requests follow records',
);
is($follow_index->{follows_by_actor}{$did}, 1, 'follow index counts outgoing follows');
is($follow_index->{followers_by_subject}{$did}, 1, 'follow index counts inbound followers');
is(
  $follow_index->{follow_uris}{$did}{'did:plc:bob'},
  "at://$did/app.bsky.graph.follow/follow-bob",
  'follow index records follow URIs for viewer state',
);

my $follow_context_again = LocalTestContext->new($follow_store);
my $cached_follow_index = $follow_proxy->_follow_index($follow_context_again);
is($follow_store->{latest_event_seq_calls}, 2, 'follow index still checks the latest event seq on reuse');
is($follow_store->{list_records_by_collections_calls}, 1, 'unchanged event seq reuses the cached follow index');
is($cached_follow_index, $follow_index, 'unchanged event seq returns the cached follow index reference');

my $viewer = $follow_proxy->_profile_viewer($follow_context_again, { did => 'did:plc:bob' }, { did => $did });
is(
  $viewer->{following},
  "at://$did/app.bsky.graph.follow/follow-bob",
  'profile viewer includes the outgoing follow URI',
);
is(
  $viewer->{followedBy},
  "at://did:plc:bob/app.bsky.graph.follow/follow-alice",
  'profile viewer includes the reciprocal follow URI',
);

my $remote_quote_embed = $proxy->_post_embed_view(
  $c,
  $store->{accounts_by_did}{$did},
  {
    embed => {
      '$type' => 'app.bsky.embed.record',
      record  => {
        uri => 'at://did:plc:bob/app.bsky.feed.post/remote-post',
        cid => 'bafyremote',
      },
    },
  },
);
ok(!defined($remote_quote_embed), 'remote quoted records omit non-authoritative derived embeds');

my $missing_local_quote_embed = $proxy->_post_embed_view(
  $c,
  $store->{accounts_by_did}{$did},
  {
    embed => {
      '$type' => 'app.bsky.embed.record',
      record  => {
        uri => "at://$did/app.bsky.feed.post/missing-post",
        cid => 'bafymissing',
      },
    },
  },
);
is(
  $missing_local_quote_embed->{record}{'$type'},
  'app.bsky.embed.record#viewNotFound',
  'missing local quoted records still render viewNotFound',
);

done_testing;
