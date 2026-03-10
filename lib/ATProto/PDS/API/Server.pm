package ATProto::PDS::API::Server;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use Mojo::JSON qw(false true);

use ATProto::PDS::Auth::JWT qw(decode_jwt encode_jwt);
use ATProto::PDS::Auth::Password qw(hash_password verify_password);
use ATProto::PDS::Identity qw(account_did account_did_doc normalize_handle service_did);

our @EXPORT_OK = qw(register_server_handlers);

sub register_server_handlers ($registry, $app) {
  $registry->register('com.atproto.server.createAccount', sub ($c, $endpoint) {
    my $body   = $c->req->json || {};
    my $domain = $c->config_value('service_handle_domain', 'localhost');
    my $handle = normalize_handle($body->{handle}, $domain);
    _xrpc_error(400, 'InvalidHandle', 'Requested handle is invalid') unless defined $handle;
    _xrpc_error(400, 'UnsupportedDomain', 'Handle is outside the configured domain')
      unless $handle =~ /\.\Q$domain\E\z/ || $handle eq $domain;

    my $password = $body->{password} // '';
    _xrpc_error(400, 'InvalidPassword', 'Passwords must be at least 8 characters long')
      if length($password) < 8;
    _xrpc_error(400, 'HandleNotAvailable', 'That handle is already registered')
      if $c->store->get_account_by_handle($handle);

    my $account_id = _new_id();
    my $did        = $body->{did} || account_did($c->app->settings, $account_id);
    my $did_doc    = account_did_doc($c->app->settings, {
      id     => $account_id,
      did    => $did,
      handle => $handle,
    });

    my $account = $c->store->create_account(
      id            => $account_id,
      did           => $did,
      handle        => $handle,
      email         => $body->{email},
      password_hash => hash_password($password),
      did_doc       => $did_doc,
      recovery_key  => $body->{recoveryKey},
    );

    return _issue_session($c, $account);
  });

  $registry->register('com.atproto.server.createSession', sub ($c, $endpoint) {
    my $body = $c->req->json || {};
    my $account = _find_account($c, $body->{identifier} // '');
    _xrpc_error(401, 'AuthRequired', 'Invalid identifier or password') unless $account;

    my $password = $body->{password} // '';
    my $valid = verify_password($password, $account->{password_hash} // '');
    unless ($valid) {
      for my $app_password (@{ $c->store->list_app_passwords_by_did($account->{did}) }) {
        next if defined $app_password->{revoked_at};
        if (verify_password($password, $app_password->{password_hash} // '')) {
          $valid = 1;
          last;
        }
      }
    }

    _xrpc_error(401, 'AuthRequired', 'Invalid identifier or password') unless $valid;
    return _issue_session($c, $account);
  });

  $registry->register('com.atproto.server.getSession', sub ($c, $endpoint) {
    my ($claims, $account) = _require_auth($c, audience => 'access', allow_refresh => 1);
    return _session_view($account);
  });

  $registry->register('com.atproto.server.refreshSession', sub ($c, $endpoint) {
    my ($claims, $account) = _require_auth($c, audience => 'refresh');
    my $session = $c->store->get_session($claims->{jti});
    _xrpc_error(401, 'InvalidToken', 'Refresh session was not found') unless $session;
    _xrpc_error(401, 'ExpiredToken', 'Refresh session has already been revoked') if defined $session->{revoked_at};
    $c->store->revoke_session($session->{id});
    return _issue_session($c, $account);
  });

  $registry->register('com.atproto.server.deleteSession', sub ($c, $endpoint) {
    my ($claims, $account) = _require_auth($c, audience => 'refresh');
    my $session = $c->store->get_session($claims->{jti});
    _xrpc_error(401, 'InvalidToken', 'Refresh session was not found') unless $session;
    $c->store->revoke_session($session->{id});
    $c->res->code(200);
    return {};
  });

  $registry->register('com.atproto.server.createAppPassword', sub ($c, $endpoint) {
    my ($claims, $account) = _require_auth($c, audience => 'access', allow_refresh => 1);
    my $body = $c->req->json || {};
    my $name = $body->{name} // '';
    _xrpc_error(400, 'InvalidRequest', 'App password name is required') unless length $name;

    my $password = _new_app_password();
    my $row = $c->store->create_app_password(
      did           => $account->{did},
      name          => $name,
      password_hash => hash_password($password),
    );

    return {
      name       => $row->{name},
      password   => $password,
      createdAt  => _iso8601($row->{created_at}),
      privileged => $body->{privileged} ? true : false,
    };
  });

  $registry->register('com.atproto.server.listAppPasswords', sub ($c, $endpoint) {
    my ($claims, $account) = _require_auth($c, audience => 'access', allow_refresh => 1);
    my $rows = $c->store->list_app_passwords_by_did($account->{did});
    return {
      passwords => [
        map {
          +{
            name       => $_->{name},
            createdAt  => _iso8601($_->{created_at}),
            privileged => false,
          }
        }
        grep { !defined $_->{revoked_at} } @$rows
      ],
    };
  });

  $registry->register('com.atproto.server.revokeAppPassword', sub ($c, $endpoint) {
    my ($claims, $account) = _require_auth($c, audience => 'access', allow_refresh => 1);
    my $body = $c->req->json || {};
    my $name = $body->{name} // '';
    _xrpc_error(400, 'InvalidRequest', 'App password name is required') unless length $name;

    my $row = $c->store->get_app_password_by_name($account->{did}, $name);
    _xrpc_error(404, 'AppPasswordNotFound', 'No app password exists with that name') unless $row;
    $c->store->revoke_app_password($row->{id});
    $c->res->code(200);
    return {};
  });
}

sub _issue_session ($c, $account) {
  my $session = $c->store->create_session(
    did        => $account->{did},
    expires_at => time + (30 * 24 * 60 * 60),
  );

  my $issuer = service_did($c->app->settings);
  my $secret = $c->config_value('jwt_secret', 'perlds-dev-secret');
  my $now    = time;

  my $access = encode_jwt({
    iss => $issuer,
    sub => $account->{did},
    aud => 'access',
    typ => 'access',
    jti => $session->{id},
    exp => $now + 3600,
  }, $secret);

  my $refresh = encode_jwt({
    iss => $issuer,
    sub => $account->{did},
    aud => 'refresh',
    typ => 'refresh',
    jti => $session->{id},
    exp => $now + (30 * 24 * 60 * 60),
  }, $secret);

  return {
    accessJwt => $access,
    refreshJwt => $refresh,
    %{ _session_view($account) },
  };
}

sub _session_view ($account) {
  return {
    handle         => $account->{handle},
    did            => $account->{did},
    didDoc         => $account->{did_doc},
    email          => $account->{email},
    emailConfirmed => $account->{email} ? true : false,
    emailAuthFactor => false,
    active         => !defined($account->{deactivated_at}) ? true : false,
    (defined($account->{deactivated_at}) ? (status => 'deactivated') : ()),
  };
}

sub _find_account ($c, $identifier) {
  return undef unless defined $identifier && length $identifier;
  return $c->store->get_account_by_did($identifier) if $identifier =~ /\Adid:/;
  my $account = $c->store->get_account_by_handle($identifier);
  return $account if $account;
  return $c->store->get_account_by_email($identifier);
}

sub _require_auth ($c, %opts) {
  my $auth = $c->req->headers->authorization // '';
  _xrpc_error(401, 'AuthRequired', 'Authorization header is required') unless $auth =~ /\ABearer\s+(.+)\z/i;
  my $token = $1;

  my $decoded = eval {
    decode_jwt($token, $c->config_value('jwt_secret', 'perlds-dev-secret'))
  };
  if (my $err = $@) {
    my $message = "$err";
    my $code = $message =~ /expired/ ? 'ExpiredToken' : 'InvalidToken';
    _xrpc_error(401, $code, $message);
  }

  my $claims = $decoded->{claims};
  my $aud = $claims->{aud} // q();
  my $ok = $aud eq ($opts{audience} // 'access')
    || ($opts{allow_refresh} && $aud eq 'refresh');
  _xrpc_error(401, 'InvalidToken', 'Unexpected token audience') unless $ok;

  my $account = $c->store->get_account_by_did($claims->{sub});
  _xrpc_error(401, 'InvalidToken', 'Token subject no longer exists') unless $account;
  return ($claims, $account);
}

sub _xrpc_error ($status, $error, $message) {
  die {
    status  => $status,
    error   => $error,
    message => $message,
  };
}

sub _new_id {
  open(my $fh, '<:raw', '/dev/urandom') or die "open(/dev/urandom): $!";
  my $bytes = q();
  my $read = read($fh, $bytes, 10);
  CORE::close($fh);
  die 'failed to read random bytes' unless defined $read && $read == 10;
  return unpack('H*', $bytes);
}

sub _new_app_password {
  my @parts;
  push @parts, substr(_new_id(), 0, 4) for 1 .. 4;
  return join('-', @parts);
}

sub _iso8601 ($epoch) {
  my @gmt = gmtime($epoch // time);
  return sprintf(
    '%04d-%02d-%02dT%02d:%02d:%02dZ',
    $gmt[5] + 1900,
    $gmt[4] + 1,
    $gmt[3],
    $gmt[2],
    $gmt[1],
    $gmt[0],
  );
}

1;
