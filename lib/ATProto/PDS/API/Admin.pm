package ATProto::PDS::API::Admin;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use JSON::PP ();

use ATProto::PDS::API::Helpers qw(account_view find_account invite_code_view require_admin subject_key);
use ATProto::PDS::API::Util qw(xrpc_error);
use ATProto::PDS::Auth::Password qw(hash_password);
use ATProto::PDS::Identity qw(account_did_doc normalize_handle);

our @EXPORT_OK = qw(register_admin_handlers);

sub register_admin_handlers ($registry, $app) {
  $registry->register('com.atproto.admin.getAccountInfo', sub ($c, $endpoint) {
    require_admin($c);
    my $account = $c->store->get_account_by_did($c->param('did') // q());
    xrpc_error(404, 'AccountNotFound', 'Account was not found') unless $account;
    return account_view($account);
  });

  $registry->register('com.atproto.admin.getAccountInfos', sub ($c, $endpoint) {
    require_admin($c);
    my @dids = $c->every_param('dids');
    return {
      infos => [
        map { account_view($_) }
        grep { defined }
        map { $c->store->get_account_by_did($_) } @dids
      ],
    };
  });

  $registry->register('com.atproto.admin.searchAccounts', sub ($c, $endpoint) {
    require_admin($c);
    my $page = $c->store->search_accounts(
      email  => $c->param('email'),
      cursor => $c->param('cursor'),
      limit  => $c->param('limit') // 50,
    );
    return {
      (defined $page->{cursor} ? (cursor => $page->{cursor}) : ()),
      accounts => [ map { account_view($_) } @{ $page->{items} } ],
    };
  });

  $registry->register('com.atproto.admin.getSubjectStatus', sub ($c, $endpoint) {
    require_admin($c);
    my $subject = _subject_from_params($c);
    my $status = $c->store->get_subject_status(subject_key($subject));
    return {
      subject => $subject,
      ($status && $status->{takedown} ? (takedown => $status->{takedown}) : ()),
      ($status && $status->{deactivated} ? (deactivated => $status->{deactivated}) : ()),
    };
  });

  $registry->register('com.atproto.admin.updateSubjectStatus', sub ($c, $endpoint) {
    require_admin($c);
    my $body = $c->req->json || {};
    my $subject = $body->{subject} || {};
    my $status = $c->store->put_subject_status(
      subject_key  => subject_key($subject),
      subject      => $subject,
      takedown     => $body->{takedown},
      deactivated  => $body->{deactivated},
    );
    if (exists($subject->{did}) && !exists($subject->{uri}) && !exists($subject->{cid}) && $body->{deactivated}) {
      $c->store->update_account(
        $subject->{did},
        deactivated_at => $body->{deactivated}{applied} ? time : undef,
      );
    }
    return {
      subject => $status->{subject},
      ($status->{takedown} ? (takedown => $status->{takedown}) : ()),
      ($status->{deactivated} ? (deactivated => $status->{deactivated}) : ()),
    };
  });

  $registry->register('com.atproto.admin.sendEmail', sub ($c, $endpoint) {
    require_admin($c);
    my $body = $c->req->json || {};
    my $account = $c->store->get_account_by_did($body->{recipientDid} // q());
    $c->store->log_outbound_email(
      recipient_did   => $body->{recipientDid},
      recipient_email => $account ? $account->{email} : undef,
      sender_did      => $body->{senderDid},
      subject         => $body->{subject},
      content         => $body->{content},
      comment         => $body->{comment},
      sent            => 1,
    );
    return { sent => JSON::PP::true };
  });

  $registry->register('com.atproto.admin.updateAccountHandle', sub ($c, $endpoint) {
    require_admin($c);
    my $body = $c->req->json || {};
    my $account = $c->store->get_account_by_did($body->{did} // q());
    xrpc_error(404, 'AccountNotFound', 'Account was not found') unless $account;
    my $handle = normalize_handle($body->{handle}, $c->config_value('service_handle_domain', 'localhost'));
    xrpc_error(400, 'InvalidHandle', 'Requested handle is invalid') unless defined $handle;
    my $existing = $c->store->get_account_by_handle($handle);
    xrpc_error(400, 'HandleNotAvailable', 'That handle is already registered')
      if $existing && ($existing->{did} // q()) ne $account->{did};
    $c->store->update_account(
      $account->{did},
      handle  => $handle,
      did_doc => account_did_doc($c->app->settings, { %$account, handle => $handle }),
    );
    return {};
  });

  $registry->register('com.atproto.admin.updateAccountPassword', sub ($c, $endpoint) {
    require_admin($c);
    my $body = $c->req->json || {};
    xrpc_error(400, 'InvalidPassword', 'Passwords must be at least 8 characters long')
      if length($body->{password} // q()) < 8;
    my $account = $c->store->get_account_by_did($body->{did} // q());
    xrpc_error(404, 'AccountNotFound', 'Account was not found') unless $account;
    my $password_record = hash_password($body->{password});
    $c->store->update_account(
      $account->{did},
      password_hash => $password_record->{hash},
      password_salt => $password_record->{salt},
    );
    return {};
  });

  $registry->register('com.atproto.admin.updateAccountEmail', sub ($c, $endpoint) {
    require_admin($c);
    my $body = $c->req->json || {};
    my $account = find_account($c, $body->{account} // q());
    xrpc_error(404, 'AccountNotFound', 'Account was not found') unless $account;
    $c->store->update_account(
      $account->{did},
      email              => $body->{email},
      email_confirmed_at => undef,
    );
    return {};
  });

  $registry->register('com.atproto.admin.deleteAccount', sub ($c, $endpoint) {
    require_admin($c);
    my $body = $c->req->json || {};
    my $account = $c->store->get_account_by_did($body->{did} // q());
    xrpc_error(404, 'AccountNotFound', 'Account was not found') unless $account;
    $c->store->txn(sub ($dbh) {
      $c->store->update_account(
        $account->{did},
        deactivated_at => time,
        deleted_at     => time,
      );
      $c->store->revoke_sessions_by_did($account->{did});
      $c->store->revoke_app_passwords_by_did($account->{did});
    });
    return {};
  });

  $registry->register('com.atproto.admin.disableInviteCodes', sub ($c, $endpoint) {
    require_admin($c);
    my $body = $c->req->json || {};
    $c->store->disable_invite_codes(
      codes    => $body->{codes},
      accounts => $body->{accounts},
    );
    return {};
  });

  $registry->register('com.atproto.admin.getInviteCodes', sub ($c, $endpoint) {
    require_admin($c);
    my $page = $c->store->list_invite_codes(
      sort   => $c->param('sort') // 'recent',
      cursor => $c->param('cursor'),
      limit  => $c->param('limit') // 100,
    );
    return {
      (defined $page->{cursor} ? (cursor => $page->{cursor}) : ()),
      codes => [ map { invite_code_view($c->store, $_) } @{ $page->{items} } ],
    };
  });

  $registry->register('com.atproto.admin.disableAccountInvites', sub ($c, $endpoint) {
    require_admin($c);
    my $body = $c->req->json || {};
    my $account = $c->store->get_account_by_did($body->{account} // q());
    xrpc_error(404, 'AccountNotFound', 'Account was not found') unless $account;
    $c->store->update_account(
      $account->{did},
      invites_disabled => 1,
      invite_note      => $body->{note},
    );
    return {};
  });

  $registry->register('com.atproto.admin.enableAccountInvites', sub ($c, $endpoint) {
    require_admin($c);
    my $body = $c->req->json || {};
    my $account = $c->store->get_account_by_did($body->{account} // q());
    xrpc_error(404, 'AccountNotFound', 'Account was not found') unless $account;
    $c->store->update_account(
      $account->{did},
      invites_disabled => 0,
      invite_note      => $body->{note},
    );
    return {};
  });

  $registry->register('com.atproto.admin.updateAccountSigningKey', sub ($c, $endpoint) {
    require_admin($c);
    my $body = $c->req->json || {};
    my $account = $c->store->get_account_by_did($body->{did} // q());
    xrpc_error(404, 'AccountNotFound', 'Account was not found') unless $account;
    my $multibase = $body->{signingKey} // q();
    $multibase =~ s/\Adid:key://;
    my $updated = {
      %$account,
      public_key_multibase => $multibase,
    };
    $c->store->update_account(
      $account->{did},
      public_key_multibase => $multibase,
      did_doc              => account_did_doc($c->app->settings, $updated),
    );
    return {};
  });
}

sub _subject_from_params ($c) {
  return { did => $c->param('did') } if defined($c->param('did')) && !defined($c->param('uri')) && !defined($c->param('blob'));
  return { uri => $c->param('uri') } if defined $c->param('uri');
  return {
    did => $c->param('did'),
    cid => $c->param('blob'),
  } if defined $c->param('blob');
  xrpc_error(400, 'InvalidRequest', 'A subject reference is required');
}

1;
