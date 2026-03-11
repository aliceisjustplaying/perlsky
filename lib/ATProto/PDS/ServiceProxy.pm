package ATProto::PDS::ServiceProxy;

use v5.34;
use warnings;

use Mojo::Base -base, -signatures;
use Mojo::URL;
use Mojo::UserAgent;

use ATProto::PDS::API::Server qw(require_auth);
use ATProto::PDS::API::Util qw(xrpc_error);
use ATProto::PDS::Auth::JWT qw(encode_service_jwt);
use ATProto::PDS::Constants qw(TOKEN_AUD_ACCESS);
use ATProto::PDS::ServiceProxy::Posts qw(
  _non_negative_int_param
  _post_indexed_at
  _post_uri
  _quoted_uri
  _reply_parent_uri
  _resolve_local_post_uri
);
use ATProto::PDS::ServiceProxy::Preferences qw(
  _default_notification_preferences
  _get_notification_preferences
  _get_preferences
  _load_notification_preferences
  _put_notification_preferences_v2
  _put_preferences
);
use ATProto::PDS::ServiceProxy::Profile qw(
  _blob_cid
  _blob_url
  _get_local_profile
  _profile_associated
  _profile_record_value
  _profile_view_basic
  _profile_view_detailed
);
use ATProto::PDS::ServiceProxy::Threads qw(
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
use ATProto::PDS::ServiceProxy::Upstream qw(
  _config
  _perform_upstream_request
  _target_for_request
  _target_from_proxy_header
);

has settings => sub { {} };
has local_post_index_cache => sub { undef };
has ua => sub {
  my $ua = Mojo::UserAgent->new(max_redirects => 0);
  $ua->request_timeout(15);
  $ua->inactivity_timeout(30);
  return $ua;
};

my %LOCAL_HANDLER_FOR = (
  'app.bsky.actor.getPreferences'         => '_get_preferences',
  'app.bsky.actor.putPreferences'         => '_put_preferences',
  'app.bsky.notification.getPreferences'  => '_get_notification_preferences',
  'app.bsky.notification.putPreferencesV2' => '_put_notification_preferences_v2',
  'app.bsky.actor.getProfile'             => '_get_local_profile',
  'app.bsky.feed.getAuthorFeed'           => '_get_author_feed',
  'app.bsky.feed.getPosts'                => '_get_posts',
  'app.bsky.feed.getPostThread'           => '_get_post_thread',
);

sub proxy_xrpc_request ($self, $c, $nsid) {
  if (my $handler = $LOCAL_HANDLER_FOR{$nsid}) {
    my $status = $self->$handler($c);
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
    my (undef, $account) = require_auth($c, audience => TOKEN_AUD_ACCESS);
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

  my $res = $self->_perform_upstream_request(
    method  => $method,
    url     => $url,
    headers => \%headers,
    body    => ($c->req->body // q()),
  );

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

1;
