package ATProto::PDS::ServiceProxy;

use v5.34;
use warnings;

use Mojo::Base -base, -signatures;
use Mojo::URL;
use Mojo::UserAgent;
use JSON::PP ();

use ATProto::PDS::API::Server qw(require_auth);
use ATProto::PDS::API::Util qw(iso8601 resolve_repo xrpc_error);
use ATProto::PDS::Auth::JWT qw(encode_service_jwt);
use ATProto::PDS::Moderation qw(parse_at_uri);

has settings => sub { {} };
has ua => sub {
  my $ua = Mojo::UserAgent->new(max_redirects => 0);
  $ua->request_timeout(15);
  $ua->inactivity_timeout(30);
  return $ua;
};

sub proxy_xrpc_request ($self, $c, $nsid) {
  if ($nsid eq 'app.bsky.actor.getPreferences') {
    return $self->_get_preferences($c);
  }
  if ($nsid eq 'app.bsky.actor.putPreferences') {
    return $self->_put_preferences($c);
  }
  if ($nsid eq 'app.bsky.actor.getProfile') {
    my $status = $self->_get_local_profile($c);
    return $status if defined $status;
  }
  if ($nsid eq 'app.bsky.feed.getAuthorFeed') {
    my $status = $self->_get_author_feed($c);
    return $status if defined $status;
  }
  if ($nsid eq 'app.bsky.feed.getPosts') {
    my $status = $self->_get_posts($c);
    return $status if defined $status;
  }
  if ($nsid eq 'app.bsky.feed.getPostThread') {
    my $status = $self->_get_post_thread($c);
    return $status if defined $status;
  }

  my $target = $self->_target_for_request($c, $nsid) or return undef;

  my $method = $c->req->method;
  xrpc_error(400, 'InvalidRequest', 'XRPC proxy only supports GET, HEAD, and POST')
    unless $method eq 'GET' || $method eq 'HEAD' || $method eq 'POST';

  my $url = Mojo::URL->new($target->{url});
  $url->path($c->req->url->path->to_string);
  $url->query($c->req->url->query->clone);

  my %headers = (
    'Accept-Encoding' => 'identity',
  );
  for my $pair (
    ['Accept-Language', 'Accept-Language'],
    ['Atproto-Accept-Labelers', 'Atproto-Accept-Labelers'],
    ['X-Bsky-Topics', 'X-Bsky-Topics'],
  ) {
    my ($source, $dest) = @$pair;
    my $value = $c->req->headers->header($source);
    $headers{$dest} = $value if defined $value && length $value;
  }

  if ($method eq 'POST') {
    for my $name (qw(Content-Type Content-Encoding)) {
      my $value = $c->req->headers->header($name);
      $headers{$name} = $value if defined $value && length $value;
    }
  }

  my $auth = $c->req->headers->authorization;
  if (defined $auth && length $auth) {
    my (undef, $account) = require_auth($c, audience => 'access', allow_refresh => 1);
    xrpc_error(500, 'SigningKeyUnavailable', 'Account signing key is unavailable')
      unless defined($account->{private_key}) && length($account->{private_key});
    $headers{Authorization} = 'Bearer ' . encode_service_jwt(
      {
        iss => $account->{did},
        aud => $target->{did},
        lxm => $nsid,
      },
      $account->{private_key},
    );
  }

  my $tx = $method eq 'POST'
    ? $self->ua->build_tx($method => $url => \%headers => ($c->req->body // q()))
    : $self->ua->build_tx($method => $url => \%headers);

  $tx = eval { $self->ua->start($tx) };
  if (my $err = $@) {
    my $message = "$err";
    xrpc_error(502, 'UpstreamFailure', $message || 'Upstream service unreachable');
  }

  my $res = $tx->result;
  if (my $err = $res->error) {
    xrpc_error(502, 'UpstreamFailure', $err->{message} // 'Upstream service unreachable')
      unless $res->code;
  }

  my $status = $res->code // 502;
  my $headers_out = $c->res->headers;
  for my $name (
    qw(
      Content-Type
      Content-Language
      Atproto-Repo-Rev
      Atproto-Content-Labelers
      Retry-After
      WWW-Authenticate
      DPoP-Nonce
    )
  ) {
    my $value = $res->headers->header($name);
    $headers_out->header($name => $value) if defined $value && length $value;
  }

  if ($method eq 'HEAD') {
    $c->res->code($status);
    $c->rendered($status);
    return $status;
  }

  $c->render(
    status => $status,
    data   => $res->body,
  );
  return $status;
}

sub _target_for_request ($self, $c, $nsid) {
  if (my $proxy_to = $c->req->headers->header('Atproto-Proxy')) {
    return $self->_target_from_proxy_header($proxy_to);
  }

  return {
    did => $self->_config('chat_service_did', 'did:web:api.bsky.chat'),
    url => $self->_config('chat_service_url', 'https://api.bsky.chat'),
  } if $nsid =~ /\Achat\.bsky\./;

  return {
    did => $self->_config('bsky_appview_did', 'did:web:api.bsky.app'),
    url => $self->_config('bsky_appview_url', 'https://api.bsky.app'),
  } if $nsid =~ /\Aapp\.bsky\./;

  return undef;
}

sub _target_from_proxy_header ($self, $proxy_to) {
  xrpc_error(400, 'InvalidRequest', 'Proxy header cannot contain spaces')
    if $proxy_to =~ /\s/;

  my ($did, $service_id) = $proxy_to =~ /\A([^#]+)#([^#]+)\z/;
  xrpc_error(400, 'InvalidRequest', 'Invalid proxy header format')
    unless defined $did && defined $service_id;

  my $appview_did = $self->_config('bsky_appview_did', 'did:web:api.bsky.app');
  return {
    did => $appview_did,
    url => $self->_config('bsky_appview_url', 'https://api.bsky.app'),
  } if $did eq $appview_did && $service_id eq 'bsky_appview';

  my $chat_did = $self->_config('chat_service_did', 'did:web:api.bsky.chat');
  return {
    did => $chat_did,
    url => $self->_config('chat_service_url', 'https://api.bsky.chat'),
  } if $did eq $chat_did && $service_id eq 'bsky_chat';

  xrpc_error(400, 'InvalidRequest', "Unsupported proxy target $proxy_to");
}

sub _config ($self, $key, $default) {
  return $self->settings->{$key} // $default;
}

sub _get_preferences ($self, $c) {
  xrpc_error(405, 'MethodNotAllowed', 'app.bsky.actor.getPreferences expects GET')
    unless $c->req->method eq 'GET';

  my (undef, $account) = require_auth($c, audience => 'access', allow_refresh => 1);
  my $preferences = $c->store->list_preferences($account->{did}, 'app.bsky');
  $c->render(json => { preferences => $preferences });
  return 200;
}

sub _put_preferences ($self, $c) {
  xrpc_error(405, 'MethodNotAllowed', 'app.bsky.actor.putPreferences expects POST')
    unless $c->req->method eq 'POST';

  my (undef, $account) = require_auth($c, audience => 'access', allow_refresh => 1);
  my $body = $c->req->json || {};
  my $preferences = $body->{preferences};
  xrpc_error(400, 'InvalidRequest', 'preferences must be an array')
    unless ref($preferences) eq 'ARRAY';

  for my $pref (@$preferences) {
    xrpc_error(400, 'InvalidRequest', 'preference entries must be objects')
      unless ref($pref) eq 'HASH';
    xrpc_error(400, 'InvalidRequest', 'preference entries must include $type')
      unless defined($pref->{'$type'}) && length($pref->{'$type'});
  }

  $c->store->put_preferences($account->{did}, 'app.bsky', $preferences);
  $c->render(json => {});
  return 200;
}

sub _get_local_profile ($self, $c) {
  xrpc_error(405, 'MethodNotAllowed', 'app.bsky.actor.getProfile expects GET')
    unless $c->req->method eq 'GET';

  my $actor = $c->param('actor') // q();
  xrpc_error(400, 'InvalidRequest', 'actor is required') unless length $actor;

  my $account = resolve_repo($c, $actor) or return undef;
  my $profile_value = $self->_profile_record_value($c, $account);
  my $result = {
    %{ $self->_profile_view_detailed($c, $account, $profile_value) },
    associated => {
      %{ $self->_profile_associated },
      lists                => 0,
      feedgens             => 0,
      starterPacks         => 0,
      labeler              => JSON::PP::false,
    },
    viewer => {
      muted     => JSON::PP::false,
      blockedBy => JSON::PP::false,
    },
  };

  $c->render(json => $result);
  return 200;
}

sub _get_author_feed ($self, $c) {
  xrpc_error(405, 'MethodNotAllowed', 'app.bsky.feed.getAuthorFeed expects GET')
    unless $c->req->method eq 'GET';

  my $actor = $c->param('actor') // q();
  xrpc_error(400, 'InvalidRequest', 'actor is required') unless length $actor;

  my $account = resolve_repo($c, $actor) or return undef;
  my $viewer = $self->_optional_auth_account($c);
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
  push @uris, $c->param('uris')
    if !@uris && defined($c->param('uris')) && length($c->param('uris'));
  xrpc_error(400, 'InvalidRequest', 'uris is required') unless @uris;

  my @resolved = map { $self->_resolve_local_post_uri($c, $_) } @uris;
  return undef if grep { !defined $_ } @resolved;

  my $viewer = $self->_optional_auth_account($c);
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
  my $viewer = $self->_optional_auth_account($c);
  my $profile_value = $self->_profile_record_value($c, $account);
  my $depth = $c->param('depth') // 6;
  $depth = 0 if $depth < 0;
  my $thread = $self->_thread_view($c, $account, $row, $profile_value, $viewer, $depth);

  $c->render(json => { thread => $thread });
  return 200;
}

sub _optional_auth_account ($self, $c) {
  my $auth = $c->req->headers->authorization;
  return undef unless defined $auth && length $auth;
  my (undef, $account) = require_auth($c, audience => 'access', allow_refresh => 1);
  return $account;
}

sub _profile_record_value ($self, $c, $account) {
  my $profile = $c->store->get_record($account->{did}, 'app.bsky.actor.profile', 'self');
  return (ref($profile) eq 'HASH' && ref($profile->{value}) eq 'HASH') ? $profile->{value} : {};
}

sub _profile_view_basic ($self, $c, $account, $profile_value = undef) {
  $profile_value //= $self->_profile_record_value($c, $account);
  my $view = {
    did    => $account->{did},
    handle => $account->{handle},
    associated => $self->_profile_associated,
    labels     => [],
    createdAt  => iso8601($account->{created_at}),
  };
  $view->{displayName} = $profile_value->{displayName}
    if defined($profile_value->{displayName}) && length($profile_value->{displayName});
  $view->{pronouns} = $profile_value->{pronouns}
    if defined($profile_value->{pronouns}) && length($profile_value->{pronouns});
  if (my $avatar_cid = $self->_blob_cid($profile_value->{avatar})) {
    $view->{avatar} = $self->_blob_url($c, $account->{did}, $avatar_cid);
  }
  return $view;
}

sub _profile_view_detailed ($self, $c, $account, $profile_value = undef) {
  $profile_value //= $self->_profile_record_value($c, $account);
  my $view = {
    %{ $self->_profile_view_basic($c, $account, $profile_value) },
    createdAt      => iso8601($account->{created_at}),
    indexedAt      => iso8601($account->{created_at}),
    followersCount => 0,
    followsCount   => 0,
    postsCount     => 0 + $c->store->count_records_by_collection($account->{did}, 'app.bsky.feed.post'),
  };
  $view->{description} = $profile_value->{description}
    if defined($profile_value->{description}) && length($profile_value->{description});
  $view->{website} = $profile_value->{website}
    if defined($profile_value->{website}) && length($profile_value->{website});
  if (my $banner_cid = $self->_blob_cid($profile_value->{banner})) {
    $view->{banner} = $self->_blob_url($c, $account->{did}, $banner_cid);
  }
  return $view;
}

sub _profile_associated ($self) {
  return {
    chat => {
      allowIncoming => 'all',
    },
    activitySubscription => {
      allowSubscriptions => 'followers',
    },
  };
}

sub _blob_cid ($self, $blob) {
  return undef unless ref($blob) eq 'HASH';
  return $blob->{ref}{'$link'} if ref($blob->{ref}) eq 'HASH' && defined $blob->{ref}{'$link'};
  return $blob->{ref} if defined $blob->{ref} && !ref($blob->{ref});
  return undef;
}

sub _blob_url ($self, $c, $did, $cid) {
  my $base = Mojo::URL->new($self->_config('base_url', 'http://127.0.0.1:7755'));
  $base->path('/xrpc/com.atproto.sync.getBlob');
  $base->query({ did => $did, cid => $cid });
  return $base->to_string;
}

sub _resolve_local_post_uri ($self, $c, $uri) {
  my ($repo, $collection, $rkey) = parse_at_uri($uri);
  return undef unless defined $repo && defined $collection && defined $rkey;
  return undef unless $collection eq 'app.bsky.feed.post';
  my $account = resolve_repo($c, $repo) or return undef;
  my $row = $c->store->get_record($account->{did}, $collection, $rkey) or return undef;
  return [ $account, $row ];
}

sub _post_uri ($self, $account, $row) {
  return 'at://' . $account->{did} . '/' . $row->{collection} . '/' . $row->{rkey};
}

sub _post_indexed_at ($self, $row) {
  return $row->{value}{createdAt}
    if ref($row->{value}) eq 'HASH' && defined $row->{value}{createdAt};
  return iso8601($row->{created_at} // $row->{updated_at});
}

sub _post_view ($self, $c, $account, $row, $profile_value = undef, $viewer = undef, $depth = 0) {
  my $uri = $self->_post_uri($account, $row);
  my $counts = $self->_post_counts_and_viewer($c, $uri, $viewer);
  my $post = {
    uri        => $uri,
    cid        => $row->{cid},
    author     => $self->_profile_view_basic($c, $account, $profile_value),
    record     => $row->{value},
    bookmarkCount => 0,
    replyCount => $counts->{replyCount},
    repostCount => $counts->{repostCount},
    likeCount  => $counts->{likeCount},
    quoteCount => $counts->{quoteCount},
    indexedAt  => $self->_post_indexed_at($row),
    labels     => [],
  };
  if ($depth < 2) {
    my $embed = $self->_post_embed_view($c, $account, $row->{value}, $viewer, $depth + 1);
    $post->{embed} = $embed if defined $embed;
  }
  $post->{viewer} = $counts->{viewer} if %{ $counts->{viewer} };
  return $post;
}

sub _thread_view ($self, $c, $account, $row, $profile_value = undef, $viewer = undef, $depth = 6) {
  my $thread = {
    '$type' => 'app.bsky.feed.defs#threadViewPost',
    post    => $self->_post_view($c, $account, $row, $profile_value, $viewer),
  };
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
    );
  }
  $thread->{replies} = \@replies if @replies;
  return $thread;
}

sub _reply_rows ($self, $c, $parent_uri) {
  my @matches;
  for my $account (@{ $c->store->list_accounts }) {
    for my $row (@{ $c->store->all_records_for_did($account->{did}) }) {
      next unless ($row->{collection} // q()) eq 'app.bsky.feed.post';
      my $reply = (ref($row->{value}) eq 'HASH') ? $row->{value}{reply} : undef;
      next unless ref($reply) eq 'HASH';
      next unless (($reply->{parent}{uri} // q()) eq $parent_uri);
      push @matches, [ $account, $row ];
    }
  }
  @matches = sort {
    $self->_post_indexed_at($a->[1]) cmp $self->_post_indexed_at($b->[1])
  } @matches;
  return @matches;
}

sub _post_counts_and_viewer ($self, $c, $post_uri, $viewer = undef) {
  my $cache = $c->stash('local_post_stats') // {};
  return $cache->{$post_uri} if $cache->{$post_uri};

  my $viewer_did = $viewer ? $viewer->{did} : undef;
  my $stats = {
    likeCount   => 0,
    repostCount => 0,
    replyCount  => 0,
    quoteCount  => 0,
    viewer      => {},
  };

  for my $account (@{ $c->store->list_accounts }) {
    for my $row (@{ $c->store->all_records_for_did($account->{did}) }) {
      my $value = $row->{value};
      next unless ref($value) eq 'HASH';

      if (($row->{collection} // q()) eq 'app.bsky.feed.like') {
        next unless (($value->{subject}{uri} // q()) eq $post_uri);
        $stats->{likeCount}++;
        $stats->{viewer}{like} = 'at://' . $account->{did} . '/' . $row->{collection} . '/' . $row->{rkey}
          if defined $viewer_did && $account->{did} eq $viewer_did;
      }
      elsif (($row->{collection} // q()) eq 'app.bsky.feed.repost') {
        next unless (($value->{subject}{uri} // q()) eq $post_uri);
        $stats->{repostCount}++;
        $stats->{viewer}{repost} = 'at://' . $account->{did} . '/' . $row->{collection} . '/' . $row->{rkey}
          if defined $viewer_did && $account->{did} eq $viewer_did;
      }
      elsif (($row->{collection} // q()) eq 'app.bsky.feed.post') {
        my $reply = $value->{reply};
        $stats->{replyCount}++
          if ref($reply) eq 'HASH' && (($reply->{parent}{uri} // q()) eq $post_uri);
        $stats->{quoteCount}++
          if ($self->_quoted_uri($value) // q()) eq $post_uri;
      }
    }
  }

  $cache->{$post_uri} = $stats;
  $c->stash(local_post_stats => $cache);
  return $stats;
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
      '$type'    => 'app.bsky.embed.external#view',
      external   => \%view,
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
      '$type'  => 'app.bsky.embed.recordWithMedia#view',
      record   => {
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
    '$type'    => 'app.bsky.embed.record#viewNotFound',
    uri        => $uri,
    notFound   => JSON::PP::true,
  } unless $resolved;

  my ($account, $row) = @$resolved;
  my $profile_value = $self->_profile_record_value($c, $account);
  my $post_view = $self->_post_view($c, $account, $row, $profile_value, $viewer, $depth);
  my %record_view = (
    '$type'     => 'app.bsky.embed.record#viewRecord',
    uri         => $post_view->{uri},
    cid         => $post_view->{cid},
    author      => $post_view->{author},
    value       => $post_view->{record},
    indexedAt   => $post_view->{indexedAt},
  );
  $record_view{labels} = $post_view->{labels} if $post_view->{labels};
  $record_view{replyCount} = $post_view->{replyCount} if defined $post_view->{replyCount};
  $record_view{repostCount} = $post_view->{repostCount} if defined $post_view->{repostCount};
  $record_view{likeCount} = $post_view->{likeCount} if defined $post_view->{likeCount};
  $record_view{quoteCount} = $post_view->{quoteCount} if defined $post_view->{quoteCount};
  $record_view{embeds} = [ $post_view->{embed} ] if defined $post_view->{embed};
  return \%record_view;
}

1;
