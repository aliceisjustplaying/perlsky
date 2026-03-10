package ATProto::PDS;

use v5.34;
use warnings;

use Mojo::Base 'Mojolicious', -signatures;
use Mojo::JSON ();
use ATProto::PDS::API::Registry;
use ATProto::PDS::LexiconCatalog qw(endpoint_catalog);
use ATProto::PDS::XRPC::Dispatcher;

has project_root => '';
has settings     => sub { {} };

sub startup ($self) {
  my $config = $self->settings;
  my $root   = $self->project_root;

  $self->secrets([$config->{jwt_secret} // 'perlds-dev-secret']);
  $self->helper(api_registry => sub { state $registry = ATProto::PDS::API::Registry->new });
  $self->helper(endpoint_catalog => sub ($c) { endpoint_catalog($root) });
  $self->helper(config_value => sub ($c, $key, $default = undef) { $c->app->settings->{$key} // $default });

  my $routes = $self->routes;
  $routes->get('/')->to(cb => sub ($c) {
    $c->render(json => {
      service   => 'perlds',
      status    => 'booting',
      endpoints => scalar @{ $c->endpoint_catalog },
    });
  });

  $routes->get('/_health')->to(cb => sub ($c) {
    $c->render(json => {
      ok        => Mojo::JSON->true,
      service   => 'perlds',
      endpoints => scalar @{ endpoint_catalog($root) },
    });
  });

  $self->_register_builtin_handlers;
  ATProto::PDS::XRPC::Dispatcher->new(
    app     => $self,
    routes  => $routes,
    catalog => endpoint_catalog($root),
  )->register_routes;
}

sub _register_builtin_handlers ($self) {
  $self->api_registry->register('com.atproto.server.describeServer', sub ($c, $endpoint) {
    my $domain = $c->config_value('service_handle_domain', 'localhost');
    my $base   = $c->config_value('base_url', 'http://127.0.0.1:7755');
    (my $host = $base) =~ s{\Ahttps?://}{};
    $host =~ s{/.*\z}{};

    $c->render(json => {
      inviteCodeRequired        => Mojo::JSON->false,
      phoneVerificationRequired => Mojo::JSON->false,
      availableUserDomains      => [$domain],
      did                       => "did:web:$host",
    });
  });
}

1;
