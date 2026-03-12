package ATProto::PDS::ServiceProxy::Preferences;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use JSON::PP ();

use ATProto::PDS::API::Server qw(require_auth);
use ATProto::PDS::API::Util qw(xrpc_error);
use ATProto::PDS::Constants qw(TOKEN_AUD_ACCESS);

our @EXPORT_OK = qw(
  _default_notification_preferences
  _get_notification_preferences
  _get_preferences
  _load_notification_preferences
  _put_notification_preferences_v2
  _put_preferences
);

sub _get_preferences ($self, $c) {
  xrpc_error(405, 'MethodNotAllowed', 'app.bsky.actor.getPreferences expects GET')
    unless $c->req->method eq 'GET';

  my (undef, $account) = require_auth(
    $c,
    audience            => TOKEN_AUD_ACCESS,
    required_permission => {
      type => 'rpc',
      aud  => $self->_permission_audience_for_request($c, 'app.bsky.actor.getPreferences'),
      lxm  => 'app.bsky.actor.getPreferences',
    },
  );
  my $preferences = $c->store->list_preferences($account->{did}, 'app.bsky');
  $c->render(json => { preferences => $preferences });
  return 200;
}

sub _put_preferences ($self, $c) {
  xrpc_error(405, 'MethodNotAllowed', 'app.bsky.actor.putPreferences expects POST')
    unless $c->req->method eq 'POST';

  my (undef, $account) = require_auth(
    $c,
    audience            => TOKEN_AUD_ACCESS,
    required_permission => {
      type => 'rpc',
      aud  => $self->_permission_audience_for_request($c, 'app.bsky.actor.putPreferences'),
      lxm  => 'app.bsky.actor.putPreferences',
    },
  );
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

sub _get_notification_preferences ($self, $c) {
  xrpc_error(405, 'MethodNotAllowed', 'app.bsky.notification.getPreferences expects GET')
    unless $c->req->method eq 'GET';

  my (undef, $account) = require_auth(
    $c,
    audience            => TOKEN_AUD_ACCESS,
    required_permission => {
      type => 'rpc',
      aud  => $self->_permission_audience_for_request($c, 'app.bsky.notification.getPreferences'),
      lxm  => 'app.bsky.notification.getPreferences',
    },
  );
  my $preferences = $self->_load_notification_preferences($c, $account->{did});
  $c->render(json => { preferences => $preferences });
  return 200;
}

sub _put_notification_preferences_v2 ($self, $c) {
  xrpc_error(405, 'MethodNotAllowed', 'app.bsky.notification.putPreferencesV2 expects POST')
    unless $c->req->method eq 'POST';

  my (undef, $account) = require_auth(
    $c,
    audience            => TOKEN_AUD_ACCESS,
    required_permission => {
      type => 'rpc',
      aud  => $self->_permission_audience_for_request($c, 'app.bsky.notification.putPreferencesV2'),
      lxm  => 'app.bsky.notification.putPreferencesV2',
    },
  );
  my $body = $c->req->json || {};
  xrpc_error(400, 'InvalidRequest', 'notification preferences body must be an object')
    unless ref($body) eq 'HASH';

  my $preferences = {
    %{ $self->_load_notification_preferences($c, $account->{did}) },
    %{$body},
  };
  $c->store->put_notification_preferences($account->{did}, $preferences);
  $c->render(json => { preferences => $preferences });
  return 200;
}

sub _load_notification_preferences ($self, $c, $did) {
  my $stored = $c->store->get_notification_preferences($did);
  return {
    %{ _default_notification_preferences() },
    %{ $stored // {} },
  };
}

sub _default_notification_preferences () {
  my $filterable = {
    include => 'all',
    list    => JSON::PP::true,
    push    => JSON::PP::true,
  };
  my $plain = {
    list => JSON::PP::true,
    push => JSON::PP::true,
  };
  return {
    chat              => { include => 'all', push => JSON::PP::true },
    follow            => { %{$filterable} },
    like              => { %{$filterable} },
    likeViaRepost     => { %{$filterable} },
    mention           => { %{$filterable} },
    quote             => { %{$filterable} },
    reply             => { %{$filterable} },
    repost            => { %{$filterable} },
    repostViaRepost   => { %{$filterable} },
    starterpackJoined => { %{$plain} },
    subscribedPost    => { %{$plain} },
    unverified        => { %{$plain} },
    verified          => { %{$plain} },
  };
}

1;
