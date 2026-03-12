package ATProto::PDS::API::Builtins;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use Mojo::JSON qw(false true);
use Mojo::URL;
use Mojo::UserAgent;

use ATProto::PDS::Identity qw(account_did_doc normalize_handle resolve_handle_to_did service_did service_did_doc);
use ATProto::PDS::PLC qw(is_plc_did refresh_plc_did_doc);

our @EXPORT_OK = qw(register_builtin_handlers);

sub register_builtin_handlers ($registry, $app) {
  $registry->register('com.atproto.server.describeServer', sub ($c, $endpoint) {
    return {
      inviteCodeRequired        => $c->config_value('invite_code_required', 0) ? true : false,
      phoneVerificationRequired => false,
      availableUserDomains      => [ $c->config_value('service_handle_domain', 'localhost') ],
      did                       => service_did($c->app->settings),
    };
  });

  $registry->register('com.atproto.identity.resolveDid', sub ($c, $endpoint) {
    my $did = $c->param('did') // '';
    my $service_did = service_did($c->app->settings);
    if (_same_did($did, $service_did)) {
      return {
        didDoc => service_did_doc($c->app->settings),
      };
    }

    my $account = $c->store->get_account_by_did(_canonical_did($did));
    if ($account) {
      return {
        didDoc => $account->{did_doc} || account_did_doc($c->app->settings, $account),
      };
    }

    if (my $did_doc = _resolve_remote_did_doc($c, $did)) {
      return {
        didDoc => $did_doc,
      };
    }

    die {
      status  => 404,
      error   => 'DidNotFound',
      message => "No DID document found for $did",
    };
  });

  $registry->register('com.atproto.identity.resolveHandle', sub ($c, $endpoint) {
    my $raw_handle = lc($c->param('handle') // q());
    my $service_handle = lc($c->config_value('service_handle_domain', 'localhost'));
    if ($raw_handle eq $service_handle) {
      return {
        did => service_did($c->app->settings),
      };
    }

    my $handle = normalize_handle($raw_handle, undef, { no_append => 1 });
    die {
      status  => 400,
      error   => 'InvalidHandle',
      message => 'Handle is invalid',
    } unless defined $handle && length $handle;
    if (my $did = _resolve_handle_to_did($c, $handle)) {
      return { did => $did };
    }

    die {
      status  => 404,
      error   => 'HandleNotFound',
      message => "No DID found for handle $handle",
    };
  });

  $registry->register('com.atproto.identity.resolveIdentity', sub ($c, $endpoint) {
    my $identifier = lc($c->param('identifier') // '');
    my $service_did = lc(service_did($c->app->settings));
    my $service_handle = lc($c->config_value('service_handle_domain', 'localhost'));
    if (my $account = $identifier =~ /^did:/ ? $c->store->get_account_by_did(_canonical_did($identifier)) : $c->store->get_account_by_handle($identifier)) {
      return {
        did    => $account->{did},
        handle => $account->{handle},
        didDoc => $account->{did_doc} || account_did_doc($c->app->settings, $account),
      };
    }
    if (my $remote = _resolve_remote_identity($c, $identifier)) {
      return $remote;
    }

    die {
      status  => 404,
      error   => ($identifier =~ /^did:/ ? 'DidNotFound' : 'HandleNotFound'),
      message => "No identity found for $identifier",
    } unless _same_did($identifier, $service_did) || $identifier eq $service_handle;

    return {
      did    => service_did($c->app->settings),
      handle => $c->config_value('service_handle_domain', 'localhost'),
      didDoc => service_did_doc($c->app->settings),
    };
  });

  $registry->register('com.atproto.temp.checkHandleAvailability', sub ($c, $endpoint) {
    my $handle = normalize_handle($c->param('handle') // '', $c->config_value('service_handle_domain', 'localhost'));
    my $service_handle = lc($c->config_value('service_handle_domain', 'localhost'));
    my $available = defined $handle
      && $handle ne ''
      && $handle ne $service_handle
      && !$c->store->get_account_by_handle($handle)
      && !$c->store->get_reserved_handle($handle);
    return {
      handle    => $handle // ($c->param('handle') // ''),
      available => $available ? true : false,
      result    => $available ? {} : {
        suggestions => [
          map {
            +{
              handle => $_,
              method => 'suffix',
            }
          } grep {
            !$c->store->get_account_by_handle($_) && !$c->store->get_reserved_handle($_)
          } map {
            my ($left, $rest) = split /\./, ($handle // q()), 2;
            $left . '-' . $_ . ($rest ? ".$rest" : q())
          } qw(perl perl5 pds)
        ],
      },
    };
  });
}

sub _resolve_handle_to_did ($c, $handle) {
  return undef unless defined $handle && length $handle;
  my $service_handle = lc($c->config_value('service_handle_domain', 'localhost'));
  if (my $account = $c->store->get_account_by_handle($handle)) {
    return $account->{did};
  }
  return service_did($c->app->settings) if $handle eq $service_handle;
  return resolve_handle_to_did($c->app->settings, $handle)
    // _resolve_remote_handle_via_appview($c, $handle);
}

sub _resolve_remote_identity ($c, $identifier) {
  if ($identifier =~ /^did:/) {
    my $did_doc = _resolve_remote_did_doc($c, $identifier) or return undef;
    return _identity_info_from_did_doc($c, $did_doc);
  }

  my $handle = normalize_handle($identifier, undef, { no_append => 1 });
  return undef unless defined $handle && length $handle;
  my $did = _resolve_handle_to_did($c, $handle) or return undef;
  my $did_doc = _resolve_remote_did_doc($c, $did) or return undef;
  return _identity_info_from_did_doc($c, $did_doc, $handle);
}

sub _resolve_remote_handle_via_appview ($c, $handle) {
  my $origin = $c->config_value('bsky_appview_url', 'https://api.bsky.app');
  return undef unless defined $origin && length $origin;

  state %ua_for_origin;
  my $ua = $ua_for_origin{$origin} //= do {
    my $client = Mojo::UserAgent->new(max_redirects => 0);
    $client->request_timeout(15);
    $client->inactivity_timeout(15);
    $client;
  };

  my $url = Mojo::URL->new($origin)->path('/xrpc/com.atproto.identity.resolveHandle')->query(handle => $handle);
  my $tx = eval { $ua->get($url) };
  return undef if $@ || !$tx;

  my $res = eval { $tx->result };
  return undef if $@ || !$res;
  return undef unless ($res->code // 0) == 200;
  my $json = $res->json;
  return undef unless ref($json) eq 'HASH' && defined($json->{did}) && length($json->{did});
  return $json->{did};
}

sub _identity_info_from_did_doc ($c, $did_doc, $fallback = undef) {
  return {
    did    => $did_doc->{id},
    handle => _validated_handle_for_did_doc($c, $did_doc, $fallback),
    didDoc => $did_doc,
  };
}

sub _validated_handle_for_did_doc ($c, $did_doc, $fallback = undef) {
  my $candidate = _did_doc_handle($did_doc) // $fallback;
  return 'handle.invalid' unless defined $candidate && length $candidate;
  my $resolved = _resolve_handle_to_did($c, $candidate);
  return 'handle.invalid' unless defined $resolved && _same_did($resolved, $did_doc->{id});
  return $candidate;
}

sub _did_doc_handle ($did_doc) {
  return undef unless ref($did_doc) eq 'HASH';
  for my $aka (@{ $did_doc->{alsoKnownAs} || [] }) {
    next unless defined $aka && $aka =~ /\Aat:\/\/(.+)\z/i;
    my $handle = normalize_handle($1, undef, { no_append => 1 });
    return $handle if defined $handle;
  }
  return undef;
}

sub _resolve_remote_did_doc ($c, $did) {
  if (is_plc_did($did) && defined($c->app->settings->{plc_url}) && length($c->app->settings->{plc_url})) {
    my $did_doc = eval { refresh_plc_did_doc($c->app->settings, $did) };
    return $did_doc unless $@;
    return undef;
  }

  return undef unless $did =~ /\Adid:web:/i;

  state %ua_for_origin;
  my $origin = lc(_relaxed_did($did));
  my $ua = $ua_for_origin{$origin} //= do {
    my $client = Mojo::UserAgent->new(max_redirects => 0);
    $client->request_timeout(15);
    $client->inactivity_timeout(15);
    $client;
  };

  my ($host, $path) = _web_did_origin_and_path($did);
  return undef unless defined $host && defined $path;
  my $scheme = $host =~ /\A(?:localhost|127\.0\.0\.1|\[::1\])(?::\d+)?\z/i ? 'http' : 'https';
  my $url = Mojo::URL->new("$scheme://$host");
  $url->path($path);

  my $tx = eval { $ua->get($url) };
  return undef if $@ || !$tx;

  my $res = eval { $tx->result };
  return undef if $@ || !$res;
  return undef unless ($res->code // 0) == 200;
  my $json = $res->json;
  return undef unless ref($json) eq 'HASH' && defined($json->{id}) && _same_did($json->{id}, $did);
  return $json;
}

sub _web_did_origin_and_path ($did) {
  return unless defined $did && $did =~ s/\Adid:web://i;
  my @parts = split /:/, $did;
  return unless @parts;

  my $host = shift @parts;
  $host =~ s/%3a/:/ig;
  if (@parts && $parts[0] =~ /\A\d+\z/ && $host !~ /:/) {
    $host .= ':' . shift @parts;
  }

  my $path = @parts
    ? '/' . join('/', map { s/%3A/:/igr } @parts) . '/did.json'
    : '/.well-known/did.json';
  return ($host, $path);
}

sub _same_did ($left, $right) {
  return lc(_relaxed_did($left)) eq lc(_relaxed_did($right));
}

sub _relaxed_did ($did) {
  $did //= '';
  $did =~ s/%3a/:/ig;
  return $did;
}

sub _canonical_did ($did) {
  $did = _relaxed_did($did);
  $did =~ s/^(did:web:[^:]+):(\d+)$/$1%3A$2/i;
  return $did;
}

1;
