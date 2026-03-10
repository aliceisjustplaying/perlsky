package ATProto::PDS::API::Builtins;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use Mojo::JSON qw(false true);

use ATProto::PDS::Identity qw(account_did_doc normalize_handle service_did service_did_doc);

our @EXPORT_OK = qw(register_builtin_handlers);

sub register_builtin_handlers ($registry, $app) {
  $registry->register('com.atproto.server.describeServer', sub ($c, $endpoint) {
    return {
      inviteCodeRequired        => false,
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
    my $handle = lc($c->param('handle') // '');
    if (my $account = $c->store->get_account_by_handle($handle)) {
      return { did => $account->{did} };
    }

    my $service_handle = lc($c->config_value('service_handle_domain', 'localhost'));
    die {
      status  => 404,
      error   => 'HandleNotFound',
      message => "No DID found for handle $handle",
    } unless $handle eq $service_handle;

    return {
      did => service_did($c->app->settings),
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
    my $payload = $c->req->json || {};
    my $handle = normalize_handle($payload->{handle} // '', $c->config_value('service_handle_domain', 'localhost'));
    my $service_handle = lc($c->config_value('service_handle_domain', 'localhost'));
    return {
      handle    => $handle // ($payload->{handle} // ''),
      available => (defined $handle && $handle ne '' && $handle ne $service_handle && !$c->store->get_account_by_handle($handle) ? true : false),
    };
  });
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
