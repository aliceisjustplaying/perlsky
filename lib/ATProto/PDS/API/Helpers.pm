package ATProto::PDS::API::Helpers;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use JSON::PP ();

use ATProto::PDS::API::Util qw(iso8601 xrpc_error);
use ATProto::PDS::Auth::Password qw(verify_password);
use ATProto::PDS::Constants qw(
  ACTION_TOKEN_EMAIL_CONFIRM
  ACTION_TOKEN_EMAIL_UPDATE
  TOKEN_AUD_ACCESS
);
use ATProto::PDS::Moderation qw(admin_authorization_status subject_key);

our @EXPORT_OK = qw(
  account_view
  admin_account_view
  find_account
  issue_account_action_token
  invite_code_view
  require_admin
  supported_email
  subject_key
  update_account_email
  verify_account_password
  verify_login_password
);

sub require_admin ($c) {
  my $configured = $c->config_value('admin_password');
  xrpc_error(503, 'AdminAuthUnavailable', 'Admin password is not configured')
    unless defined $configured && length $configured;

  my ($valid, $supplied) = admin_authorization_status($c);
  xrpc_error(401, 'AuthRequired', 'Admin authorization is required')
    unless $supplied;
  xrpc_error(403, 'InvalidAdminToken', 'Invalid admin authorization')
    unless $valid;
  return 1;
}

sub find_account ($c, $identifier) {
  return undef unless defined $identifier && length $identifier;
  my $account = $c->store->get_account_by_identifier($identifier);
  return $account if $account;
  return $c->store->get_account_by_email($identifier);
}

sub verify_account_password ($c, $account, $password) {
  return 0 unless $account && defined $password;
  return verify_password($password, $account->{password_salt}, $account->{password_hash}) ? 1 : 0;
}

sub verify_login_password ($c, $account, $password) {
  return undef unless $account && defined $password;
  return {
    kind  => 'account',
    scope => TOKEN_AUD_ACCESS,
  } if verify_account_password($c, $account, $password);

  for my $app_password (@{ $c->store->list_app_passwords_by_did($account->{did}) }) {
    next if defined $app_password->{revoked_at};
    my ($salt_hex, $hash) = split /:/, ($app_password->{password_hash} // q()), 2;
    next unless defined $salt_hex && defined $hash;
    my $salt = pack('H*', $salt_hex);
    if (verify_password($password, $salt, $hash)) {
      return {
        kind              => 'app_password',
        scope             => $app_password->{privileged} ? 'com.atproto.appPassPrivileged' : 'com.atproto.appPass',
        app_password_name => $app_password->{name},
      };
    }
  }

  return undef;
}

sub issue_account_action_token ($c, $account, %args) {
  return undef unless $account;
  my $token = $c->store->create_action_token(
    did        => $account->{did},
    email      => $account->{email},
    purpose    => $args{purpose},
    expires_at => $args{expires_at} // (time + 3600),
  );
  if (defined($account->{email}) && length($account->{email})) {
    $c->store->log_outbound_email(
      recipient_did   => $account->{did},
      recipient_email => $account->{email},
      subject         => $args{subject},
      content         => ref($args{content}) eq 'CODE'
        ? $args{content}->($token)
        : $args{content},
    );
  }
  return $token;
}

sub supported_email ($email) {
  return undef unless defined $email;
  my $normalized = lc $email;
  return undef unless length $normalized;
  return undef if $normalized =~ /\s/;
  return undef unless $normalized =~ /\A[^\s\@]+\@[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?)+\z/;
  return $normalized;
}

sub update_account_email ($c, $did, $email) {
  eval {
    $c->store->txn(sub ($dbh) {
      $c->store->update_account(
        $did,
        email              => $email,
        email_confirmed_at => undef,
      );
      $c->store->consume_action_tokens_by_did($did,
        purposes    => [ACTION_TOKEN_EMAIL_CONFIRM, ACTION_TOKEN_EMAIL_UPDATE],
        consumed_at => time,
      );
    });
    1;
  } or do {
    my $err = $@;
    xrpc_error(400, 'InvalidRequest', 'This email address is already in use, please use a different email.')
      if !ref($err) && ($err // q()) =~ /UNIQUE constraint failed: accounts\.email/;
    die $err;
  };
  return $c->store->get_account_by_did($did);
}

sub account_view ($account) {
  return {
    did             => $account->{did},
    handle          => $account->{handle},
    ($account->{email} ? (email => $account->{email}) : ()),
    indexedAt       => iso8601($account->{updated_at} // $account->{created_at}),
    invitesDisabled => ($account->{invites_disabled} ? JSON::PP::true : JSON::PP::false),
    (defined($account->{email_confirmed_at}) ? (emailConfirmedAt => iso8601($account->{email_confirmed_at})) : ()),
    ($account->{invite_note} ? (inviteNote => $account->{invite_note}) : ()),
    (defined($account->{deactivated_at}) ? (deactivatedAt => iso8601($account->{deactivated_at})) : ()),
  };
}

sub admin_account_view ($store, $account, %args) {
  my $view = {
    did       => $account->{did},
    handle    => $account->{handle},
    indexedAt => iso8601($account->{created_at}),
    ($account->{email} ? (email => $account->{email}) : ()),
    (defined($account->{email_confirmed_at}) ? (emailConfirmedAt => iso8601($account->{email_confirmed_at})) : ()),
    (defined($account->{deactivated_at}) ? (deactivatedAt => iso8601($account->{deactivated_at})) : ()),
    ($account->{invite_note} ? (inviteNote => $account->{invite_note}) : ()),
  };

  unless ($args{entryway}) {
    my $invited_by = $store->get_invited_by_for_account($account->{did});
    my @invites = @{ $store->list_invite_codes_for_account($account->{did}) || [] };
    $view->{invitesDisabled} = $account->{invites_disabled} ? JSON::PP::true : JSON::PP::false;
    $view->{invitedBy} = invite_code_view($store, $invited_by) if $invited_by;
    $view->{invites} = [ map { invite_code_view($store, $_) } @invites ];
  }

  return $view;
}

sub invite_code_view ($store, $row) {
  my $uses = $store->list_invite_code_uses($row->{code});
  my $consumed = scalar @$uses;
  my $available = ($row->{use_count} // 0) - $consumed;
  $available = 0 if $available < 0;

  return {
    code       => $row->{code},
    available  => $row->{disabled} ? 0 : $available,
    disabled   => $row->{disabled} ? JSON::PP::true : JSON::PP::false,
    forAccount => $row->{for_account} // q(),
    createdBy  => $row->{created_by} // q(),
    createdAt  => iso8601($row->{created_at}),
    uses       => [
      map {
        +{
          usedBy => $_->{used_by},
          usedAt => iso8601($_->{used_at}),
        }
      } @$uses
    ],
  };
}

1;
