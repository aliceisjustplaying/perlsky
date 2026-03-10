package ATProto::PDS::API::Misc;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use JSON::PP ();
use Mojo::IOLoop;

use ATProto::PDS::API::Helpers qw(find_account require_admin subject_key);
use ATProto::PDS::API::Server qw(require_auth);
use ATProto::PDS::API::Util qw(iso8601 xrpc_error);
use ATProto::PDS::Auth::Password qw(hash_password random_hex);
use ATProto::PDS::EventStream qw(encode_error_frame encode_info_frame encode_message_frame);
use ATProto::PDS::Identity qw(account_did_doc normalize_handle service_did service_did_doc);
use ATProto::PDS::Moderation qw(assert_report_allowed);
use ATProto::PDS::PLC qw(create_signed_plc_operation is_plc_did plc_rotation_did plc_update_handle recommended_did_credentials refresh_plc_did_doc submit_plc_operation);
use ATProto::PDS::Repo::CID;
use ATProto::PDS::Repo::DagCbor qw(encode_dag_cbor);

our @EXPORT_OK = qw(register_misc_handlers);

sub register_misc_handlers ($registry, $app) {
  $registry->register('com.atproto.identity.getRecommendedDidCredentials', sub ($c, $endpoint) {
    my (undef, $account) = require_auth($c, audience => 'access', allow_refresh => 1);
    return recommended_did_credentials($c->app->settings, $account);
  });

  $registry->register('com.atproto.identity.refreshIdentity', sub ($c, $endpoint) {
    my $body = $c->req->json || {};
    my $identifier = $body->{identifier} // q();
    my $account = find_account($c, $identifier);
    if ($account) {
      return {
        did    => $account->{did},
        handle => $account->{handle},
        didDoc => $account->{did_doc} || account_did_doc($c->app->settings, $account),
      };
    }

    my $service_did = service_did($c->app->settings);
    if (lc($identifier) eq lc($service_did)) {
      return {
        did    => $service_did,
        handle => $c->config_value('service_handle_domain', 'localhost'),
        didDoc => service_did_doc($c->app->settings),
      };
    }

    xrpc_error(
      404,
      ($identifier =~ /^did:/ ? 'DidNotFound' : 'HandleNotFound'),
      "No identity found for $identifier",
    );
  });

  $registry->register('com.atproto.identity.requestPlcOperationSignature', sub ($c, $endpoint) {
    my (undef, $account) = require_auth($c, audience => 'access', allow_refresh => 1);
    xrpc_error(400, 'InvalidRequest', 'account does not have an email address')
      unless defined($account->{email}) && length($account->{email});
    my $token = $c->store->create_action_token(
      did        => $account->{did},
      email      => $account->{email},
      purpose    => 'plc_operation',
      expires_at => time + 3600,
    );
    $c->store->log_outbound_email(
      recipient_did   => $account->{did},
      recipient_email => $account->{email},
      subject         => 'PLC update requested',
      content         => "Use token $token->{token} to authorize your PLC operation.",
    );
    return {};
  });

  $registry->register('com.atproto.identity.signPlcOperation', sub ($c, $endpoint) {
    my (undef, $account) = require_auth($c, audience => 'access', allow_refresh => 1);
    xrpc_error(400, 'InvalidRequest', 'PLC operations are only supported for did:plc accounts')
      unless is_plc_did($account->{did});
    my $body = $c->req->json || {};
    my $token_value = $body->{token} // q();
    xrpc_error(400, 'InvalidRequest', 'email confirmation token required to sign PLC operations')
      unless length $token_value;
    my $token = $c->store->get_action_token($token_value);
    xrpc_error(400, 'InvalidToken', 'Token is invalid') unless $token;
    xrpc_error(400, 'InvalidToken', 'Token purpose did not match') unless ($token->{purpose} // q()) eq 'plc_operation';
    xrpc_error(400, 'ExpiredToken', 'Token has expired')
      if defined($token->{expires_at}) && $token->{expires_at} < time;
    xrpc_error(400, 'InvalidToken', 'Token was not issued for this account')
      unless ($token->{did} // q()) eq $account->{did};
    $c->store->consume_action_token($token->{token});
    my $current = recommended_did_credentials($c->app->settings, $account);
    my $last_op = ATProto::PDS::PLC::get_last_plc_operation($c->app->settings, $account->{did});
    return {
      operation => create_signed_plc_operation($c->app->settings, {
        type                => 'plc_operation',
        rotationKeys        => $body->{rotationKeys} // $current->{rotationKeys},
        alsoKnownAs         => $body->{alsoKnownAs} // $current->{alsoKnownAs},
        verificationMethods => $body->{verificationMethods} // $current->{verificationMethods},
        services            => $body->{services} // $current->{services},
        prev                => ATProto::PDS::Repo::CID->for_dag_cbor(encode_dag_cbor($last_op))->to_string,
      }),
    };
  });

  $registry->register('com.atproto.identity.submitPlcOperation', sub ($c, $endpoint) {
    my (undef, $account) = require_auth($c, audience => 'access', allow_refresh => 1);
    xrpc_error(400, 'InvalidRequest', 'PLC operations are only supported for did:plc accounts')
      unless is_plc_did($account->{did});
    my $body = $c->req->json || {};
    my $operation = $body->{operation} || {};
    my $rotation_did = ATProto::PDS::PLC::plc_rotation_did($c->app->settings);
    xrpc_error(400, 'InvalidRequest', q{Rotation keys do not include server's rotation key})
      unless grep { ($_ // q()) eq $rotation_did } @{ $operation->{rotationKeys} || [] };
    xrpc_error(400, 'InvalidRequest', 'Incorrect type on atproto_pds service')
      unless (($operation->{services}{atproto_pds}{type} // q()) eq 'AtprotoPersonalDataServer');
    xrpc_error(400, 'InvalidRequest', 'Incorrect endpoint on atproto_pds service')
      unless (($operation->{services}{atproto_pds}{endpoint} // q()) eq $c->app->settings->{base_url});
    xrpc_error(400, 'InvalidRequest', 'Incorrect signing key')
      unless (($operation->{verificationMethods}{atproto} // q()) eq ($account->{signing_key_did} // q()));
    my $primary_aka = (($operation->{alsoKnownAs} || [])->[0]) // q();
    xrpc_error(400, 'InvalidRequest', 'Incorrect handle in alsoKnownAs')
      if ($account->{handle} // q()) && ($primary_aka ne 'at://' . $account->{handle});
    submit_plc_operation($c->app->settings, $account->{did}, $operation);
    my $did_doc = refresh_plc_did_doc($c->app->settings, $account->{did});
    $c->store->update_account($account->{did}, did_doc => $did_doc);
    $account = $c->store->update_account($account->{did}, did_doc => $did_doc);
    $c->append_event(
      did     => $account->{did},
      type    => 'identity',
      rev     => $account->{repo_rev},
      payload => {
        did    => $account->{did},
        handle => $account->{handle},
      },
    );
    return {};
  });

  $registry->register('com.atproto.identity.updateHandle', sub ($c, $endpoint) {
    my (undef, $account) = require_auth($c, audience => 'access', allow_refresh => 1);
    my $body   = $c->req->json || {};
    my $domain = $c->config_value('service_handle_domain', 'localhost');
    my $handle = normalize_handle($body->{handle}, $domain);
    xrpc_error(400, 'InvalidHandle', 'Requested handle is invalid') unless defined $handle;
    my $existing = $c->store->get_account_by_handle($handle);
    xrpc_error(400, 'HandleNotAvailable', 'That handle is already registered')
      if $existing && ($existing->{did} // q()) ne $account->{did};
    xrpc_error(400, 'HandleNotAvailable', 'That handle is reserved')
      if $c->store->get_reserved_handle($handle);
    my $did_doc = is_plc_did($account->{did})
      ? plc_update_handle($c->app->settings, $account, $handle)
      : account_did_doc($c->app->settings, { %$account, handle => $handle });
    my $updated = $c->store->update_account(
      $account->{did},
      handle  => $handle,
      did_doc => $did_doc,
    );
    $c->append_event(
      did     => $updated->{did},
      type    => 'identity',
      rev     => $updated->{repo_rev},
      payload => {
        did    => $updated->{did},
        handle => $updated->{handle},
      },
    );
    return {};
  });

  $registry->register('com.atproto.lexicon.resolveLexicon', sub ($c, $endpoint) {
    my $nsid = $c->req->url->query->param('nsid') // q();
    my $schema = $c->lexicons->get($nsid);
    xrpc_error(404, 'LexiconNotFound', "No lexicon found for $nsid") unless $schema;
    my $bytes = encode_dag_cbor($schema);
    my $cid   = ATProto::PDS::Repo::CID->for_dag_cbor($bytes)->to_string;
    return {
      uri    => 'at://' . service_did($c->app->settings) . '/com.atproto.lexicon.schema/' . $nsid,
      cid    => $cid,
      schema => $schema,
    };
  });

  $registry->register('com.atproto.moderation.createReport', sub ($c, $endpoint) {
    my (undef, $account) = require_auth($c, audience => 'access', allow_refresh => 1);
    my $body = $c->req->json || {};
    assert_report_allowed($c, $account, $body->{reasonType});
    my $row = $c->store->create_report(
      reason_type => $body->{reasonType},
      reason      => $body->{reason},
      subject     => $body->{subject},
      reported_by => $account->{did},
      mod_tool    => $body->{modTool},
    );
    return {
      id         => 0 + $row->{id},
      reasonType => $row->{reason_type},
      ($row->{reason} ? (reason => $row->{reason}) : ()),
      subject    => $row->{subject},
      reportedBy => $row->{reported_by},
      createdAt  => iso8601($row->{created_at}),
    };
  });

  $registry->register('com.atproto.label.queryLabels', sub ($c, $endpoint) {
    my $patterns = [ _flatten_params($c->every_param('uriPatterns')) ];
    my @sources  = _flatten_params($c->every_param('sources'));
    xrpc_error(400, 'InvalidRequest', 'uriPatterns is required') unless @$patterns;
    my $page = $c->store->list_labels(
      uri_patterns => $patterns,
      (@sources ? (sources => \@sources) : ()),
      limit        => $c->param('limit') // 50,
      cursor       => $c->param('cursor'),
    );
    return {
      (defined $page->{cursor} ? (cursor => $page->{cursor}) : ()),
      labels => [ map { _label_view($_) } @{ $page->{items} } ],
    };
  });

  $registry->register('com.atproto.temp.fetchLabels', sub ($c, $endpoint) {
    my $page = $c->store->list_labels(
      limit  => $c->param('limit') // 50,
      cursor => $c->param('cursor'),
    );
    return {
      (defined $page->{cursor} ? (cursor => $page->{cursor}) : ()),
      labels => [ map { _label_view($_) } @{ $page->{items} } ],
    };
  });

  $registry->register('com.atproto.label.subscribeLabels', sub ($c, $endpoint) {
    my $cursor_param = $c->param('cursor');
    my $latest = $c->store->latest_event_seq;
    my $oldest = $c->store->oldest_event_seq;

    my $next_seq;
    if (!defined $cursor_param || $cursor_param eq q()) {
      $next_seq = $latest + 1;
    } else {
      my $cursor = int($cursor_param);
      if ($cursor > $latest + 1) {
        $c->send({ binary => encode_error_frame('FutureCursor', 'Cursor is ahead of the local label stream') });
        $c->finish(1008);
        return;
      }
      if ($oldest && $cursor && $cursor < $oldest) {
        $c->send({ binary => encode_info_frame('OutdatedCursor', 'Cursor predates the oldest locally retained event') });
        $next_seq = $oldest;
      } else {
        $next_seq = $cursor || ($oldest || ($latest + 1));
      }
    }

    my $drain;
    $drain = sub {
      my $events = $c->store->list_events_from($next_seq, limit => 100);
      for my $event (@$events) {
        next unless ($event->{type} // q()) eq 'label';
        my $labels = $event->{payload}{labels} || [];
        next unless @$labels;
        $next_seq = $event->{seq} + 1;
        $c->send({ binary => encode_message_frame('#labels', {
          seq    => 0 + $event->{seq},
          labels => $labels,
        })});
      }
    };

    $drain->();
    my $timer_id = Mojo::IOLoop->recurring(0.25 => sub { $drain->() });
    $c->on(finish => sub ($c, $code, $reason = undef) {
      Mojo::IOLoop->remove($timer_id) if defined $timer_id;
    });
    return;
  });

  $registry->register('com.atproto.temp.addReservedHandle', sub ($c, $endpoint) {
    require_admin($c);
    my $body   = $c->req->json || {};
    my $domain = $c->config_value('service_handle_domain', 'localhost');
    my $handle = normalize_handle($body->{handle}, $domain);
    xrpc_error(400, 'InvalidHandle', 'Requested handle is invalid') unless defined $handle;
    $c->store->reserve_handle($handle);
    return {};
  });

  $registry->register('com.atproto.temp.checkSignupQueue', sub ($c, $endpoint) {
    return {
      activated => JSON::PP::true,
    };
  });

  $registry->register('com.atproto.temp.dereferenceScope', sub ($c, $endpoint) {
    my $scope = $c->param('scope') // q();
    xrpc_error(400, 'InvalidScopeReference', 'Scope reference must start with ref:')
      unless $scope =~ /\Aref:(.+)\z/;
    xrpc_error(400, 'InvalidScopeReference', 'Scope reference was empty') unless length $1;
    return {
      scope => $1,
    };
  });

  $registry->register('com.atproto.temp.requestPhoneVerification', sub ($c, $endpoint) {
    return {};
  });

  $registry->register('com.atproto.temp.revokeAccountCredentials', sub ($c, $endpoint) {
    my $body = $c->req->json || {};
    my $account = find_account($c, $body->{account} // q());
    xrpc_error(404, 'AccountNotFound', 'Account was not found') unless $account;
    my $password_record = hash_password(random_hex(16));
    $c->store->txn(sub ($dbh) {
      $c->store->update_account(
        $account->{did},
        password_hash => $password_record->{hash},
        password_salt => $password_record->{salt},
      );
      $c->store->revoke_sessions_by_did($account->{did});
      $c->store->revoke_app_passwords_by_did($account->{did});
    });
    return {};
  });
}

sub _flatten_params (@values) {
  my @flat;
  for my $value (@values) {
    push @flat, ref($value) eq 'ARRAY' ? @$value : $value;
  }
  return @flat;
}

sub _label_view ($row) {
  return {
    ver => 1,
    src => $row->{src},
    uri => $row->{uri},
    (defined($row->{cid}) ? (cid => $row->{cid}) : ()),
    val => $row->{val},
    cts => iso8601($row->{created_at}),
    (defined($row->{exp}) ? (exp => iso8601($row->{exp})) : ()),
    (defined($row->{sig}) ? (sig => $row->{sig}) : ()),
  };
}

1;
