package ATProto::PDS::API::Admin;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use JSON::PP ();

use ATProto::PDS::API::Helpers qw(account_view admin_account_view find_account invite_code_view require_admin subject_key update_account_email);
use ATProto::PDS::API::Util qw(flatten_params xrpc_error);
use ATProto::PDS::Auth::Password qw(hash_password);
use ATProto::PDS::Constants qw(EVENT_TYPE_IDENTITY);
use ATProto::PDS::Crypto::Secp256k1 qw(signing_did_to_public_key_multibase);
use ATProto::PDS::Identity qw(account_did_doc normalize_handle resolve_handle_to_did service_did);
use ATProto::PDS::Moderation qw(current_record_subject current_subject_status parse_at_uri);

our @EXPORT_OK = qw(register_admin_handlers);
my $NEW_PASSWORD_MAX_LENGTH = 256;

sub register_admin_handlers ($registry, $app) {
  $registry->register('com.atproto.admin.getAccountInfo', sub ($c, $endpoint) {
    require_admin($c);
    my $account = $c->store->get_account_by_did($c->param('did') // q());
    xrpc_error(404, 'AccountNotFound', 'Account was not found') unless $account;
    return admin_account_view($c->store, $account, entryway => $c->config_value('entryway', 0));
  });

  $registry->register('com.atproto.admin.getAccountInfos', sub ($c, $endpoint) {
    require_admin($c);
    my @dids = flatten_params($c->every_param('dids'));
    my %accounts_by_did = map { $_->{did} => $_ } @{ $c->store->get_accounts_by_dids(\@dids) };
    return {
      infos => [
        map { admin_account_view($c->store, $_, entryway => $c->config_value('entryway', 0)) }
        grep { defined }
        map { $accounts_by_did{$_} } @dids
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
    my $account_before = (exists($subject->{did}) && !exists($subject->{uri}) && !exists($subject->{cid}))
      ? $c->store->get_account_by_did($subject->{did})
      : undef;
    my $status = $c->store->put_subject_status(
      subject_key  => $subject_key,
      subject      => $subject,
      takedown     => exists($body->{takedown}) ? $body->{takedown} : ($existing ? $existing->{takedown} : undef),
      deactivated  => exists($body->{deactivated}) ? $body->{deactivated} : ($existing ? $existing->{deactivated} : undef),
    );
    _sync_hide_label($c, $subject, $existing, $status);
    my $account_after = $account_before;
    if (exists($subject->{did}) && !exists($subject->{uri}) && !exists($subject->{cid}) && exists($body->{deactivated})) {
      $account_after = $c->store->update_account(
        $subject->{did},
        deactivated_at => $body->{deactivated}{applied} ? time : undef,
      );
    }
    if (exists($subject->{did}) && !exists($subject->{uri}) && !exists($subject->{cid}) && (exists($body->{takedown}) || exists($body->{deactivated}))) {
      my $before = _repo_account_event_payload($account_before, $existing);
      my $after  = _repo_account_event_payload($account_after, $status);
      _append_account_event($c, $subject->{did}, $account_after, $after)
        unless _same_account_event_payload($before, $after);
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
    xrpc_error(400, 'InvalidRequest', 'Recipient not found') unless $account;
    xrpc_error(400, 'InvalidRequest', 'account does not have an email address')
      unless defined($account->{email}) && length($account->{email});
    my $subject = defined($body->{subject}) && length($body->{subject})
      ? $body->{subject}
      : 'Message via your PDS';
    $c->store->log_outbound_email(
      recipient_did   => $body->{recipientDid},
      recipient_email => $account->{email},
      sender_did      => $body->{senderDid},
      subject         => $subject,
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
    my $domain = $c->config_value('service_handle_domain', 'localhost');
    my $handle = normalize_handle($body->{handle}, $domain);
    $handle = normalize_handle($body->{handle}, undef, { no_append => 1 })
      unless defined $handle;
    xrpc_error(400, 'InvalidHandle', 'Requested handle is invalid') unless defined $handle;
    my $service_handle = normalize_handle($handle, $domain, { no_append => 1 });
    if (!defined $service_handle) {
      my $resolved_did = resolve_handle_to_did($c->app->settings, $handle);
      xrpc_error(400, 'InvalidRequest', 'External handle did not resolve to DID')
        unless defined $resolved_did && lc($resolved_did) eq lc($account->{did});
    }
    my $existing = $c->store->get_account_by_handle($handle);
    xrpc_error(400, 'InvalidRequest', "Handle already taken: $handle")
      if $existing && ($existing->{did} // q()) ne $account->{did};
    my $updated = $c->store->update_account(
      $account->{did},
      handle  => $handle,
      did_doc => account_did_doc($c->app->settings, { %$account, handle => $handle }),
    );
    _append_identity_event($c, $updated);
    return {};
  });

  $registry->register('com.atproto.admin.updateAccountPassword', sub ($c, $endpoint) {
    require_admin($c);
    my $body = $c->req->json || {};
    xrpc_error(400, 'InvalidRequest', 'Invalid password length.')
      if length($body->{password} // q()) > $NEW_PASSWORD_MAX_LENGTH;
    my $account = $c->store->get_account_by_did($body->{did} // q());
    xrpc_error(404, 'AccountNotFound', 'Account was not found') unless $account;
    my $password_record = hash_password($body->{password});
    $c->store->txn(sub ($dbh) {
      $c->store->update_account(
        $account->{did},
        password_hash => $password_record->{hash},
        password_salt => $password_record->{salt},
      );
      $c->store->revoke_sessions_by_did($account->{did});
    });
    return {};
  });

  $registry->register('com.atproto.admin.updateAccountEmail', sub ($c, $endpoint) {
    require_admin($c);
    my $body = $c->req->json || {};
    my $account = find_account($c, $body->{account} // q());
    xrpc_error(400, 'InvalidRequest', 'Account does not exist: ' . ($body->{account} // q()))
      unless $account;
    update_account_email($c, $account->{did}, $body->{email});
    return {};
  });

  $registry->register('com.atproto.admin.deleteAccount', sub ($c, $endpoint) {
    require_admin($c);
    my $body = $c->req->json || {};
    my $account = $c->store->get_account_by_did($body->{did} // q());
    $c->store->txn(sub ($dbh) {
      my $did = $body->{did} // q();
      my $deleted = $account
        ? $c->store->update_account(
          $did,
          deactivated_at => time,
          deleted_at     => time,
        )
        : undef;
      $c->store->revoke_sessions_by_did($did);
      $c->store->revoke_app_passwords_by_did($did);
      my $payload = $deleted
        ? _repo_account_event_payload($deleted, undef)
        : {
          active => JSON::PP::false,
          status => 'deleted',
        };
      _append_account_event($c, $did, $deleted, $payload);
    });
    $c->render(data => q());
    return;
  });

  $registry->register('com.atproto.admin.disableInviteCodes', sub ($c, $endpoint) {
    require_admin($c);
    my $body = $c->req->json || {};
    xrpc_error(400, 'InvalidRequest', 'cannot disable admin invite codes')
      if grep { defined($_) && $_ eq 'admin' } @{ $body->{accounts} || [] };
    $c->store->disable_invite_codes(
      codes    => $body->{codes},
      accounts => $body->{accounts},
    );
    return {};
  });

  $registry->register('com.atproto.admin.getInviteCodes', sub ($c, $endpoint) {
    require_admin($c);
    my $sort = $c->param('sort') // 'recent';
    xrpc_error(400, 'InvalidRequest', "unknown sort method: $sort")
      unless $sort eq 'recent' || $sort eq 'usage';
    my $page = eval {
      $c->store->list_invite_codes(
        sort   => $sort,
        cursor => $c->param('cursor'),
        limit  => $c->param('limit') // 100,
      );
    };
    if (my $err = $@) {
      xrpc_error(400, 'InvalidRequest', 'Malformed cursor')
        if !ref($err) && ($err // q()) =~ /invalid usage cursor/;
      die $err;
    }
    return {
      (defined $page->{cursor} ? (cursor => $page->{cursor}) : ()),
      codes => [ map { invite_code_view($c->store, $_) } @{ $page->{items} } ],
    };
  });

  $registry->register('com.atproto.admin.disableAccountInvites', sub ($c, $endpoint) {
    require_admin($c);
    my $body = $c->req->json || {};
    return _set_account_invites($c, $body->{account}, 1, $body->{note});
  });

  $registry->register('com.atproto.admin.enableAccountInvites', sub ($c, $endpoint) {
    require_admin($c);
    my $body = $c->req->json || {};
    return _set_account_invites($c, $body->{account}, 0, $body->{note});
  });

  $registry->register('com.atproto.admin.updateAccountSigningKey', sub ($c, $endpoint) {
    require_admin($c);
    my $body = $c->req->json || {};
    my $account = $c->store->get_account_by_did($body->{did} // q());
    xrpc_error(404, 'AccountNotFound', 'Account was not found') unless $account;
    my $signing_key = $body->{signingKey} // q();
    xrpc_error(400, 'InvalidRequest', 'signingKey must be a did:key')
      unless $signing_key =~ /\Adid:key:/;
    my $multibase = eval { signing_did_to_public_key_multibase($signing_key) };
    xrpc_error(400, 'InvalidRequest', 'signingKey must be a valid secp256k1 did:key')
      if $@ || !defined($multibase) || !length($multibase);
    my $updated = {
      %$account,
      public_key_multibase => $multibase,
      signing_key_did      => $signing_key,
    };
    my $stored = $c->store->update_account(
      $account->{did},
      public_key_multibase => $multibase,
      signing_key_did      => $signing_key,
      did_doc              => account_did_doc($c->app->settings, $updated),
    );
    _append_identity_event($c, $stored);
    return {};
  });
}

sub _append_identity_event ($c, $account) {
  $c->append_event(
    did     => $account->{did},
    type    => EVENT_TYPE_IDENTITY,
    rev     => $account->{repo_rev},
    payload => {
      did    => $account->{did},
      handle => $account->{handle},
    },
  );
  return;
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
      unless $blob && $c->store->blob_owned_by_did($subject->{cid}, $subject->{did});
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
  my $label_time = time;
  my $label = {
    ver => 1,
    src => $src,
    uri => $uri,
    (defined $cid ? (cid => $cid) : ()),
    val => '!hide',
    cts => ATProto::PDS::API::Util::iso8601($label_time),
    ($now ? () : (neg => JSON::PP::true)),
  };

  if ($now) {
    $c->store->put_label(
      subject_key => subject_key($subject),
      src         => $src,
      uri         => $uri,
      cid         => $cid,
      val         => '!hide',
      created_at  => $label_time,
      neg         => 0,
    );
  } else {
    $c->store->put_label(
      subject_key => subject_key($subject),
      src         => $src,
      uri         => $uri,
      cid         => $cid,
      val         => '!hide',
      created_at  => $label_time,
      neg         => 1,
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

sub _set_account_invites ($c, $identifier, $disabled, $note) {
  my $account = $c->store->get_account_by_did($identifier // q());
  xrpc_error(404, 'AccountNotFound', 'Account was not found') unless $account;
  $c->store->update_account(
    $account->{did},
    invites_disabled => $disabled ? 1 : 0,
    invite_note      => undef,
  );
  return {};
}

sub _append_account_event ($c, $did, $account, $payload) {
  $c->append_event(
    did     => $did,
    type    => 'account',
    rev     => ($account->{repo_rev} // undef),
    payload => $payload,
  );
  return;
}

sub _repo_account_event_payload ($account, $status) {
  my $takedown = ($status && $status->{takedown} && $status->{takedown}{applied}) ? 1 : 0;
  # Match the effective hosting state that firehose consumers should observe.
  return {
    active => JSON::PP::false,
    status => 'deleted',
  } if $account && defined $account->{deleted_at};
  return {
    active => JSON::PP::false,
    status => 'takendown',
  } if $takedown;
  return {
    active => JSON::PP::false,
    status => 'deactivated',
  } if $account && defined $account->{deactivated_at};
  return {
    active => JSON::PP::true,
  };
}

sub _same_account_event_payload ($left, $right) {
  my $left_active  = ($left && $left->{active}) ? 1 : 0;
  my $right_active = ($right && $right->{active}) ? 1 : 0;
  return 0 if $left_active != $right_active;
  return (($left->{status} // q()) eq ($right->{status} // q())) ? 1 : 0;
}

1;
