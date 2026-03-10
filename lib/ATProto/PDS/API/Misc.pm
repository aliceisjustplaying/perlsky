package ATProto::PDS::API::Misc;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use JSON::PP ();

use ATProto::PDS::API::Helpers qw(find_account subject_key);
use ATProto::PDS::API::Server qw(require_auth);
use ATProto::PDS::API::Util qw(iso8601 xrpc_error);
use ATProto::PDS::Auth::Password qw(hash_password random_hex);
use ATProto::PDS::Identity qw(account_did_doc normalize_handle service_did service_did_doc);
use ATProto::PDS::Repo::CID;
use ATProto::PDS::Repo::DagCbor qw(encode_dag_cbor);

our @EXPORT_OK = qw(register_misc_handlers);

sub register_misc_handlers ($registry, $app) {
  $registry->register('com.atproto.identity.getRecommendedDidCredentials', sub ($c, $endpoint) {
    return {
      rotationKeys        => [],
      alsoKnownAs         => [],
      verificationMethods => {},
      services            => {
        atproto_pds => service_did_doc($c->app->settings)->{service}[0],
      },
    };
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
    my $token = $c->store->create_action_token(
      did        => $account->{did},
      email      => $account->{email},
      purpose    => 'plc_signature',
      expires_at => time + 3600,
    );
    $c->store->log_outbound_email(
      recipient_did   => $account->{did},
      recipient_email => $account->{email},
      subject         => 'perlds PLC operation signature',
      content         => "Use token $token->{token} to sign your PLC operation.",
    ) if $account->{email};
    return {};
  });

  $registry->register('com.atproto.identity.signPlcOperation', sub ($c, $endpoint) {
    my (undef, $account) = require_auth($c, audience => 'access', allow_refresh => 1);
    my $body = $c->req->json || {};
    if (defined($body->{token}) && length($body->{token})) {
      my $token = $c->store->get_action_token($body->{token});
      xrpc_error(400, 'InvalidToken', 'Token was not found') unless $token;
      xrpc_error(400, 'InvalidToken', 'Token purpose did not match') unless ($token->{purpose} // q()) eq 'plc_signature';
      xrpc_error(400, 'ExpiredToken', 'Token has expired')
        if defined($token->{expires_at}) && $token->{expires_at} < time;
      xrpc_error(400, 'InvalidToken', 'Token was not issued for this account')
        unless ($token->{did} // q()) eq $account->{did};
      $c->store->consume_action_token($token->{token});
    }
    return {
      operation => {
        type                => 'com.atproto.identity.plcOperation',
        did                 => $account->{did},
        alsoKnownAs         => $body->{alsoKnownAs} // $account->{did_doc}{alsoKnownAs} // [],
        verificationMethods => $body->{verificationMethods} // {},
        services            => $body->{services} // {},
        rotationKeys        => $body->{rotationKeys} // [],
        signedAt            => iso8601(),
      },
    };
  });

  $registry->register('com.atproto.identity.submitPlcOperation', sub ($c, $endpoint) {
    my $body = $c->req->json || {};
    my $operation = $body->{operation} || {};
    my $account = $c->store->get_account_by_did($operation->{did} // q());
    if (!$account) {
      my (undef, $authed) = require_auth($c, audience => 'access', allow_refresh => 1);
      $account = $authed;
    }
    xrpc_error(404, 'DidNotFound', 'Account was not found') unless $account;

    my $did_doc = $account->{did_doc} || account_did_doc($c->app->settings, $account);
    $did_doc->{alsoKnownAs}         = $operation->{alsoKnownAs}         if exists $operation->{alsoKnownAs};
    $did_doc->{verificationMethod}  = $operation->{verificationMethods} if exists $operation->{verificationMethods};
    $did_doc->{service}             = $operation->{services}            if exists $operation->{services};
    $c->store->update_account($account->{did}, did_doc => $did_doc);
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
    my $updated = $c->store->update_account(
      $account->{did},
      handle  => $handle,
      did_doc => account_did_doc($c->app->settings, { %$account, handle => $handle }),
    );
    $c->store->append_event(
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
    my $nsid = $c->param('nsid') // q();
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
    my $patterns = [ $c->every_param('uriPatterns') ];
    xrpc_error(400, 'InvalidRequest', 'uriPatterns is required') unless @$patterns;
    my @labels = grep { _matches_patterns($_->{uri}, $patterns) } @{ _current_labels($c) };
    my $limit = $c->param('limit') // 50;
    $limit = 250 if $limit > 250;
    my @slice = @labels[0 .. (@labels < $limit ? $#labels : $limit - 1)];
    return {
      labels => \@slice,
    };
  });

  $registry->register('com.atproto.temp.fetchLabels', sub ($c, $endpoint) {
    my @labels = @{ _current_labels($c) };
    my $limit = $c->param('limit') // 50;
    $limit = 250 if $limit > 250;
    my @slice = @labels[0 .. (@labels < $limit ? $#labels : $limit - 1)];
    return {
      labels => \@slice,
    };
  });

  $registry->register('com.atproto.label.subscribeLabels', sub ($c, $endpoint) {
    my $cursor = int($c->param('cursor') // 0);
    my @labels = @{ _current_labels($c) };
    my $seq = $cursor + 1;
    if (@labels) {
      $c->send({ json => {
        seq    => $seq,
        labels => \@labels,
      }});
    }
    $c->finish(1000);
    return;
  });

  $registry->register('com.atproto.temp.addReservedHandle', sub ($c, $endpoint) {
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

sub _current_labels ($c) {
  my $src = service_did($c->app->settings);
  my @labels;
  for my $status (@{ $c->store->list_subject_statuses }) {
    next unless $status->{takedown} && $status->{takedown}{applied};
    my ($uri, $cid) = _subject_uri_and_cid($status->{subject});
    push @labels, {
      ver => 1,
      src => $src,
      uri => $uri,
      (defined $cid ? (cid => $cid) : ()),
      val => '!hide',
      cts => iso8601($status->{updated_at}),
    };
  }
  return \@labels;
}

sub _subject_uri_and_cid ($subject) {
  if (exists $subject->{uri}) {
    return ($subject->{uri}, $subject->{cid});
  }
  if (exists $subject->{did} && exists $subject->{cid}) {
    return ($subject->{recordUri} || ('at://' . $subject->{did}), $subject->{cid});
  }
  return ('at://' . ($subject->{did} // q()), undef);
}

sub _matches_patterns ($uri, $patterns) {
  for my $pattern (@$patterns) {
    return 1 if $pattern eq $uri;
    if ($pattern =~ /\A(.+)\*\z/ && index($uri, $1) == 0) {
      return 1;
    }
  }
  return 0;
}

1;
