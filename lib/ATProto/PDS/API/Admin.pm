package ATProto::PDS::API::Admin;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use JSON::PP ();

use ATProto::PDS::API::Helpers qw(account_view find_account invite_code_view require_admin subject_key);
use ATProto::PDS::API::Util qw(flatten_params xrpc_error);
use ATProto::PDS::Auth::Password qw(hash_password);
use ATProto::PDS::Crypto::Secp256k1 qw(signing_did_to_public_key_multibase);
use ATProto::PDS::Identity qw(account_did_doc normalize_handle service_did);
use ATProto::PDS::Moderation qw(current_record_subject current_subject_status parse_at_uri);

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
    my @dids = flatten_params($c->every_param('dids'));
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
    my $status = current_subject_status($c, $subject);
    xrpc_error(404, 'NotFound', 'Subject not found') unless $status;
    return {
      subject => $status->{subject},
      ($status->{takedown} ? (takedown => $status->{takedown}) : ()),
      ($status->{deactivated} ? (deactivated => $status->{deactivated}) : ()),
    };
  });

  $registry->register('com.atproto.admin.updateSubjectStatus', sub ($c, $endpoint) {
    require_admin($c);
    my $body = $c->req->json || {};
    my $subject = _validated_subject($c, $body->{subject} || {});
    my $subject_key = subject_key($subject);
    my $existing = $c->store->get_subject_status($subject_key);
    my $status = $c->store->put_subject_status(
      subject_key  => $subject_key,
      subject      => $subject,
      takedown     => exists($body->{takedown}) ? $body->{takedown} : ($existing ? $existing->{takedown} : undef),
      deactivated  => exists($body->{deactivated}) ? $body->{deactivated} : ($existing ? $existing->{deactivated} : undef),
    );
    _sync_hide_label($c, $subject, $existing, $status);
    if (exists($subject->{did}) && !exists($subject->{uri}) && !exists($subject->{cid}) && exists($body->{deactivated})) {
      $c->store->update_account(
        $subject->{did},
        deactivated_at => $body->{deactivated}{applied} ? time : undef,
      );
      $c->append_event(
        did     => $subject->{did},
        type    => 'account',
        rev     => ($c->store->get_account_by_did($subject->{did})->{repo_rev} // undef),
        payload => {
          active => $body->{deactivated}{applied} ? JSON::PP::false : JSON::PP::true,
          ($body->{deactivated}{applied} ? (status => 'deactivated') : ()),
        },
      );
    }
    if (exists($subject->{did}) && exists($subject->{cid})) {
      $c->store->update_blob(
        $subject->{cid},
        quarantined_at => ($status->{takedown} && $status->{takedown}{applied}) ? time : undef,
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
    my $signing_key = $body->{signingKey} // q();
    xrpc_error(400, 'InvalidRequest', 'signingKey must be a did:key')
      unless $signing_key =~ /\Adid:key:/;
    my $multibase = signing_did_to_public_key_multibase($signing_key);
    my $updated = {
      %$account,
      public_key_multibase => $multibase,
      signing_key_did      => $signing_key,
    };
    $c->store->update_account(
      $account->{did},
      public_key_multibase => $multibase,
      signing_key_did      => $signing_key,
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

sub _validated_subject ($c, $subject) {
  if (exists($subject->{did}) && !exists($subject->{uri}) && !exists($subject->{cid})) {
    my $account = $c->store->get_account_by_did($subject->{did});
    xrpc_error(404, 'NotFound', 'Subject not found') unless $account;
    return {
      %{$subject},
      '$type' => ($subject->{'$type'} // 'com.atproto.admin.defs#repoRef'),
    };
  }
  if (exists $subject->{uri}) {
    my $current = current_record_subject($c, $subject->{uri});
    xrpc_error(404, 'NotFound', 'Subject not found') unless $current;
    return {
      %{$current},
      '$type' => ($subject->{'$type'} // 'com.atproto.repo.strongRef'),
    };
  }
  if (exists($subject->{did}) && exists($subject->{cid})) {
    my $blob = $c->store->get_blob($subject->{cid});
    xrpc_error(404, 'NotFound', 'Subject not found')
      unless $blob && ($blob->{did} // q()) eq ($subject->{did} // q());
    return {
      %{$subject},
      '$type' => ($subject->{'$type'} // 'com.atproto.admin.defs#repoBlobRef'),
    };
  }
  xrpc_error(400, 'InvalidRequest', 'Invalid subject');
}

sub _sync_hide_label ($c, $subject, $before, $after) {
  my $was = ($before && $before->{takedown} && $before->{takedown}{applied}) ? 1 : 0;
  my $now = ($after && $after->{takedown} && $after->{takedown}{applied}) ? 1 : 0;
  return if $was == $now;

  my $src = service_did($c->app->settings);
  my ($uri, $cid) = _label_uri_and_cid($subject);
  my $label = {
    ver => 1,
    src => $src,
    uri => $uri,
    (defined $cid ? (cid => $cid) : ()),
    val => '!hide',
    cts => ATProto::PDS::API::Util::iso8601(time),
    ($now ? () : (neg => JSON::PP::true)),
  };

  if ($now) {
    $c->store->put_label(
      subject_key => subject_key($subject),
      src         => $src,
      uri         => $uri,
      cid         => $cid,
      val         => '!hide',
    );
  } else {
    $c->store->delete_label(
      subject_key => subject_key($subject),
      src         => $src,
      val         => '!hide',
    );
  }

  $c->append_event(
    did     => $src,
    type    => 'label',
    payload => {
      labels => [ $label ],
    },
  );
}

sub _label_uri_and_cid ($subject) {
  if (exists $subject->{uri}) {
    return ($subject->{uri}, $subject->{cid});
  }
  if (exists($subject->{did}) && exists($subject->{cid})) {
    return ('at://' . $subject->{did}, $subject->{cid});
  }
  return ('at://' . ($subject->{did} // q()), undef);
}

1;
