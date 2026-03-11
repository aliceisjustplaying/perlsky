package ATProto::PDS::API::Server;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use JSON::PP ();

use ATProto::PDS::API::Helpers qw(find_account invite_code_view issue_account_action_token require_admin verify_account_password verify_login_password);
use ATProto::PDS::API::Util qw(iso8601 xrpc_error);
use ATProto::PDS::Auth::JWT qw(decode_jwt encode_jwt encode_service_jwt);
use ATProto::PDS::Auth::Password qw(hash_password random_hex);
use ATProto::PDS::Constants qw(
  ACTION_TOKEN_ACCOUNT_DELETE
  ACTION_TOKEN_EMAIL_CONFIRM
  ACTION_TOKEN_EMAIL_UPDATE
  ACTION_TOKEN_PASSWORD_RESET
  EVENT_TYPE_ACCOUNT
  EVENT_TYPE_COMMIT
  EVENT_TYPE_IDENTITY
  EVENT_TYPE_SYNC
  TOKEN_AUD_ACCESS
  TOKEN_AUD_REFRESH
);
use ATProto::PDS::Identity qw(account_did account_did_doc normalize_handle service_did);
use ATProto::PDS::Moderation qw(assert_login_allowed is_repo_takedown);
use ATProto::PDS::PLC qw(account_did_method create_plc_account is_plc_did refresh_plc_did_doc);
use ATProto::PDS::Repo::CAR qw(read_car);

our @EXPORT_OK = qw(register_server_handlers require_auth session_view);

my %PROTECTED_SERVICE_AUTH_METHOD = map { lc($_) => 1 } qw(
  com.atproto.identity.requestPlcOperationSignature
  com.atproto.identity.signPlcOperation
  com.atproto.identity.updateHandle
  com.atproto.server.activateAccount
  com.atproto.server.confirmEmail
  com.atproto.server.createAppPassword
  com.atproto.server.deactivateAccount
  com.atproto.server.getAccountInviteCodes
  com.atproto.server.getSession
  com.atproto.server.listAppPasswords
  com.atproto.server.requestAccountDelete
  com.atproto.server.requestEmailConfirmation
  com.atproto.server.requestEmailUpdate
  com.atproto.server.revokeAppPassword
  com.atproto.server.updateEmail
);

