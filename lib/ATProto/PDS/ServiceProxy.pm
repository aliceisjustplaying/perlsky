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

  my (undef, $viewer) = require_auth($c, audience => 'access', allow_refresh => 1);
  my $actor = $c->param('actor') // q();
  xrpc_error(400, 'InvalidRequest', 'actor is required') unless length $actor;

  my $account = resolve_repo($c, $actor) or return undef;
  my $profile = $c->store->get_record($account->{did}, 'app.bsky.actor.profile', 'self');
  my $value = (ref($profile) eq 'HASH' && ref($profile->{value}) eq 'HASH') ? $profile->{value} : {};

  my $result = {
    did        => $account->{did},
    handle     => $account->{handle},
    associated => {
      lists               => 0,
      feedgens            => 0,
      starterPacks        => 0,
      labeler             => JSON::PP::false,
      activitySubscription => {
        allowSubscriptions => 'followers',
      },
    },
    viewer => {
      muted     => JSON::PP::false,
      blockedBy => JSON::PP::false,
    },
    labels         => [],
    createdAt      => iso8601($account->{created_at}),
    followersCount => 0,
    followsCount   => 0,
    postsCount     => 0 + $c->store->count_records_by_did($account->{did}),
  };

  $result->{displayName} = $value->{displayName} if defined $value->{displayName};
  $result->{description} = $value->{description} if defined $value->{description};

  $c->render(json => $result);
  return 200;
}

1;
