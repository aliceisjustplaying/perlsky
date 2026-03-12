package ATProto::PDS::API::Builtins;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use Mojo::JSON qw(false true);
use Mojo::URL;
use Mojo::UserAgent;

use ATProto::PDS::Identity qw(account_did_doc normalize_handle service_did service_did_doc);

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
    die {
      status  => 404,
      error   => 'DidNotFound',
      message => "No DID document found for $did",
    } unless $account;

    return {
      didDoc => $account->{did_doc} || account_did_doc($c->app->settings, $account),
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
    if (my $account = $c->store->get_account_by_handle($handle)) {
      return { did => $account->{did} };
    }

    if ($handle eq $service_handle) {
      return {
        did => service_did($c->app->settings),
      };
    }

    if (my $did = _resolve_remote_handle_via_appview($c, $handle)) {
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

  my $res = $tx->result;
  return undef unless ($res->code // 0) == 200;
  my $json = $res->json;
  return undef unless ref($json) eq 'HASH' && defined($json->{did}) && length($json->{did});
  return $json->{did};
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
