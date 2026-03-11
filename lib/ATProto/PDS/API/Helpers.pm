package ATProto::PDS::API::Helpers;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use JSON::PP ();

use ATProto::PDS::API::Util qw(iso8601 xrpc_error);
use ATProto::PDS::Auth::Password qw(verify_password);
use ATProto::PDS::Moderation qw(admin_authorization_status subject_key);

our @EXPORT_OK = qw(
  account_view
  find_account
  issue_account_action_token
  invite_code_view
  require_admin
  subject_key
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
    scope => 'access',
  } if verify_account_password($c, $account, $password);

  for my $app_password (@{ $c->store->list_app_passwords_by_did($account->{did}) }) {
    next if defined $app_password->{revoked_at};
    my ($salt_hex, $hash) = split /:/, ($app_password->{password_hash} // q()), 2;
    next unless defined $salt_hex && defined $hash;
    my $salt = pack('H*', $salt_hex);
    if (verify_password($password, $salt, $hash)) {
      return {
        kind              => 'app_password',
        scope             => $app_password->{privileged} ? 'app_password_privileged' : 'app_password',
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
