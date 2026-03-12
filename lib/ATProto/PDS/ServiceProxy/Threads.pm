package ATProto::PDS::ServiceProxy::Threads;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use JSON::PP ();
use Time::HiRes qw(time);

use ATProto::PDS::API::Server qw(require_auth);
use ATProto::PDS::API::Util qw(resolve_repo xrpc_error);
use ATProto::PDS::Constants qw(TOKEN_AUD_ACCESS);

our @EXPORT_OK = qw(
  _get_author_feed
  _get_post_thread
  _get_posts
  _local_post_index
  _optional_auth_account
  _post_counts_and_viewer
  _post_embed_view
  _post_view
  _record_embed_view
  _reply_rows
  _thread_view
);

sub _get_author_feed ($self, $c) {
  xrpc_error(405, 'MethodNotAllowed', 'app.bsky.feed.getAuthorFeed expects GET')
    unless $c->req->method eq 'GET';

  my $actor = $c->param('actor') // q();
  xrpc_error(400, 'InvalidRequest', 'actor is required') unless length $actor;

  my $account = resolve_repo($c, $actor) or return undef;
  my $viewer = $self->_optional_auth_account($c, 'app.bsky.feed.getAuthorFeed');
  return undef unless $viewer && ($viewer->{did} // q()) eq ($account->{did} // q());
  my $limit = $c->param('limit') // 50;
  $limit = 1 if $limit < 1;
  $limit = 100 if $limit > 100;

  my $page = $c->store->list_records(
    $account->{did},
    'app.bsky.feed.post',
    limit   => $limit,
    cursor  => $c->param('cursor'),
    reverse => 1,
  );
  my $profile_value = $self->_profile_record_value($c, $account);
  my @feed = map {
    +{
      post => $self->_post_view($c, $account, $_, $profile_value, $viewer),
    }
  } @{ $page->{items} };

  my %body = (feed => \@feed);
  $body{cursor} = $page->{cursor} if defined $page->{cursor};
  $c->render(json => \%body);
  return 200;
}

sub _get_posts ($self, $c) {
  xrpc_error(405, 'MethodNotAllowed', 'app.bsky.feed.getPosts expects GET')
    unless $c->req->method eq 'GET';

  my @uris = grep { defined($_) && length($_) } $c->every_param('uris');
  xrpc_error(400, 'InvalidRequest', 'uris is required') unless @uris;

  my @resolved;
  my %seen_uri;
  for my $uri (@uris) {
    my $resolved = eval { $self->_resolve_local_post_uri($c, $uri) };
    if (my $err = $@) {
      next if ref($err) eq 'HASH'
        && ($err->{status} // 0) == 404
        && ($err->{error} // q()) eq 'RecordNotFound';
      die $err;
    }
    return undef unless defined $resolved;
    my ($account, $row) = @$resolved;
    my $canonical_uri = $self->_post_uri($account, $row);
    next if $seen_uri{$canonical_uri}++;
    push @resolved, $resolved;
  }

  my $viewer = $self->_optional_auth_account($c, 'app.bsky.feed.getPosts');
  my @posts = map {
    my ($account, $row) = @$_;
    my $profile_value = $self->_profile_record_value($c, $account);
    $self->_post_view($c, $account, $row, $profile_value, $viewer);
  } @resolved;

  $c->render(json => { posts => \@posts });
  return 200;
}

sub _get_post_thread ($self, $c) {
  xrpc_error(405, 'MethodNotAllowed', 'app.bsky.feed.getPostThread expects GET')
    unless $c->req->method eq 'GET';

  my $uri = $c->param('uri') // q();
  xrpc_error(400, 'InvalidRequest', 'uri is required') unless length $uri;

  my $resolved = $self->_resolve_local_post_uri($c, $uri) or return undef;
  my ($account, $row) = @$resolved;
  my $viewer = $self->_optional_auth_account($c, 'app.bsky.feed.getPostThread');
  return undef unless $viewer && ($viewer->{did} // q()) eq ($account->{did} // q());
  return undef if _thread_requires_upstream($self, $c, $row);
  my $profile_value = $self->_profile_record_value($c, $account);
  my $depth = $self->_non_negative_int_param($c, 'depth', 6);
  my $parent_height = $self->_non_negative_int_param($c, 'parentHeight', 80);
  my $thread = $self->_thread_view($c, $account, $row, $profile_value, $viewer, $depth, $parent_height);

  $c->render(json => { thread => $thread });
  return 200;
}

sub _optional_auth_account ($self, $c, $nsid) {
  my $auth = $c->req->headers->authorization;
  return undef unless defined $auth && length $auth;
  my %opts = (
    audience => TOKEN_AUD_ACCESS,
  );
  if (defined $nsid && length $nsid) {
    $opts{required_permission} = {
      type => 'rpc',
      aud  => $self->_permission_audience_for_request($c, $nsid),
      lxm  => $nsid,
    };
  }
  my (undef, $account) = require_auth($c, %opts);
  return $account;
}

sub _post_view ($self, $c, $account, $row, $profile_value = undef, $viewer = undef, $depth = 0) {
  my $uri = $self->_post_uri($account, $row);
  my $post = {
    uri       => $uri,
    cid       => $row->{cid},
    author    => $self->_profile_view_basic($c, $account, $profile_value, $viewer),
    record    => $row->{value},
    indexedAt => $self->_post_indexed_at($row),
  };
  if ($depth < 2) {
    my $embed = $self->_post_embed_view($c, $account, $row->{value}, $viewer, $depth + 1);
    $post->{embed} = $embed if defined $embed;
  }
  my $viewer_state = $self->_post_counts_and_viewer($c, $uri, $viewer)->{viewer} || {};
  $post->{viewer} = $viewer_state if %$viewer_state;
  return $post;
}

sub _thread_requires_upstream ($self, $c, $row) {
  for my $uri ($self->_reply_parent_uri($row), $self->_quoted_uri($row->{value})) {
    next unless defined $uri && length $uri;
    my $resolved = eval { $self->_resolve_local_post_uri($c, $uri) };
    return 1 if !$resolved || $@;
  }
  return 0;
}

sub _thread_view ($self, $c, $account, $row, $profile_value = undef, $viewer = undef, $depth = 6, $parent_height = 80) {
  my $thread = {
    '$type' => 'app.bsky.feed.defs#threadViewPost',
    post    => $self->_post_view($c, $account, $row, $profile_value, $viewer),
  };

  if ($parent_height > 0) {
    my $parent_uri = $self->_reply_parent_uri($row);
    if (defined $parent_uri) {
      my $parent = eval { $self->_resolve_local_post_uri($c, $parent_uri) };
      if ($parent) {
        my ($parent_account, $parent_row) = @$parent;
        $thread->{parent} = $self->_thread_view(
          $c,
          $parent_account,
          $parent_row,
          undef,
          $viewer,
          0,
          $parent_height - 1,
        );
      }
    }
  }

  return $thread if $depth <= 0;

  my $uri = $self->_post_uri($account, $row);
  my @replies;
  for my $reply ($self->_reply_rows($c, $uri)) {
    my ($reply_account, $reply_row) = @$reply;
    push @replies, $self->_thread_view(
      $c,
      $reply_account,
      $reply_row,
      undef,
      $viewer,
      $depth - 1,
      0,
    );
  }
  $thread->{replies} = \@replies if @replies;
  return $thread;
}

sub _reply_rows ($self, $c, $parent_uri) {
  my $index = $self->_local_post_index($c);
  return @{ $index->{replies}{$parent_uri} || [] };
}

sub _post_counts_and_viewer ($self, $c, $post_uri, $viewer = undef) {
  my $index = $self->_local_post_index($c);
  my $viewer_did = $viewer ? $viewer->{did} : undef;
  my $viewer_state = {};
  if (defined $viewer_did) {
    my $state = $index->{viewer}{$post_uri} || {};
    $viewer_state->{like} = $state->{like}{$viewer_did}
      if defined $state->{like}{$viewer_did};
    $viewer_state->{repost} = $state->{repost}{$viewer_did}
      if defined $state->{repost}{$viewer_did};
  }
  return { viewer => $viewer_state };
}

sub _local_post_index ($self, $c) {
  my $index = $c->stash('local_post_index');
  if ($index) {
    $c->app->metrics->increment_counter(
      'perlsky_service_proxy_local_post_index_cache_access_total',
      1,
      { result => 'request_cache_hit' },
    );
    return $index;
  }

  my $event_seq = $c->store->latest_event_seq;
  my $cache = $self->local_post_index_cache;
  if ($cache && (($cache->{event_seq} // -1) == $event_seq)) {
    $c->app->metrics->increment_counter(
      'perlsky_service_proxy_local_post_index_cache_access_total',
      1,
      { result => 'process_cache_hit' },
    );
    $c->stash(local_post_index => $cache->{index});
    return $cache->{index};
  }

  my $started = time;
  $index = _build_local_post_index($self, $c);
  $c->app->metrics->increment_counter(
    'perlsky_service_proxy_local_post_index_cache_access_total',
    1,
    { result => 'rebuild' },
  );
  $c->app->metrics->observe_histogram(
    'perlsky_service_proxy_local_post_index_rebuild_duration_seconds',
    time - $started,
  );
  $c->app->metrics->set_gauge(
    'perlsky_service_proxy_local_post_index_entries',
    scalar(keys %{ $index->{posts} }),
    { kind => 'posts' },
  );
  $c->app->metrics->set_gauge(
    'perlsky_service_proxy_local_post_index_entries',
    scalar(keys %{ $index->{replies} }),
    { kind => 'reply_parents' },
  );
  $c->app->metrics->set_gauge(
    'perlsky_service_proxy_local_post_index_entries',
    scalar(keys %{ $index->{stats} }),
    { kind => 'stats' },
  );
  $c->app->metrics->set_gauge(
    'perlsky_service_proxy_local_post_index_entries',
    scalar(keys %{ $index->{viewer} }),
    { kind => 'viewer_subjects' },
  );
  $self->local_post_index_cache({
    event_seq => $event_seq,
    index     => $index,
  });
  $c->stash(local_post_index => $index);
  return $index;
}

# Local appview reads can hit this repeatedly across requests, so keep the
# expensive scan isolated behind an event-seq keyed cache.
sub _build_local_post_index ($self, $c) {
  my @collections = qw(
    app.bsky.feed.post
    app.bsky.feed.like
    app.bsky.feed.repost
  );
  my $rows = $c->store->list_records_by_collections(\@collections);
  my %did_seen = map { $_->{did} => 1 } grep { defined $_->{did} && length $_->{did} } @$rows;
  my %accounts_by_did = map { $_->{did} => $_ }
    @{ $c->store->get_accounts_by_dids([ sort keys %did_seen ]) };
  my $index = {
    replies => {},
    posts   => {},
    stats   => {},
    viewer  => {},
  };

  for my $row (@$rows) {
    my $account = $accounts_by_did{ $row->{did} } or next;
    my $value = $row->{value};
    next unless ref($value) eq 'HASH';

    if (($row->{collection} // q()) eq 'app.bsky.feed.post') {
      $index->{posts}{ $self->_post_uri($account, $row) } = [ $account, $row ];
      my $reply = $value->{reply};
      if (ref($reply) eq 'HASH') {
        my $parent_uri = $reply->{parent}{uri} // q();
        if (length $parent_uri) {
          push @{ $index->{replies}{$parent_uri} }, [ $account, $row ];
          _local_post_stats($index, $parent_uri)->{replyCount}++;
        }
      }

      my $quoted_uri = $self->_quoted_uri($value) // q();
      _local_post_stats($index, $quoted_uri)->{quoteCount}++
        if length $quoted_uri;
      next;
    }

    if (($row->{collection} // q()) eq 'app.bsky.feed.like') {
      my $subject_uri = $value->{subject}{uri} // q();
      next unless length $subject_uri;
      _local_post_stats($index, $subject_uri)->{likeCount}++;
      $index->{viewer}{$subject_uri}{like}{$account->{did}} = $self->_post_uri($account, $row);
      next;
    }

    if (($row->{collection} // q()) eq 'app.bsky.feed.repost') {
      my $subject_uri = $value->{subject}{uri} // q();
      next unless length $subject_uri;
      _local_post_stats($index, $subject_uri)->{repostCount}++;
      $index->{viewer}{$subject_uri}{repost}{$account->{did}} = $self->_post_uri($account, $row);
    }
  }

  for my $parent_uri (keys %{ $index->{replies} }) {
    my @sorted = sort {
      $self->_post_indexed_at($a->[1]) cmp $self->_post_indexed_at($b->[1])
    } @{ $index->{replies}{$parent_uri} };
    $index->{replies}{$parent_uri} = \@sorted;
  }

  return $index;
}

sub _local_post_stats ($index, $post_uri) {
  return $index->{stats}{$post_uri} ||= {
    likeCount   => 0,
    repostCount => 0,
    replyCount  => 0,
    quoteCount  => 0,
  };
}

sub _post_embed_view ($self, $c, $account, $value, $viewer = undef, $depth = 0) {
  return undef unless ref($value) eq 'HASH';
  my $embed = $value->{embed};
  return undef unless ref($embed) eq 'HASH';

  my $type = $embed->{'$type'} // q();
  if ($type eq 'app.bsky.embed.images') {
    my @images = map {
      my $cid = $self->_blob_cid($_->{image});
      +{
        thumb    => $self->_blob_url($c, $account->{did}, $cid),
        fullsize => $self->_blob_url($c, $account->{did}, $cid),
        alt      => $_->{alt} // q(),
        (ref($_->{aspectRatio}) eq 'HASH' ? (aspectRatio => $_->{aspectRatio}) : ()),
      }
    } grep { ref($_) eq 'HASH' && $self->_blob_cid($_->{image}) } @{ $embed->{images} // [] };

    return undef unless @images;
    return {
      '$type' => 'app.bsky.embed.images#view',
      images  => \@images,
    };
  }

  if ($type eq 'app.bsky.embed.external' && ref($embed->{external}) eq 'HASH') {
    my $external = $embed->{external};
    my %view = (
      uri         => $external->{uri} // q(),
      title       => $external->{title} // q(),
      description => $external->{description} // q(),
    );
    if (my $cid = $self->_blob_cid($external->{thumb})) {
      $view{thumb} = $self->_blob_url($c, $account->{did}, $cid);
    }
    return {
      '$type'  => 'app.bsky.embed.external#view',
      external => \%view,
    };
  }

  if ($type eq 'app.bsky.embed.record' && ref($embed->{record}) eq 'HASH') {
    return {
      '$type' => 'app.bsky.embed.record#view',
      record  => $self->_record_embed_view($c, $embed->{record}, $viewer, $depth),
    };
  }

  if ($type eq 'app.bsky.embed.recordWithMedia'
      && ref($embed->{record}) eq 'HASH'
      && ref($embed->{media}) eq 'HASH') {
    my $record = $self->_record_embed_view($c, $embed->{record}{record} // $embed->{record}, $viewer, $depth);
    my $media = $self->_post_embed_view(
      $c,
      $account,
      { embed => $embed->{media} },
      $viewer,
      $depth,
    );
    return undef unless defined $record && defined $media;
    return {
      '$type' => 'app.bsky.embed.recordWithMedia#view',
      record  => {
        '$type' => 'app.bsky.embed.record#view',
        record  => $record,
      },
      media => $media,
    };
  }

  return undef;
}

sub _record_embed_view ($self, $c, $record_ref, $viewer = undef, $depth = 0) {
  my $uri = $record_ref->{uri} // q();
  my $resolved = $self->_resolve_local_post_uri($c, $uri);
  return {
    '$type'   => 'app.bsky.embed.record#viewNotFound',
    uri       => $uri,
    notFound  => JSON::PP::true,
  } unless $resolved;

  my ($account, $row) = @$resolved;
  my $profile_value = $self->_profile_record_value($c, $account);
  my $post_view = $self->_post_view($c, $account, $row, $profile_value, $viewer, $depth);
  my %record_view = (
    '$type'   => 'app.bsky.embed.record#viewRecord',
    uri       => $post_view->{uri},
    cid       => $post_view->{cid},
    author    => $post_view->{author},
    value     => $post_view->{record},
    indexedAt => $post_view->{indexedAt},
  );
  $record_view{labels} = $post_view->{labels} if $post_view->{labels};
  $record_view{embeds} = [ $post_view->{embed} ] if defined $post_view->{embed};
  return \%record_view;
}

1;
