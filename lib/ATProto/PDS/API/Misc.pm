package ATProto::PDS::API::Misc;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use JSON::PP ();

use ATProto::PDS::API::Helpers qw(find_account issue_account_action_token require_admin subject_key);
use ATProto::PDS::API::Server qw(require_auth);
use ATProto::PDS::API::Util qw(flatten_params iso8601 pump_event_subscription subscription_start_seq xrpc_error);
use ATProto::PDS::Auth::OAuth qw(oauth_scope_has_atproto);
use ATProto::PDS::Auth::Password qw(hash_password random_hex);
use ATProto::PDS::Constants qw(
  ACTION_TOKEN_PLC_OPERATION
  EVENT_TYPE_IDENTITY
  EVENT_TYPE_LABEL
  TOKEN_AUD_ACCESS
);
use ATProto::PDS::EventStream qw(encode_message_frame);
use ATProto::PDS::Identity qw(account_did_doc normalize_handle resolve_handle_to_did service_did service_did_doc);
use ATProto::PDS::Moderation qw(assert_report_allowed);
use ATProto::PDS::PLC qw(create_signed_plc_operation is_plc_did plc_rotation_did plc_update_handle recommended_did_credentials refresh_plc_did_doc submit_plc_operation);
use ATProto::PDS::Repo::CID;
use ATProto::PDS::Repo::DagCbor qw(encode_dag_cbor);

our @EXPORT_OK = qw(register_misc_handlers);