sub register_server_handlers ($registry, $app) {
  $registry->register('com.atproto.server.createAccount', sub ($c, $endpoint) {
    my $body   = $c->req->json || {};
    my $domain = $c->config_value('service_handle_domain', 'localhost');
    my $handle = normalize_handle($body->{handle}, $domain);
    xrpc_error(400, 'InvalidHandle', 'Requested handle is invalid') unless defined $handle;
    xrpc_error(400, 'HandleNotAvailable', 'That handle is already registered')
      if $c->store->get_account_by_handle($handle);
    xrpc_error(400, 'HandleNotAvailable', 'That handle is reserved')
      if $c->store->get_reserved_handle($handle);

    my $password = $body->{password} // q();
    xrpc_error(400, 'InvalidPassword', 'Passwords must be at least 8 characters long')
      if length($password) < 8;

    my $invite;
    if (defined($body->{inviteCode}) && length($body->{inviteCode})) {
      $invite = $c->store->get_invite_code($body->{inviteCode});
      xrpc_error(400, 'InvalidInviteCode', 'Invite code is not valid') unless $invite;
      my $available = ($invite->{use_count} // 0) - ($invite->{use_count_consumed} // 0);
      xrpc_error(400, 'InvalidInviteCode', 'Invite code has been exhausted')
        if $invite->{disabled} || $available <= 0;
    } elsif ($c->config_value('invite_code_required', 0)) {
      xrpc_error(400, 'InvalidInviteCode', 'Invite code is required');
    }

    my $account_id = random_hex(8);
    my $did_method = account_did_method($c->app->settings);
    my $did        = $body->{did};
    my $reserved   = $body->{did} ? $c->store->get_reserved_signing_key($did) : undef;
    my $keys       = ($reserved && !defined $reserved->{claimed_at})
      ? {
          private_key          => $reserved->{private_key},
          public_key           => $reserved->{public_key},
          public_key_multibase => $reserved->{public_key_multibase},
          signing_key_did      => $reserved->{signing_key_did},
        }
      : $c->repo_manager->generate_signing_key;
    my $did_doc;
    if (!$did) {
      if ($did_method eq 'did:plc') {
        my $plc = create_plc_account(
          $c->app->settings,
          handle          => $handle,
          signing_key_did => $keys->{signing_key_did},
        );
        $did     = $plc->{did};
        $did_doc = $plc->{did_doc};
      } else {
        $did = account_did($c->app->settings, $account_id);
      }
    }
    my $password_record = hash_password($password);
    $did_doc //= account_did_doc($c->app->settings, {
      account_id            => $account_id,
      did                   => $did,
      handle                => $handle,
      public_key_multibase  => $keys->{public_key_multibase},
      signing_key_did       => $keys->{signing_key_did},
    });

    my $account = $c->store->create_account(
      account_id            => $account_id,
      did                   => $did,
      handle                => $handle,
      email                 => $body->{email},
      email_confirmed_at    => _initial_email_confirmed_at($c, $body->{email}),
      password_hash         => $password_record->{hash},
      password_salt         => $password_record->{salt},
      did_doc               => $did_doc,
      private_key           => $keys->{private_key},
      public_key            => $keys->{public_key},
      public_key_multibase  => $keys->{public_key_multibase},
      signing_key_did       => $keys->{signing_key_did},
    );

    my $repo = $c->repo_manager->initialize_repo($account);
    $account = $c->store->update_account($account->{did},
      repo_commit_cid => $repo->{cid},
      repo_root_cid   => $repo->{root_cid},
      repo_rev        => $repo->{rev},
      did_doc         => is_plc_did($account->{did}) ? refresh_plc_did_doc($c->app->settings, $account->{did}) : account_did_doc($c->app->settings, $account),
    );

    $c->store->record_invite_code_use(
      code    => $invite->{code},
      used_by => $account->{did},
    ) if $invite;
    $c->store->claim_reserved_signing_key($did) if $reserved && !defined $reserved->{claimed_at};
    $c->append_event(
      did     => $account->{did},
      type    => EVENT_TYPE_IDENTITY,
      rev     => $account->{repo_rev},
      payload => {
        did    => $account->{did},
        handle => $account->{handle},
      },
    );
    $c->append_event(
      did     => $account->{did},
      type    => EVENT_TYPE_ACCOUNT,
      rev     => $account->{repo_rev},
      payload => {
        active => JSON::PP::true,
      },
    );
    $c->append_event(
      did        => $account->{did},
      type       => EVENT_TYPE_COMMIT,
      rev        => $account->{repo_rev},
      commit_cid => $repo->{cid},
      payload    => {
        ops   => [],
        since => undef,
      },
      car_bytes  => $repo->{car_bytes},
    );
    $c->append_event(
      did        => $account->{did},
      type       => EVENT_TYPE_SYNC,
      rev        => $account->{repo_rev},
      commit_cid => $repo->{cid},
      car_bytes  => $repo->{sync_car_bytes},
      payload    => {
        did => $account->{did},
      },
    );

    return _issue_session($c, $account);
  });

  $registry->register('com.atproto.server.createSession', sub ($c, $endpoint) {
    my $body = $c->req->json || {};
    my $account = find_account($c, $body->{identifier} // q());
    xrpc_error(401, 'AuthRequired', 'Invalid identifier or password') unless $account;
    my $authn = verify_login_password($c, $account, $body->{password} // q());
    xrpc_error(401, 'AuthRequired', 'Invalid identifier or password') unless $authn;
    if (($authn->{kind} // q()) eq 'app_password' && is_repo_takedown($c, $account->{did})) {
      xrpc_error(401, 'AuthRequired', 'Invalid identifier or password');
    }
    assert_login_allowed($c, $account, allow_takedown => $body->{allowTakendown});
    return _issue_session($c, $account,
      kind          => $authn->{kind},
      scope         => $authn->{scope},
      session_token => $authn->{app_password_name},
    );
  });

  $registry->register('com.atproto.server.getSession', sub ($c, $endpoint) {
    my (undef, $account) = require_auth($c, audience => TOKEN_AUD_ACCESS);
    return session_view($account);
  });

  $registry->register('com.atproto.server.refreshSession', sub ($c, $endpoint) {
    my (undef, $account, $session) = require_auth($c, audience => TOKEN_AUD_REFRESH);
    assert_login_allowed($c, $account);
    my $rotated = $c->store->rotate_session($session->{id});
    xrpc_error(401, 'ExpiredToken', 'Refresh session has already been revoked') unless $rotated;
    return _session_response($c, $account, $rotated);
  });

  $registry->register('com.atproto.server.deleteSession', sub ($c, $endpoint) {
    my ($claims) = require_auth($c, audience => TOKEN_AUD_REFRESH, allow_refresh => 1);
    my $session = $c->store->get_session($claims->{jti});
    $c->store->revoke_session($session->{id}) if $session;
    return {};
  });

  $registry->register('com.atproto.server.checkAccountStatus', sub ($c, $endpoint) {
    my (undef, $account) = require_auth($c, audience => TOKEN_AUD_ACCESS);
    my $car = $c->store->repo_car($account->{did});
    my $block_count = 0;
    my $blob_count = 0 + $c->store->count_blobs_by_did($account->{did});
    $block_count = scalar @{ read_car($car)->{blocks} } if defined $car && length $car;
    return {
      activated          => (!defined($account->{deactivated_at}) && !defined($account->{deleted_at}))
        ? JSON::PP::true
        : JSON::PP::false,
      validDid           => ($account->{did} // q()) =~ /^did:/ ? JSON::PP::true : JSON::PP::false,
      repoCommit         => $account->{repo_commit_cid} // q(),
      repoRev            => $account->{repo_rev} // q(),
      repoBlocks         => 0 + $block_count,
      indexedRecords     => 0 + $c->store->count_records_by_did($account->{did}),
      privateStateValues => 0,
      expectedBlobs      => $blob_count,
      importedBlobs      => $blob_count,
    };
  });

  $registry->register('com.atproto.server.createAppPassword', sub ($c, $endpoint) {
    my (undef, $account) = require_auth($c, audience => TOKEN_AUD_ACCESS, required_scope => 'full');
    my $body = $c->req->json || {};
    my $name = $body->{name} // q();
    xrpc_error(400, 'InvalidRequest', 'App password name is required') unless length $name;

    my $password = _new_app_password();
    my $password_record = hash_password($password);
    my $row = $c->store->create_app_password(
      did           => $account->{did},
      name          => $name,
      password_hash => unpack('H*', $password_record->{salt}) . ':' . $password_record->{hash},
      privileged    => $body->{privileged} ? 1 : 0,
    );

    return {
      name       => $row->{name},
      password   => $password,
      createdAt  => iso8601($row->{created_at}),
      privileged => $row->{privileged} ? JSON::PP::true : JSON::PP::false,
    };
  });

  $registry->register('com.atproto.server.listAppPasswords', sub ($c, $endpoint) {
    my (undef, $account) = require_auth($c, audience => TOKEN_AUD_ACCESS);
    my $rows = $c->store->list_app_passwords_by_did($account->{did});
    return {
      passwords => [
        map {
          +{
            name       => $_->{name},
            createdAt  => iso8601($_->{created_at}),
            privileged => $_->{privileged} ? JSON::PP::true : JSON::PP::false,
          }
        } grep { !defined $_->{revoked_at} } @$rows
      ],
    };
  });

  $registry->register('com.atproto.server.revokeAppPassword', sub ($c, $endpoint) {
    my (undef, $account) = require_auth($c, audience => TOKEN_AUD_ACCESS);
    my $body = $c->req->json || {};
    my $name = $body->{name} // q();
    xrpc_error(400, 'InvalidRequest', 'App password name is required') unless length $name;
    my $row = $c->store->get_app_password_by_name($account->{did}, $name);
    xrpc_error(404, 'AppPasswordNotFound', 'No app password exists with that name') unless $row;
    $c->store->revoke_app_password($row->{id});
    for my $session (@{ $c->store->list_sessions_by_did($account->{did}) }) {
      next unless ($session->{kind} // q()) eq 'app_password';
      next unless ($session->{token} // q()) eq $name;
      next if defined $session->{revoked_at};
      $c->store->revoke_session($session->{id});
    }
    return {};
  });

  $registry->register('com.atproto.server.deactivateAccount', sub ($c, $endpoint) {
    my (undef, $account) = require_auth($c, audience => TOKEN_AUD_ACCESS, required_scope => 'full');
    $c->store->update_account($account->{did}, deactivated_at => time);
    $c->append_event(
      did     => $account->{did},
      type    => EVENT_TYPE_ACCOUNT,
      rev     => $account->{repo_rev},
      payload => {
        active => JSON::PP::false,
        status => 'deactivated',
      },
    );
    return {};
  });

  $registry->register('com.atproto.server.activateAccount', sub ($c, $endpoint) {
    my (undef, $account) = require_auth($c, audience => TOKEN_AUD_ACCESS, required_scope => 'full');
    $account = $c->store->update_account($account->{did}, deactivated_at => undef);
    $c->append_event(
      did     => $account->{did},
      type    => EVENT_TYPE_ACCOUNT,
      rev     => $account->{repo_rev},
      payload => {
        active => JSON::PP::true,
      },
    );
    $c->append_event(
      did     => $account->{did},
      type    => EVENT_TYPE_IDENTITY,
      rev     => $account->{repo_rev},
      payload => {
        did    => $account->{did},
        handle => $account->{handle},
      },
    );
    my $commit = $c->store->get_latest_commit($account->{did});
    if ($commit) {
      my $sync_car = $c->repo_manager->sync_car_for_commit($commit);
      $c->append_event(
        did        => $account->{did},
        type       => EVENT_TYPE_SYNC,
        rev        => $account->{repo_rev},
        commit_cid => $commit->{cid},
        car_bytes  => $sync_car,
        payload    => {
          did => $account->{did},
        },
      ) if defined $sync_car;
    }
    return {};
  });

  $registry->register('com.atproto.server.requestPasswordReset', sub ($c, $endpoint) {
    my $body = $c->req->json || {};
    my $account = $c->store->get_account_by_email($body->{email} // q());
    if ($account) {
      issue_account_action_token(
        $c,
        $account,
        purpose => ACTION_TOKEN_PASSWORD_RESET,
        subject => 'perlsky password reset',
        content => sub ($token) { "Use token $token->{token} to reset your password." },
      );
    }
    return {};
  });

  $registry->register('com.atproto.server.resetPassword', sub ($c, $endpoint) {
    my $body = $c->req->json || {};
    xrpc_error(400, 'InvalidPassword', 'Passwords must be at least 8 characters long')
      if length($body->{password} // q()) < 8;
    my $token = _require_action_token($c,
      token   => $body->{token},
      purpose => ACTION_TOKEN_PASSWORD_RESET,
    );
    my $account = $c->store->get_account_by_did($token->{did});
    xrpc_error(404, 'AccountNotFound', 'Account was not found') unless $account;
    my $password_record = hash_password($body->{password});
    $c->store->txn(sub ($dbh) {
      $c->store->update_account(
        $account->{did},
        password_hash => $password_record->{hash},
        password_salt => $password_record->{salt},
      );
      $c->store->revoke_sessions_by_did($account->{did});
      $c->store->revoke_app_passwords_by_did($account->{did});
      $c->store->consume_action_token($token->{token});
    });
    return {};
  });

  $registry->register('com.atproto.server.requestEmailConfirmation', sub ($c, $endpoint) {
    my (undef, $account) = require_auth($c, audience => TOKEN_AUD_ACCESS);
    return {} unless $account->{email};
    issue_account_action_token(
      $c,
      $account,
      purpose => ACTION_TOKEN_EMAIL_CONFIRM,
      subject => 'perlsky email confirmation',
      content => sub ($token) { "Use token $token->{token} to confirm your email address." },
    );
    return {};
  });

  $registry->register('com.atproto.server.confirmEmail', sub ($c, $endpoint) {
    my $body = $c->req->json || {};
    my $token = _require_action_token($c,
      token   => $body->{token},
      purpose => ACTION_TOKEN_EMAIL_CONFIRM,
    );
    my $account = $c->store->get_account_by_did($token->{did});
    xrpc_error(404, 'AccountNotFound', 'Account was not found') unless $account;
    my $email = $body->{email} // q();
    xrpc_error(400, 'InvalidEmail', 'Token was not issued for that email')
      unless length($email)
      && ($token->{email} // q()) eq $email
      && ($account->{email} // q()) eq $email;
    $c->store->txn(sub ($dbh) {
      $c->store->update_account($account->{did}, email_confirmed_at => time);
      $c->store->consume_action_token($token->{token});
    });
    return {};
  });

  $registry->register('com.atproto.server.requestEmailUpdate', sub ($c, $endpoint) {
    my (undef, $account) = require_auth($c, audience => TOKEN_AUD_ACCESS);
    my $token_required = defined $account->{email_confirmed_at} ? 1 : 0;
    if ($token_required) {
      issue_account_action_token(
        $c,
        $account,
        purpose => ACTION_TOKEN_EMAIL_UPDATE,
        subject => 'perlsky email change authorization',
        content => sub ($token) { "Use token $token->{token} to update your email address." },
      );
    }
    return {
      tokenRequired => $token_required ? JSON::PP::true : JSON::PP::false,
    };
  });

  $registry->register('com.atproto.server.updateEmail', sub ($c, $endpoint) {
    my (undef, $account) = require_auth($c, audience => TOKEN_AUD_ACCESS, required_scope => 'full');
    my $body = $c->req->json || {};
    if (defined $account->{email_confirmed_at}) {
      xrpc_error(400, 'TokenRequired', 'A confirmation token is required to update email')
        unless defined($body->{token}) && length($body->{token});
      my $token = _require_action_token($c,
        token   => $body->{token},
        purpose => ACTION_TOKEN_EMAIL_UPDATE,
      );
      xrpc_error(400, 'InvalidToken', 'Token was not issued for this account')
        unless ($token->{did} // q()) eq $account->{did};
      $c->store->consume_action_token($token->{token});
    }
    $c->store->update_account(
      $account->{did},
      email              => $body->{email},
      email_confirmed_at => undef,
    );
    return {};
  });

  $registry->register('com.atproto.server.requestAccountDelete', sub ($c, $endpoint) {
    my (undef, $account) = require_auth($c, audience => TOKEN_AUD_ACCESS, required_scope => 'full');
    issue_account_action_token(
      $c,
      $account,
      purpose => ACTION_TOKEN_ACCOUNT_DELETE,
      subject => 'perlsky account deletion',
      content => sub ($token) { "Use token $token->{token} to delete your account." },
    );
    return {};
  });

  $registry->register('com.atproto.server.deleteAccount', sub ($c, $endpoint) {
    my ($claims, $account) = require_auth($c, audience => TOKEN_AUD_ACCESS, required_scope => 'full');
    my $body = $c->req->json || {};
    xrpc_error(401, 'AuthRequired', 'Token is not authorized for that repo')
      unless ($claims->{sub} // q()) eq ($body->{did} // q()) && ($account->{did} // q()) eq ($body->{did} // q());
    xrpc_error(401, 'AuthRequired', 'Invalid identifier or password')
      unless verify_account_password($c, $account, $body->{password} // q());
    my $token = _require_action_token($c,
      token   => $body->{token},
      purpose => ACTION_TOKEN_ACCOUNT_DELETE,
    );
    xrpc_error(400, 'InvalidToken', 'Token was not issued for this account')
      unless ($token->{did} // q()) eq $account->{did};
    $c->store->txn(sub ($dbh) {
      $c->store->update_account(
        $account->{did},
        deactivated_at => time,
        deleted_at     => time,
      );
      $c->store->revoke_sessions_by_did($account->{did});
      $c->store->revoke_app_passwords_by_did($account->{did});
      $c->store->consume_action_token($token->{token});
      $c->append_event(
        did     => $account->{did},
        type    => EVENT_TYPE_ACCOUNT,
        rev     => $account->{repo_rev},
        payload => {
          active => JSON::PP::false,
          status => 'deleted',
        },
      );
    });
    return {};
  });

  $registry->register('com.atproto.server.getServiceAuth', sub ($c, $endpoint) {
    my ($claims, $account, $session) = require_auth($c, audience => TOKEN_AUD_ACCESS);
    my $aud = $c->param('aud') // q();
    xrpc_error(400, 'InvalidRequest', 'aud is required') unless length $aud;
    my $lxm = $c->param('lxm') // q();
    my $normalized_lxm = _normalize_lxm($lxm);
    xrpc_error(400, 'InvalidRequest', 'Protected methods cannot be service-authenticated')
      if length($normalized_lxm) && $PROTECTED_SERVICE_AUTH_METHOD{$normalized_lxm};
    my $scope = _canonical_access_scope($claims->{scope} // $session->{scope});
    if (length($normalized_lxm) && _service_auth_method_requires_privileged_access($normalized_lxm) && !_scope_allows($scope, 'privileged')) {
      xrpc_error(400, 'InvalidToken', 'Bad token scope');
    }
    my $requested_exp = $c->param('exp');
    my $now = time;
    my $exp = defined($requested_exp) ? int($requested_exp) : ($now + 60);
    xrpc_error(400, 'BadExpiration', 'Requested expiration is out of bounds')
      if $exp <= $now || $exp > ($now + 3600);
    xrpc_error(400, 'BadExpiration', 'Requested expiration is out of bounds')
      if !length($normalized_lxm) && $exp > ($now + 60);
    xrpc_error(500, 'SigningKeyUnavailable', 'Account signing key is unavailable')
      unless defined($account->{private_key}) && length($account->{private_key});
    my $token = encode_service_jwt({
      iss => $account->{did},
      iat => $now,
      aud => $aud,
      exp => $exp,
      (length($lxm) ? (lxm => $lxm) : ()),
    }, $account->{private_key});
    return { token => $token };
  });

  $registry->register('com.atproto.server.reserveSigningKey', sub ($c, $endpoint) {
    my $body = $c->req->json || {};
    my $keys = $c->repo_manager->generate_signing_key;
    if ($body->{did}) {
      $c->store->reserve_signing_key(
        did                  => $body->{did},
        private_key          => $keys->{private_key},
        public_key           => $keys->{public_key},
        public_key_multibase => $keys->{public_key_multibase},
        signing_key_did      => $keys->{signing_key_did},
      );
    }
    return {
      signingKey => $keys->{signing_key_did},
    };
  });

  $registry->register('com.atproto.server.createInviteCode', sub ($c, $endpoint) {
    my $body = $c->req->json || {};
    my ($created_by, $target) = _invite_code_targets($c, $body);
    my $code = _new_invite_code();
    $c->store->create_invite_code(
      code        => $code,
      for_account => $target,
      created_by  => $created_by,
      use_count   => $body->{useCount} // 1,
    );
    return { code => $code };
  });

  $registry->register('com.atproto.server.createInviteCodes', sub ($c, $endpoint) {
    my $body = $c->req->json || {};
    my ($created_by, $accounts) = _invite_code_targets($c, $body, multiple => 1);
    my $count = $body->{codeCount} // 1;
    my @result;
    for my $target (@$accounts) {
      my @codes;
      for (1 .. $count) {
        my $code = _new_invite_code();
        $c->store->create_invite_code(
          code        => $code,
          for_account => $target,
          created_by  => $created_by,
          use_count   => $body->{useCount} // 1,
        );
        push @codes, $code;
      }
      push @result, {
        account => $target,
        codes   => \@codes,
      };
    }
    return { codes => \@result };
  });

  $registry->register('com.atproto.server.getAccountInviteCodes', sub ($c, $endpoint) {
    my (undef, $account) = require_auth($c, audience => TOKEN_AUD_ACCESS, required_scope => 'full');
    my $rows = $c->store->list_invite_codes_for_account($account->{did});
    return {
      codes => [ map { invite_code_view($c->store, $_) } @$rows ],
    };
  });
}

sub session_view ($account) {
  return {
    handle          => $account->{handle},
    did             => $account->{did},
    didDoc          => $account->{did_doc} || account_did_doc({}, $account),
    email           => $account->{email},
    emailConfirmed  => defined($account->{email_confirmed_at}) ? JSON::PP::true : JSON::PP::false,
    emailAuthFactor => JSON::PP::false,
    active          => (!defined($account->{deactivated_at}) && !defined($account->{deleted_at}))
      ? JSON::PP::true
      : JSON::PP::false,
    (defined($account->{deleted_at}) ? (status => 'deleted') : ()),
    (defined($account->{deactivated_at}) && !defined($account->{deleted_at}) ? (status => 'deactivated') : ()),
  };
}

sub require_auth ($c, %opts) {
  my $auth = $c->req->headers->authorization // q();
  xrpc_error(401, 'AuthRequired', 'Authorization header is required')
    unless $auth =~ /\ABearer\s+(.+)\z/i;
  my $token = $1;

  my $decoded = eval { decode_jwt($token, $c->config_value('jwt_secret', 'perlsky-dev-secret')) };
  if (my $err = $@) {
    my $message = "$err";
    my $code = $message =~ /expired/i ? 'ExpiredToken' : 'InvalidToken';
    xrpc_error(401, $code, $message);
  }

  my $claims = $decoded->{claims};
  my $aud = $claims->{aud} // q();
  my $ok = $aud eq ($opts{audience} // TOKEN_AUD_ACCESS)
    || ($opts{allow_refresh} && $aud eq TOKEN_AUD_REFRESH);
  xrpc_error(401, 'InvalidToken', 'Unexpected token audience') unless $ok;

  my $session_id = $claims->{jti} // q();
  xrpc_error(401, 'InvalidToken', 'Token is missing a session identifier') unless length $session_id;
  my $session = $c->store->get_session($session_id);
  xrpc_error(401, 'InvalidToken', 'Token session was not found') unless $session;
  xrpc_error(401, 'ExpiredToken', 'Token session has already been revoked')
    if defined $session->{revoked_at};
  xrpc_error(401, 'ExpiredToken', 'Token session has expired')
    if defined($session->{expires_at}) && $session->{expires_at} < time;
  xrpc_error(401, 'InvalidToken', 'Token session did not match token subject')
    unless ($session->{did} // q()) eq ($claims->{sub} // q());
  if ($aud eq TOKEN_AUD_ACCESS) {
    my $token_scope = _canonical_access_scope($claims->{scope});
    my $session_scope = _canonical_access_scope($session->{scope});
    xrpc_error(401, 'InvalidToken', 'Token session scope did not match token scope')
      unless $token_scope eq $session_scope;
    if ($opts{required_scope} && !_scope_allows($token_scope, $opts{required_scope})) {
      xrpc_error(400, 'InvalidToken', 'Bad token scope');
    }
  }

  my $account = $c->store->get_account_by_did($claims->{sub});
  xrpc_error(401, 'InvalidToken', 'Token subject no longer exists') unless $account;
  xrpc_error(401, 'InvalidToken', 'Token subject has been deleted') if defined $account->{deleted_at};
  return ($claims, $account, $session);
}

sub _issue_session ($c, $account, %opts) {
  my $session = $c->store->create_session(
    did        => $account->{did},
    kind       => ($opts{kind} // q()) eq 'app_password' ? 'app_password' : 'account',
    scope      => _canonical_access_scope($opts{scope}),
    token      => $opts{session_token},
    expires_at => time + (30 * 24 * 60 * 60),
  );

  return _session_response($c, $account, $session);
}

sub _session_response ($c, $account, $session) {
  my $issuer = service_did($c->app->settings);
  my $secret = $c->config_value('jwt_secret', 'perlsky-dev-secret');
  my $now    = time;
  my $scope  = _canonical_access_scope($session->{scope});
  my $refresh_exp = $session->{expires_at} // ($now + (30 * 24 * 60 * 60));

  my $access = encode_jwt({
    iss => $issuer,
    sub => $account->{did},
    aud => TOKEN_AUD_ACCESS,
    scope => $scope,
    typ => TOKEN_AUD_ACCESS,
    jti => $session->{id},
    exp => $now + 3600,
  }, $secret);

  my $refresh = encode_jwt({
    iss => $issuer,
    sub => $account->{did},
    aud => TOKEN_AUD_REFRESH,
    typ => TOKEN_AUD_REFRESH,
    jti => $session->{id},
    exp => $refresh_exp,
  }, $secret);

  return {
    accessJwt  => $access,
    refreshJwt => $refresh,
    %{ session_view($account) },
  };
}

sub _canonical_access_scope ($scope = undef) {
  return TOKEN_AUD_ACCESS unless defined $scope && length $scope;
  return TOKEN_AUD_ACCESS if $scope eq 'atproto';
  return $scope;
}

sub _normalize_lxm ($lxm = q()) {
  return lc($lxm // q());
}

sub _scope_allows ($scope, $required_scope) {
  $scope = _canonical_access_scope($scope);
  return 1 if !defined($required_scope) || !length($required_scope);
  return $scope eq TOKEN_AUD_ACCESS
    if $required_scope eq 'full';
  return $scope eq TOKEN_AUD_ACCESS || $scope eq 'app_password_privileged'
    if $required_scope eq 'privileged';
  return $scope eq TOKEN_AUD_ACCESS || $scope eq 'app_password' || $scope eq 'app_password_privileged'
    if $required_scope eq 'standard';
  return 0;
}

sub _service_auth_method_requires_privileged_access ($lxm) {
  return 0 unless defined $lxm && length $lxm;
  return 1 if $lxm =~ /\Achat\.bsky\./;
  return 1 if $lxm eq 'com.atproto.server.createaccount';
  return 0;
}

sub _invite_code_targets ($c, $body, %opts) {
  if (_uses_admin_authorization($c) || !$c->config_value('self_service_invite_codes', 0)) {
    require_admin($c);
    if ($opts{multiple}) {
      my @targets = @{ $body->{forAccounts} || ['admin'] };
      @targets = ('admin') unless @targets;
      return ('admin', \@targets);
    }
    my $target = $body->{forAccount};
    $target = 'admin' unless defined($target) && length($target);
    return ('admin', $target);
  }

  my (undef, $account) = require_auth($c, audience => TOKEN_AUD_ACCESS, required_scope => 'full');
  if ($opts{multiple}) {
    my @targets = @{ $body->{forAccounts} || [ $account->{did} ] };
    @targets = ($account->{did}) unless @targets;
    xrpc_error(400, 'InvalidRequest', 'Self-service invite creation can only target the authenticated account')
      if grep { !defined($_) || !length($_) || $_ ne $account->{did} } @targets;
    return ($account->{did}, \@targets);
  }

  my $target = $body->{forAccount};
  $target = $account->{did} unless defined($target) && length($target);
  xrpc_error(400, 'InvalidRequest', 'Self-service invite creation can only target the authenticated account')
    unless $target eq $account->{did};
  return ($account->{did}, $target);
}

sub _uses_admin_authorization ($c) {
  my $auth = $c->req->headers->authorization // q();
  return 1 if $auth =~ /\ABasic\s+/i;
  return 0 unless $c->config_value('legacy_admin_bearer_auth', 0);
  return 0 unless $auth =~ /\ABearer\s+(\S+)\z/i;
  my $token = $1;
  return $token !~ /\A[^.]+\.[^.]+\.[^.]+\z/;
}

sub _initial_email_confirmed_at ($c, $email) {
  return undef unless defined $email && length $email;
  return undef unless $c->config_value('testing_auto_confirm_email', 1);
  return time;
}

sub _require_action_token ($c, %args) {
  xrpc_error(400, 'InvalidToken', 'Token is required')
    unless defined($args{token}) && length($args{token});
  my $token = $c->store->get_action_token($args{token});
  xrpc_error(400, 'InvalidToken', 'Token was not found') unless $token;
  xrpc_error(400, 'InvalidToken', 'Token purpose did not match')
    unless ($token->{purpose} // q()) eq ($args{purpose} // q());
  xrpc_error(400, 'InvalidToken', 'Token has already been used') if defined $token->{consumed_at};
  xrpc_error(400, 'ExpiredToken', 'Token has expired')
    if defined($token->{expires_at}) && $token->{expires_at} < time;
  return $token;
}

sub _new_app_password {
  return join('-', map { substr(random_hex(4), 0, 4) } 1 .. 4);
}

sub _new_invite_code {
  return 'perlsky-' . substr(random_hex(8), 0, 12);
}

1;
