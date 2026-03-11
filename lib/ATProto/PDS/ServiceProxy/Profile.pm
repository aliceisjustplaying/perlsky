package ATProto::PDS::ServiceProxy::Profile;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use JSON::PP ();
use Mojo::URL;

use ATProto::PDS::API::Util qw(iso8601 resolve_repo xrpc_error);

our @EXPORT_OK = qw(
  _blob_cid
  _blob_url
  _get_local_profile
  _profile_associated
  _profile_record_value
  _profile_view_basic
  _profile_view_detailed
);

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
      lists        => 0,
      feedgens     => 0,
      starterPacks => 0,
      labeler      => JSON::PP::false,
    },
    viewer => {
      muted     => JSON::PP::false,
      blockedBy => JSON::PP::false,
    },
  };

  $c->render(json => $result);
  return 200;
}

sub _profile_record_value ($self, $c, $account) {
  my $profile = $c->store->get_record($account->{did}, 'app.bsky.actor.profile', 'self');
  return (ref($profile) eq 'HASH' && ref($profile->{value}) eq 'HASH') ? $profile->{value} : {};
}

sub _profile_view_basic ($self, $c, $account, $profile_value = undef) {
  $profile_value //= $self->_profile_record_value($c, $account);
  my $view = {
    did        => $account->{did},
    handle     => $account->{handle},
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

1;