sub register_misc_handlers ($registry, $app) {
  $registry->register('com.atproto.identity.getRecommendedDidCredentials', sub ($c, $endpoint) {
    my (undef, $account) = require_auth($c, audience => TOKEN_AUD_ACCESS);
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
    my ($claims, $account) = require_auth(
      $c,
      audience            => TOKEN_AUD_ACCESS,
      required_permission => {
        type => 'identity',
        attr => '*',
      },
    );
    _assert_full_non_oauth_access($claims);
    xrpc_error(400, 'InvalidRequest', 'account does not have an email address')
      unless defined($account->{email}) && length($account->{email});
    issue_account_action_token(
      $c,
      $account,
      purpose => ACTION_TOKEN_PLC_OPERATION,
      subject => 'PLC update requested',
      content => sub ($token) { "Use token $token->{token} to authorize your PLC operation." },
    );
    return {};
  });

  $registry->register('com.atproto.identity.signPlcOperation', sub ($c, $endpoint) {
    my ($claims, $account) = require_auth(
      $c,
      audience            => TOKEN_AUD_ACCESS,
      required_permission => {
        type => 'identity',
        attr => '*',
      },
    );
    _assert_full_non_oauth_access($claims);
    xrpc_error(400, 'InvalidRequest', 'PLC operations are only supported for did:plc accounts')
      unless is_plc_did($account->{did});
    my $body = $c->req->json || {};
    my $token_value = $body->{token} // q();
    xrpc_error(400, 'InvalidRequest', 'email confirmation token required to sign PLC operations')
      unless length $token_value;
    my $token = $c->store->get_action_token($token_value);
    xrpc_error(400, 'InvalidToken', 'Token is invalid') unless $token;
    xrpc_error(400, 'InvalidToken', 'Token purpose did not match') unless ($token->{purpose} // q()) eq ACTION_TOKEN_PLC_OPERATION;
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
    my (undef, $account) = require_auth(
      $c,
      audience            => TOKEN_AUD_ACCESS,
      required_permission => {
        type => 'identity',
        attr => '*',
      },
    );
    xrpc_error(400, 'InvalidRequest', 'PLC operations are only supported for did:plc accounts')
      unless is_plc_did($account->{did});
    my $body = $c->req->json || {};
    my $operation = $body->{operation} || {};
    xrpc_error(400, 'InvalidRequest', 'Invalid operation')
      unless _valid_plc_operation($operation);
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
    $account = $c->store->update_account($account->{did}, did_doc => $did_doc);
    _append_identity_event($c, $account);
    return {};
  });

  $registry->register('com.atproto.identity.updateHandle', sub ($c, $endpoint) {
    my (undef, $account) = require_auth(
      $c,
      audience            => TOKEN_AUD_ACCESS,
      required_permission => {
        type => 'identity',
        attr => 'handle',
      },
    );
    my $body   = $c->req->json || {};
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
    xrpc_error(400, 'HandleNotAvailable', 'That handle is already registered')
      if $existing && ($existing->{did} // q()) ne $account->{did};
    xrpc_error(400, 'HandleNotAvailable', 'That handle is reserved')
      if $c->store->get_reserved_handle($handle);
    my %changes = (handle => $handle);
    if (is_plc_did($account->{did})) {
      plc_update_handle($c->app->settings, $account, $handle);
    } else {
      $changes{did_doc} = account_did_doc($c->app->settings, { %$account, handle => $handle });
    }
    my $updated = $c->store->update_account($account->{did}, %changes);
    _append_identity_event($c, $updated);
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
    my (undef, $account) = require_auth(
      $c,
      audience            => TOKEN_AUD_ACCESS,
      required_permission => {
        type => 'rpc',
        aud  => $c->service_proxy->_permission_audience_for_request($c, $endpoint->{id}),
        lxm  => $endpoint->{id},
      },
    );
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
    my $patterns = [ flatten_params($c->every_param('uriPatterns')) ];
    my @sources  = flatten_params($c->every_param('sources'));
    xrpc_error(400, 'InvalidRequest', 'uriPatterns is required') unless @$patterns;
    my $page = $c->store->list_labels(
      uri_patterns => $patterns,
      (@sources ? (sources => \@sources) : ()),
      limit        => $c->param('limit') // 50,
      cursor       => $c->param('cursor'),
    );
    return _label_page($page);
  });

  $registry->register('com.atproto.temp.fetchLabels', sub ($c, $endpoint) {
    my $page = $c->store->list_labels(
      limit  => $c->param('limit') // 50,
      cursor => $c->param('cursor'),
    );
    return _label_page($page);
  });

  $registry->register('com.atproto.label.subscribeLabels', sub ($c, $endpoint) {
    my $next_seq = subscription_start_seq(
      $c,
      cursor_param   => $c->param('cursor'),
      future_message => 'Cursor is ahead of the local label stream',
    );
    return unless defined $next_seq;
    pump_event_subscription($c, $next_seq, sub ($event) {
      return unless ($event->{type} // q()) eq EVENT_TYPE_LABEL;
      my $labels = $event->{payload}{labels} || [];
      return unless @$labels;
      return (
        encode_message_frame('#labels', {
          seq    => 0 + $event->{seq},
          labels => $labels,
        }),
        EVENT_TYPE_LABEL,
      );
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
    require_admin($c);
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

sub _label_view ($row) {
  return {
    ver => 1,
    src => $row->{src},
    uri => $row->{uri},
    (defined($row->{cid}) ? (cid => $row->{cid}) : ()),
    val => $row->{val},
    ($row->{neg} ? (neg => JSON::PP::true) : ()),
    cts => iso8601($row->{created_at}),
    (defined($row->{exp}) ? (exp => iso8601($row->{exp})) : ()),
    (defined($row->{sig}) ? (sig => $row->{sig}) : ()),
  };
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

sub _assert_full_non_oauth_access ($claims) {
  return if ($claims->{typ} // q()) eq 'oauth_access';
  return if oauth_scope_has_atproto($claims->{scope} // q());
  xrpc_error(400, 'InvalidToken', 'Bad token scope')
    unless (($claims->{scope} // TOKEN_AUD_ACCESS) eq TOKEN_AUD_ACCESS);
  return 1;
}

sub _valid_plc_operation ($operation) {
  return 0 unless ref($operation) eq 'HASH';
  return 0 unless ($operation->{type} // q()) eq 'plc_operation';
  return 0 unless ref($operation->{rotationKeys}) eq 'ARRAY' && @{ $operation->{rotationKeys} };
  return 0 unless ref($operation->{alsoKnownAs}) eq 'ARRAY';
  return 0 unless ref($operation->{verificationMethods}) eq 'HASH' && keys %{ $operation->{verificationMethods} };
  return 0 unless ref($operation->{services}) eq 'HASH' && ref($operation->{services}{atproto_pds}) eq 'HASH';
  return 0 unless defined($operation->{sig}) && !ref($operation->{sig}) && length($operation->{sig});
  return 0 if exists($operation->{prev}) && defined($operation->{prev}) && ref($operation->{prev});
  return 0 if grep { !defined($_) || ref($_) || !length($_) } @{ $operation->{rotationKeys} };
  return 0 if grep { !defined($_) || ref($_) || !length($_) } @{ $operation->{alsoKnownAs} };
  for my $value (values %{ $operation->{verificationMethods} }) {
    return 0 if !defined($value) || ref($value) || !length($value);
  }
  return 1;
}

sub _label_page ($page) {
  return {
    (defined $page->{cursor} ? (cursor => $page->{cursor}) : ()),
    labels => [ map { _label_view($_) } @{ $page->{items} } ],
  };
}

1;
