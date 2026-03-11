package ATProto::PDS::ServiceProxy::Posts;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';

use ATProto::PDS::API::Util qw(iso8601 resolve_repo xrpc_error);
use ATProto::PDS::Moderation qw(parse_at_uri);

our @EXPORT_OK = qw(
  _non_negative_int_param
  _post_indexed_at
  _post_uri
  _quoted_uri
  _reply_parent_uri
  _resolve_local_post_uri
);

sub _resolve_local_post_uri ($self, $c, $uri) {
  my $cache = $c->stash('service_proxy_local_post_uri_cache') || {};
  if (exists $cache->{$uri}) {
    $c->app->metrics->increment_counter(
      'perlsky_service_proxy_local_post_resolution_total',
      1,
      { source => 'request_cache' },
    );
    return $cache->{$uri};
  }

  my ($repo, $collection, $rkey) = parse_at_uri($uri);
  return undef unless defined $repo && defined $collection && defined $rkey;
  my $account = resolve_repo($c, $repo) or do {
    $c->app->metrics->increment_counter(
      'perlsky_service_proxy_local_post_resolution_total',
      1,
      { source => 'non_local' },
    );
    return undef;
  };
  xrpc_error(404, 'RecordNotFound', 'Record was not found')
    unless $collection eq 'app.bsky.feed.post';
  my $canonical_uri = 'at://' . $account->{did} . '/' . $collection . '/' . $rkey;
  my $local_post_index = $c->stash('local_post_index');
  if ($local_post_index && $local_post_index->{posts}{$canonical_uri}) {
    $c->app->metrics->increment_counter(
      'perlsky_service_proxy_local_post_resolution_total',
      1,
      { source => 'index_cache' },
    );
    my $resolved = $local_post_index->{posts}{$canonical_uri};
    $cache->{$uri} = $resolved;
    $cache->{$canonical_uri} = $resolved;
    $c->stash(service_proxy_local_post_uri_cache => $cache);
    return $resolved;
  }
  $c->app->metrics->increment_counter(
    'perlsky_service_proxy_local_post_resolution_total',
    1,
    { source => 'store' },
  );
  my $row = $c->store->get_record($account->{did}, $collection, $rkey);
  xrpc_error(404, 'RecordNotFound', 'Record was not found') unless $row;
  my $resolved = [ $account, $row ];
  $cache->{$uri} = $resolved;
  $cache->{$canonical_uri} = $resolved;
  $c->stash(service_proxy_local_post_uri_cache => $cache);
  return $resolved;
}

sub _post_uri ($self, $account, $row) {
  return 'at://' . $account->{did} . '/' . $row->{collection} . '/' . $row->{rkey};
}

sub _post_indexed_at ($self, $row) {
  return $row->{value}{createdAt}
    if ref($row->{value}) eq 'HASH' && defined $row->{value}{createdAt};
  return iso8601($row->{created_at} // $row->{updated_at});
}

sub _non_negative_int_param ($self, $c, $name, $default) {
  my $value = $c->param($name);
  return $default unless defined $value && length $value;
  $value = int($value);
  return $value < 0 ? 0 : $value;
}

sub _reply_parent_uri ($self, $row) {
  return undef unless ref($row->{value}) eq 'HASH';
  my $reply = $row->{value}{reply};
  return undef unless ref($reply) eq 'HASH';
  my $parent = $reply->{parent};
  return undef unless ref($parent) eq 'HASH';
  my $uri = $parent->{uri} // q();
  return length($uri) ? $uri : undef;
}

sub _quoted_uri ($self, $value) {
  return undef unless ref($value) eq 'HASH';
  my $embed = $value->{embed};
  return undef unless ref($embed) eq 'HASH';
  return $embed->{record}{uri}
    if (($embed->{'$type'} // q()) eq 'app.bsky.embed.record')
      && ref($embed->{record}) eq 'HASH';
  return $embed->{record}{record}{uri}
    if (($embed->{'$type'} // q()) eq 'app.bsky.embed.recordWithMedia')
      && ref($embed->{record}) eq 'HASH'
      && ref($embed->{record}{record}) eq 'HASH';
  return undef;
}

1;
