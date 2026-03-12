package ATProto::PDS::API::Server;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Crypt::PK::ECC;
use Exporter 'import';
use JSON::PP ();
use Mojo::URL;
use Mojo::UserAgent;

use ATProto::PDS::API::Helpers qw(find_account invite_code_view issue_account_action_token require_admin supported_email update_account_email verify_account_password verify_login_password);
use ATProto::PDS::API::Util qw(iso8601 xrpc_error);
use ATProto::PDS::Auth::OAuth qw(
  oauth_scope_allows
  oauth_scope_allows_permission
  oauth_scope_has_atproto
);
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
use ATProto::PDS::Identity qw(account_did account_did_doc account_did_doc_valid_for_service did_to_path normalize_handle service_did);
use ATProto::PDS::Moderation qw(assert_login_allowed is_repo_takedown);
use ATProto::PDS::PLC qw(account_did_method create_plc_account is_plc_did refresh_plc_did_doc);
use ATProto::PDS::Repo::CAR qw(read_car);
use ATProto::PDS::Util::BaseX qw(base64url_decode decode_base58btc);

our @EXPORT_OK = qw(register_server_handlers require_auth require_access_or_service_auth session_view);

my $OLD_PASSWORD_MAX_LENGTH = 512;
my $NEW_PASSWORD_MAX_LENGTH = 256;

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
    xrpc_error(400, 'InvalidRequest', "Handle already taken: $handle")
      if $c->store->get_account_by_handle($handle);
    xrpc_error(400, 'HandleNotAvailable', 'That handle is reserved')
      if $c->store->get_reserved_handle($handle);

    my $password = $body->{password} // q();
    xrpc_error(400, 'InvalidPassword', 'Passwords must be at least 8 characters long')
      if length($password) < 8;
    xrpc_error(400, 'InvalidRequest', "Password too long. Maximum length is $NEW_PASSWORD_MAX_LENGTH characters.")
      if length($password) > $NEW_PASSWORD_MAX_LENGTH;
    my $email = undef;
    if (defined($body->{email}) && length($body->{email})) {
      $email = supported_email($body->{email});
      xrpc_error(400, 'InvalidRequest', 'This email address is not supported, please use a different email.')
        unless defined $email;
      xrpc_error(400, 'InvalidRequest', "Email already taken: $body->{email}")
        if $c->store->get_account_by_email($email);
    }

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
    my $migration  = defined($did) && length($did);
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
    my $deactivated_at;
    if ($migration) {
      _assert_create_account_requester($c, $did, $endpoint->{id});
      $did_doc = _resolve_migration_did_doc($c, $did) // { id => $did };
      $deactivated_at = time;
    }
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

    my $account = eval {
      $c->store->create_account(
        account_id            => $account_id,
        did                   => $did,
        handle                => $handle,
        email                 => $email,
        email_confirmed_at    => _initial_email_confirmed_at($c, $email),
        password_hash         => $password_record->{hash},
        password_salt         => $password_record->{salt},
        deactivated_at        => $deactivated_at,
        did_doc               => $did_doc,
        private_key           => $keys->{private_key},
        public_key            => $keys->{public_key},
        public_key_multibase  => $keys->{public_key_multibase},
        signing_key_did       => $keys->{signing_key_did},
      );
    };
    if (!$account) {
      my $err = $@;
      xrpc_error(400, 'InvalidRequest', "Email already taken: $body->{email}")
        if !ref($err) && defined($email) && ($err // q()) =~ /UNIQUE constraint failed: accounts\.email/;
      die $err;
    }

    my $repo = $c->repo_manager->initialize_repo($account);
    $account = $c->store->update_account($account->{did},
      repo_commit_cid => $repo->{cid},
      repo_root_cid   => $repo->{root_cid},
      repo_rev        => $repo->{rev},
      did_doc         => $migration
        ? ($account->{did_doc} || $did_doc || { id => $account->{did} })
        : is_plc_did($account->{did})
          ? refresh_plc_did_doc($c->app->settings, $account->{did})
          : account_did_doc($c->app->settings, $account),
    );

    $c->store->record_invite_code_use(
      code    => $invite->{code},
      used_by => $account->{did},
    ) if $invite;
    $c->store->claim_reserved_signing_key($did) if $reserved && !defined $reserved->{claimed_at};
    unless (defined $account->{deactivated_at}) {
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
    }

    return _issue_session($c, $account);
  });

  $registry->register('com.atproto.server.createSession', sub ($c, $endpoint) {
    my $body = $c->req->json || {};
    xrpc_error(401, 'AuthenticationRequired', 'Password too long. Consider resetting your password.')
      if length($body->{password} // q()) > $OLD_PASSWORD_MAX_LENGTH;
    my $account = find_account($c, $body->{identifier} // q());
    xrpc_error(401, 'AuthenticationRequired', 'Invalid identifier or password') unless $account;
    xrpc_error(401, 'AuthenticationRequired', 'Invalid identifier or password')
      if defined $account->{deleted_at};
    my $authn = verify_login_password($c, $account, $body->{password} // q());
    xrpc_error(401, 'AuthenticationRequired', 'Invalid identifier or password') unless $authn;
    if (($authn->{kind} // q()) eq 'app_password' && is_repo_takedown($c, $account->{did})) {
      xrpc_error(401, 'AuthenticationRequired', 'Invalid identifier or password');
    }
    assert_login_allowed(
      $c,
      $account,
      allow_takedown    => $body->{allowTakendown},
      allow_deactivated => 1,
    );
    return _issue_session($c, $account,
      kind          => $authn->{kind},
      scope         => $authn->{scope},
      session_token => $authn->{app_password_name},
    );
  });

  $registry->register('com.atproto.server.getSession', sub ($c, $endpoint) {
    my ($claims, $account) = require_auth($c, audience => TOKEN_AUD_ACCESS);
    my %opts;
    if (($claims->{typ} // q()) eq 'oauth_access') {
      $opts{include_email} = oauth_scope_allows_permission(
        $claims->{scope},
        type   => 'account',
        attr   => 'email',
        action => 'read',
      ) ? 1 : 0;
    }
    return session_view($account, %opts);
  });

  $registry->register('com.atproto.server.refreshSession', sub ($c, $endpoint) {
    my (undef, $account, $session);
    my $ok = eval {
      (undef, $account, $session) = require_auth($c, audience => TOKEN_AUD_REFRESH);
      1;
    };
    if (!$ok) {
      my $err = $@;
      if (ref($err) eq 'HASH' && ($err->{error} // q()) eq 'ExpiredToken') {
        xrpc_error(400, 'ExpiredToken', $err->{message});
      }
      die $err;
    }
    assert_login_allowed($c, $account, allow_deactivated => 1);
    my $rotated = $c->store->rotate_session($session->{id});
    xrpc_error(400, 'ExpiredToken', 'Refresh session has already been revoked') unless $rotated;
    return _session_response($c, $account, $rotated);
  });

  $registry->register('com.atproto.server.deleteSession', sub ($c, $endpoint) {
    my ($claims) = require_auth($c, audience => TOKEN_AUD_REFRESH, allow_refresh => 1);
    my $session = $c->store->get_session($claims->{jti});
    $c->store->revoke_session($session->{id}) if $session;
    return _render_empty_success($c);
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
      validDid           => account_did_doc_valid_for_service($c->app->settings, $account)
        ? JSON::PP::true
        : JSON::PP::false,
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
    my (undef, $account) = require_auth(
      $c,
      audience       => TOKEN_AUD_ACCESS,
      required_scope => 'full',
      disallow_oauth => 1,
    );
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
    my (undef, $account) = require_auth(
      $c,
      audience       => TOKEN_AUD_ACCESS,
      required_scope => 'standard',
      disallow_oauth => 1,
    );
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
    my (undef, $account) = require_auth(
      $c,
      audience       => TOKEN_AUD_ACCESS,
      required_scope => 'full',
      disallow_oauth => 1,
    );
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
    return _render_empty_success($c);
  });

  $registry->register('com.atproto.server.deactivateAccount', sub ($c, $endpoint) {
    my (undef, $account) = require_auth(
      $c,
      audience       => TOKEN_AUD_ACCESS,
      required_scope => 'full',
      disallow_oauth => 1,
    );
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
    return _render_empty_success($c);
  });

  $registry->register('com.atproto.server.activateAccount', sub ($c, $endpoint) {
    my (undef, $account) = require_auth(
      $c,
      audience       => TOKEN_AUD_ACCESS,
      required_scope => 'full',
      disallow_oauth => 1,
    );
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
    return _render_empty_success($c);
  });

  $registry->register('com.atproto.server.requestPasswordReset', sub ($c, $endpoint) {
    my $body = $c->req->json || {};
    my $account = $c->store->get_account_by_email($body->{email} // q());
    xrpc_error(400, 'InvalidRequest', 'account does not have an email address')
      unless $account && !defined($account->{deleted_at}) && defined($account->{email}) && length($account->{email});
    issue_account_action_token(
      $c,
      $account,
      purpose => ACTION_TOKEN_PASSWORD_RESET,
      subject => 'perlsky password reset',
      content => sub ($token) { "Use token $token->{token} to reset your password." },
    );
    return _render_empty_success($c);
  });

  $registry->register('com.atproto.server.resetPassword', sub ($c, $endpoint) {
    my $body = $c->req->json || {};
    xrpc_error(400, 'InvalidPassword', 'Passwords must be at least 8 characters long')
      if length($body->{password} // q()) < 8;
    xrpc_error(400, 'InvalidRequest', 'Invalid password length.')
      if length($body->{password} // q()) > $NEW_PASSWORD_MAX_LENGTH;
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
    return _render_empty_success($c);
  });

  $registry->register('com.atproto.server.requestEmailConfirmation', sub ($c, $endpoint) {
    my ($claims, $account) = require_auth(
      $c,
      audience           => TOKEN_AUD_ACCESS,
      required_permission => {
        type   => 'account',
        attr   => 'email',
        action => 'manage',
      },
    );
    _assert_full_non_oauth_access($claims);
    xrpc_error(400, 'InvalidRequest', 'account does not have an email address')
      unless defined($account->{email}) && length($account->{email});
    issue_account_action_token(
      $c,
      $account,
      purpose => ACTION_TOKEN_EMAIL_CONFIRM,
      subject => 'perlsky email confirmation',
      content => sub ($token) { "Use token $token->{token} to confirm your email address." },
    );
    return _render_empty_success($c);
  });

  $registry->register('com.atproto.server.confirmEmail', sub ($c, $endpoint) {
    if (!$c->config_value('testing_allow_unauthenticated_email_confirm', 0)) {
      my ($claims) = require_auth(
        $c,
        audience            => TOKEN_AUD_ACCESS,
        required_permission => {
          type   => 'account',
          attr   => 'email',
          action => 'manage',
        },
      );
      _assert_full_non_oauth_access($claims);
    }
    my $body = $c->req->json || {};
    my $token = _require_action_token($c,
      token   => $body->{token},
      purpose => ACTION_TOKEN_EMAIL_CONFIRM,
    );
    my $account = $c->store->get_account_by_did($token->{did});
    xrpc_error(404, 'AccountNotFound', 'Account was not found') unless $account;
    my $email = _normalize_email($body->{email}) // q();
    xrpc_error(400, 'InvalidEmail', 'invalid email')
      unless length($email)
      && ($token->{email} // q()) eq $email
      && ($account->{email} // q()) eq $email;
    $c->store->txn(sub ($dbh) {
      $c->store->update_account($account->{did}, email_confirmed_at => time);
      $c->store->consume_action_token($token->{token});
    });
    return _render_empty_success($c);
  });

  $registry->register('com.atproto.server.requestEmailUpdate', sub ($c, $endpoint) {
    my ($claims, $account) = require_auth(
      $c,
      audience            => TOKEN_AUD_ACCESS,
      required_permission => {
        type   => 'account',
        attr   => 'email',
        action => 'manage',
      },
    );
    _assert_full_non_oauth_access($claims);
    xrpc_error(400, 'InvalidRequest', 'account does not have an email address')
      unless defined($account->{email}) && length($account->{email});
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
    my (undef, $account) = require_auth(
      $c,
      audience       => TOKEN_AUD_ACCESS,
      required_scope => 'full',
      disallow_oauth => 1,
    );
    my $body = $c->req->json || {};
    my $email = supported_email($body->{email});
    xrpc_error(400, 'InvalidRequest', 'This email address is not supported, please use a different email.')
      unless defined $email;
    if (defined $account->{email_confirmed_at}) {
      xrpc_error(400, 'TokenRequired', 'confirmation token required')
        unless defined($body->{token}) && length($body->{token});
      my $token = _require_action_token($c,
        token   => $body->{token},
        purpose => ACTION_TOKEN_EMAIL_UPDATE,
      );
      xrpc_error(400, 'InvalidToken', 'Token was not issued for this account')
        unless ($token->{did} // q()) eq $account->{did};
      $c->store->consume_action_token($token->{token});
    }
    update_account_email($c, $account->{did}, $email);
    return _render_empty_success($c);
  });

  $registry->register('com.atproto.server.requestAccountDelete', sub ($c, $endpoint) {
    my (undef, $account) = require_auth(
      $c,
      audience       => TOKEN_AUD_ACCESS,
      required_scope => 'full',
      disallow_oauth => 1,
    );
    xrpc_error(400, 'InvalidRequest', 'account does not have an email address')
      unless defined($account->{email}) && length($account->{email});
    issue_account_action_token(
      $c,
      $account,
      purpose => ACTION_TOKEN_ACCOUNT_DELETE,
      subject => 'perlsky account deletion',
      content => sub ($token) { "Use token $token->{token} to delete your account." },
    );
    return _render_empty_success($c);
  });

  $registry->register('com.atproto.server.deleteAccount', sub ($c, $endpoint) {
    my $body = $c->req->json || {};
    my $did = $body->{did} // q();
    my $account = $c->store->get_account_by_did($did);
    xrpc_error(400, 'InvalidRequest', 'account not found')
      unless $account && !defined($account->{deleted_at});
    xrpc_error(400, 'InvalidRequest', 'Invalid password length.')
      if length($body->{password} // q()) > $OLD_PASSWORD_MAX_LENGTH;
    xrpc_error(401, 'AuthRequired', 'Invalid did or password')
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
    return _render_empty_success($c);
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
    if (($claims->{typ} // q()) eq 'oauth_access') {
      my $rpc_lxm = length($normalized_lxm) ? $lxm : '*';
      xrpc_error(403, 'Forbidden', qq{Missing required scope "} . 'rpc:' . $rpc_lxm . '?aud=' . $aud . q{"})
        unless oauth_scope_allows_permission(
          $scope,
          type => 'rpc',
          aud  => $aud,
          lxm  => $rpc_lxm,
        );
    } elsif (length($normalized_lxm) && _service_auth_method_requires_privileged_access($normalized_lxm) && !_scope_allows($scope, 'privileged')) {
      xrpc_error(400, 'InvalidRequest', 'Bad token scope');
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
    my (undef, $account) = require_auth(
      $c,
      audience       => TOKEN_AUD_ACCESS,
      required_scope => 'full',
      disallow_oauth => 1,
    );
    my $rows = $c->store->list_invite_codes_for_account($account->{did});
    return {
      codes => [ map { invite_code_view($c->store, $_) } @$rows ],
    };
  });
}

sub session_view ($account, %opts) {
  my $include_email = exists $opts{include_email} ? $opts{include_email} : 1;
  return {
    handle          => $account->{handle},
    did             => $account->{did},
    didDoc          => $account->{did_doc} || account_did_doc({}, $account),
    ($include_email ? (
      email           => $account->{email},
      emailConfirmed  => defined($account->{email_confirmed_at}) ? JSON::PP::true : JSON::PP::false,
      emailAuthFactor => JSON::PP::false,
    ) : ()),
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
    unless $auth =~ /\A(Bearer|DPoP)\s+(.+)\z/i;
  my ($scheme, $token) = (lc($1), $2);

  if ($scheme eq 'dpop') {
    xrpc_error(401, 'InvalidToken', 'DPoP tokens cannot be used as refresh tokens')
      if (($opts{audience} // TOKEN_AUD_ACCESS) eq TOKEN_AUD_REFRESH) || $opts{allow_refresh};
    return $c->oauth_provider->authenticate_oauth_access_token($c, $token, %opts);
  }

  my $decoded = eval { decode_jwt($token, _jwt_secret($c)) };
  if (my $err = $@) {
    my $message = "$err";
    my ($code, $safe_message) = _jwt_decode_error($message);
    xrpc_error(401, $code, $safe_message);
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

sub require_access_or_service_auth ($c, %opts) {
  my $auth = $c->req->headers->authorization // q();
  if ($auth =~ /\ABearer\s+(.+)\z/i) {
    my $token = $1;
    if (my $claims = _parse_service_auth_claims($token)) {
      my $lxm = $opts{lxm} // q();
      xrpc_error(401, 'InvalidToken', 'Unexpected token audience')
        if ($opts{audience} // TOKEN_AUD_ACCESS) eq TOKEN_AUD_REFRESH;
      my $account = _verify_user_service_auth($c, $token, $claims, $lxm);
      return ($claims, $account, undef);
    }
  }
  return require_auth($c, %opts);
}

sub _jwt_decode_error ($message) {
  return ('ExpiredToken', 'Token has expired')
    if $message =~ /expired/i;
  return ('InvalidToken', 'Token is not yet valid')
    if $message =~ /not yet valid/i;
  return ('InvalidToken', 'Token has an unexpected audience')
    if $message =~ /unexpected audience/i;
  return ('InvalidToken', 'Token has an invalid signature')
    if $message =~ /invalid signature/i;
  return ('InvalidToken', 'Token is malformed')
    if $message =~ /three sections/i;
  return ('InvalidToken', 'Token is invalid');
}

sub _assert_create_account_requester ($c, $did, $lxm) {
  my $message = "Missing auth to create account with did: $did";
  my $requester = eval {
    my (undef, $account) = require_auth($c, audience => TOKEN_AUD_ACCESS, required_scope => 'full');
    return $account->{did};
  };
  return 1 if defined($requester) && _same_did($requester, $did);

  $requester = _verify_migration_service_auth($c, $did, $lxm);
  xrpc_error(401, 'AuthRequired', $message)
    unless defined($requester) && _same_did($requester, $did);
  return 1;
}

sub _verify_migration_service_auth ($c, $did, $lxm) {
  my $auth = $c->req->headers->authorization // q();
  return undef unless $auth =~ /\ABearer\s+(.+)\z/i;
  my $token = $1;

  my $claims = _parse_service_auth_claims($token) or return undef;
  return undef unless _same_did(($claims->{iss} // q()), $did);
  return undef unless _audience_matches_service($c, $claims->{aud});
  return undef unless lc($claims->{lxm} // q()) eq lc($lxm // q());
  return undef unless _verify_service_auth_signature($c, $token, $claims->{iss});

  return $claims->{iss};
}

sub _verify_user_service_auth ($c, $token, $claims, $lxm) {
  xrpc_error(401, 'InvalidToken', 'Token subject is invalid')
    unless defined($claims->{iss}) && ($claims->{iss} // q()) =~ /\Adid:/;
  xrpc_error(401, 'InvalidToken', 'Unexpected token audience')
    unless _audience_matches_service($c, $claims->{aud});
  xrpc_error(401, 'InvalidToken', 'Token method did not match request')
    unless lc($claims->{lxm} // q()) eq lc($lxm // q());
  xrpc_error(401, 'InvalidToken', 'Token signature is invalid')
    unless _verify_service_auth_signature($c, $token, $claims->{iss});

  my $account = $c->store->get_account_by_did($claims->{iss});
  xrpc_error(401, 'InvalidToken', 'Token subject no longer exists') unless $account;
  xrpc_error(401, 'InvalidToken', 'Token subject has been deleted') if defined $account->{deleted_at};
  return $account;
}

sub _parse_service_auth_claims ($token) {
  my ($header_b64, $claims_b64, $sig_b64) = split /\./, ($token // q()), 3;
  return undef unless defined $sig_b64;

  my $header = eval { JSON::PP::decode_json(base64url_decode($header_b64)) };
  return undef if $@ || ref($header) ne 'HASH';
  return undef unless ($header->{alg} // q()) eq 'ES256K';

  my $claims = eval { JSON::PP::decode_json(base64url_decode($claims_b64)) };
  return undef if $@ || ref($claims) ne 'HASH';

  my $now = time;
  return undef if defined($claims->{nbf}) && $claims->{nbf} > $now;
  return undef if defined($claims->{iat}) && $claims->{iat} > ($now + 60);
  return undef if defined($claims->{exp}) && $claims->{exp} <= $now;
  return $claims;
}

sub _verify_service_auth_signature ($c, $token, $did) {
  my ($header_b64, $claims_b64, $sig_b64) = split /\./, ($token // q()), 3;
  return 0 unless defined $sig_b64;
  my $did_doc = _resolve_migration_did_doc($c, $did) or return 0;
  my $public_key = _did_doc_atproto_public_key($did_doc) or return 0;

  my $pk = eval {
    my $ecc = Crypt::PK::ECC->new;
    $ecc->import_key_raw($public_key, 'secp256k1');
    $ecc;
  };
  return 0 if $@ || !$pk;

  my $verified = eval {
    $pk->verify_message_rfc7518(base64url_decode($sig_b64), "$header_b64.$claims_b64", 'SHA256');
  };
  return $@ || !$verified ? 0 : 1;
}

sub _audience_matches_service ($c, $aud) {
  my %acceptable = map {
    my $value = $_ // q();
    my $decoded = $value;
    $decoded =~ s/%3a/:/ig;
    ($value => 1, $decoded => 1);
  } grep { defined && length } (
    service_did($c->app->settings),
    $c->config_value('base_url'),
  );
  if (ref($aud) eq 'ARRAY') {
    return scalar grep { $acceptable{$_ // q()} } @$aud;
  }
  return $acceptable{$aud // q()} ? 1 : 0;
}

sub _resolve_migration_did_doc ($c, $did) {
  my $service_did = service_did($c->app->settings);
  return {
    id => $service_did,
  } if _same_did($did, $service_did);

  my $account = $c->store->get_account_by_did($did);
  return $account->{did_doc} || account_did_doc($c->app->settings, $account)
    if $account;

  if (is_plc_did($did)) {
    my $did_doc = eval { refresh_plc_did_doc($c->app->settings, $did) };
    return $did_doc unless $@;
    return undef;
  }

  return undef unless $did =~ /\Adid:web:/i;
  my ($host, $path) = _web_did_origin_and_path($did);
  return undef unless defined $host && defined $path;

  state %ua_for_origin;
  my $origin = lc($host);
  my $ua = $ua_for_origin{$origin} //= do {
    my $client = Mojo::UserAgent->new(max_redirects => 0);
    $client->request_timeout(15);
    $client->inactivity_timeout(15);
    $client;
  };

  my $scheme = $host =~ /\A(?:localhost|127\.0\.0\.1|\[::1\])(?::\d+)?\z/i ? 'http' : 'https';
  my $url = Mojo::URL->new("$scheme://$host");
  $url->path($path);

  my $tx = eval { $ua->get($url) };
  return undef if $@ || !$tx;
  my $res = eval { $tx->result };
  return undef if $@ || !$res || ($res->code // 0) != 200;
  my $json = $res->json;
  return undef unless ref($json) eq 'HASH' && _same_did(($json->{id} // q()), $did);
  return $json;
}

sub _did_doc_atproto_public_key ($did_doc) {
  return undef unless ref($did_doc) eq 'HASH';
  my $did = $did_doc->{id} // q();
  my ($verification_method) = grep {
    ref($_) eq 'HASH'
      && length($_->{publicKeyMultibase} // q())
      && (
        (($_->{id} // q()) eq "$did#atproto")
        || (($_->{id} // q()) eq '#atproto')
      )
  } @{ $did_doc->{verificationMethod} || [] };
  $verification_method //= (grep {
    ref($_) eq 'HASH' && length($_->{publicKeyMultibase} // q())
  } @{ $did_doc->{verificationMethod} || [] })[0];
  return undef unless $verification_method;

  my $multibase = $verification_method->{publicKeyMultibase} // q();
  return undef unless $multibase =~ /\Az(.+)\z/;
  return decode_base58btc($1);
}

sub _web_did_origin_and_path ($did) {
  return unless defined $did;
  my $copy = $did;
  return unless $copy =~ s/\Adid:web://i;

  my @parts = split /:/, $copy;
  return unless @parts;
  my $host = shift @parts;
  $host =~ s/%3a/:/ig;
  if (@parts && $parts[0] =~ /\A\d+\z/ && $host !~ /:/) {
    $host .= ':' . shift @parts;
  }
  my $path = @parts ? '/' . join('/', map { s/%3A/:/igr } @parts) . '/did.json' : did_to_path($did);
  return ($host, $path);
}

sub _same_did ($left, $right) {
  return 0 unless defined($left) && defined($right);
  return lc($left) eq lc($right) ? 1 : 0;
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
  my $secret = _jwt_secret($c);
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
  return 'com.atproto.appPass' if $scope eq 'app_password';
  return 'com.atproto.appPassPrivileged' if $scope eq 'app_password_privileged';
  return $scope;
}

sub _jwt_secret ($c) {
  my $secret = $c->config_value('jwt_secret');
  xrpc_error(500, 'ServerMisconfigured', 'jwt_secret is not configured')
    unless defined $secret && length $secret;
  xrpc_error(500, 'ServerMisconfigured', 'jwt_secret is using the legacy dev default')
    if $secret eq 'perlsky-dev-secret';
  return $secret;
}

sub _normalize_lxm ($lxm = q()) {
  return lc($lxm // q());
}

sub _scope_allows ($scope, $required_scope) {
  $scope = _canonical_access_scope($scope);
  return oauth_scope_allows($scope, $required_scope) if oauth_scope_has_atproto($scope);
  return 1 if !defined($required_scope) || !length($required_scope);
  return $scope eq TOKEN_AUD_ACCESS
    if $required_scope eq 'full';
  return $scope eq TOKEN_AUD_ACCESS || $scope eq 'com.atproto.appPassPrivileged'
    if $required_scope eq 'privileged';
  return $scope eq TOKEN_AUD_ACCESS || $scope eq 'com.atproto.appPass' || $scope eq 'com.atproto.appPassPrivileged'
    if $required_scope eq 'standard';
  return 0;
}

sub _assert_full_non_oauth_access ($claims) {
  return 1 if ($claims->{typ} // q()) eq 'oauth_access';
  xrpc_error(400, 'InvalidToken', 'Bad token scope')
    unless _scope_allows($claims->{scope}, 'full');
  return 1;
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
  xrpc_error(400, 'InvalidRequest', 'Invite creation is disabled for this account')
    if $account->{invites_disabled};
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
  return undef unless $c->config_value('testing_auto_confirm_email', 0);
  return time;
}

sub _normalize_email ($email) {
  return undef unless defined $email;
  return lc $email;
}

sub _require_action_token ($c, %args) {
  xrpc_error(400, 'InvalidToken', 'Token is required')
    unless defined($args{token}) && length($args{token});
  my $token = $c->store->get_action_token($args{token});
  xrpc_error(400, 'InvalidToken', 'Token was not found') unless $token;
  xrpc_error(400, 'InvalidToken', 'Token purpose did not match')
    unless ($token->{purpose} // q()) eq ($args{purpose} // q());
  xrpc_error(400, 'InvalidToken', 'Token has already been used') if defined $token->{consumed_at};
  xrpc_error(400, 'ExpiredToken', 'Token is expired')
    if defined($token->{expires_at}) && $token->{expires_at} < time;
  return $token;
}

sub _new_app_password {
  return join('-', map { substr(random_hex(4), 0, 4) } 1 .. 4);
}

sub _new_invite_code {
  return 'perlsky-' . substr(random_hex(8), 0, 12);
}

sub _render_empty_success ($c) {
  $c->render(data => q());
  return;
}

1;
