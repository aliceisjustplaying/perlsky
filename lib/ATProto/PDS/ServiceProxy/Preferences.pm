package ATProto::PDS::ServiceProxy::Preferences;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use JSON::PP ();
use Time::Piece ();

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

  my (undef, $account, $session) = require_auth(
    $c,
    audience            => TOKEN_AUD_ACCESS,
    required_permission => {
      type => 'rpc',
      aud  => $self->_permission_audience_for_request($c, 'app.bsky.actor.getPreferences'),
      lxm  => 'app.bsky.actor.getPreferences',
    },
  );
  my $preferences = _visible_preferences(
    $c->store->list_preferences($account->{did}, 'app.bsky'),
    session => $session,
  );
  $c->render(json => { preferences => $preferences });
  return 200;
}

sub _put_preferences ($self, $c) {
  xrpc_error(405, 'MethodNotAllowed', 'app.bsky.actor.putPreferences expects POST')
    unless $c->req->method eq 'POST';

  my (undef, $account, $session) = require_auth(
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
    xrpc_error(400, 'InvalidRequest', 'Some preferences are not in the app.bsky namespace')
      unless _pref_matches_namespace('app.bsky', $pref->{'$type'});
    xrpc_error(400, 'InvalidRequest', 'Do not have authorization to set preferences: app.bsky.actor.defs#personalDetailsPref')
      if _pref_requires_full_access($pref->{'$type'}) && _session_is_app_password($session);
  }

  my @stored = grep { !_pref_is_read_only($_->{'$type'} // q()) } @$preferences;
  $c->store->put_preferences($account->{did}, 'app.bsky', \@stored);
  $c->render(data => q());
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
  _validate_notification_preferences_patch($body);

  my $preferences = {
    %{ $self->_load_notification_preferences($c, $account->{did}) },
    %{$body},
  };
  $c->store->put_notification_preferences($account->{did}, $preferences);
  $c->render(json => { preferences => $preferences });
  return 200;
}

sub _visible_preferences ($preferences, %opts) {
  my @prefs = map { { %$_ } } @{ $preferences || [] };
  my $declared_age = _declared_age_pref(\@prefs);
  if (_session_is_app_password($opts{session})) {
    @prefs = grep {
      my $type = $_->{'$type'} // q();
      $type ne 'app.bsky.actor.defs#personalDetailsPref';
    } @prefs;
  }

  push @prefs, $declared_age if $declared_age;
  return \@prefs;
}

sub _declared_age_pref ($preferences) {
  my ($personal) = grep {
    ($_->{'$type'} // q()) eq 'app.bsky.actor.defs#personalDetailsPref'
  } @$preferences;
  return undef unless $personal && defined($personal->{birthDate}) && !ref($personal->{birthDate});
  my ($year, $month, $day) = ($personal->{birthDate} =~ /\A(\d{4})-(\d{2})-(\d{2})/);
  return undef unless defined $year;

  my $today = Time::Piece::gmtime(time);
  my $age = $today->year - $year;
  $age-- if ($today->mon < $month) || ($today->mon == $month && $today->mday < $day);

  return {
    '$type'      => 'app.bsky.actor.defs#declaredAgePref',
    isOverAge13  => $age >= 13 ? JSON::PP::true : JSON::PP::false,
    isOverAge16  => $age >= 16 ? JSON::PP::true : JSON::PP::false,
    isOverAge18  => $age >= 18 ? JSON::PP::true : JSON::PP::false,
  };
}

sub _pref_matches_namespace ($namespace, $type) {
  return $type eq $namespace || $type =~ /^\Q$namespace\E\./;
}

sub _pref_requires_full_access ($type) {
  return $type eq 'app.bsky.actor.defs#personalDetailsPref';
}

sub _pref_is_read_only ($type) {
  return $type eq 'app.bsky.actor.defs#declaredAgePref';
}

sub _session_is_app_password ($session) {
  return defined($session) && (($session->{kind} // q()) eq 'app_password');
}

sub _validate_notification_preferences_patch ($body) {
  my $defaults = _default_notification_preferences();
  for my $category (keys %$body) {
    xrpc_error(400, 'InvalidRequest', "Unsupported notification preference category: $category")
      unless exists $defaults->{$category};
    my $value = $body->{$category};
    xrpc_error(400, 'InvalidRequest', "Notification preference $category must be an object")
      unless ref($value) eq 'HASH';
    my %allowed = map { $_ => 1 } keys %{ $defaults->{$category} };
    for my $key (keys %$value) {
      xrpc_error(400, 'InvalidRequest', "Unsupported notification preference field: $category.$key")
        unless $allowed{$key};
      if ($key eq 'include') {
        xrpc_error(400, 'InvalidRequest', "Notification preference $category.$key must be a string")
          if ref($value->{$key});
        next;
      }
      xrpc_error(400, 'InvalidRequest', "Notification preference $category.$key must be a boolean")
        unless JSON::PP::is_bool($value->{$key});
    }
  }
  return 1;
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
