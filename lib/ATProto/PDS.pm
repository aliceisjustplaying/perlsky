package ATProto::PDS;

use v5.34;
use warnings;

use Mojo::Base 'Mojolicious', -signatures;
use Mojo::JSON ();
use ATProto::PDS::API::Builtins qw(register_builtin_handlers);
use ATProto::PDS::API::Registry;
use ATProto::PDS::Identity qw(service_did);
use ATProto::PDS::LexiconCatalog qw(endpoint_catalog);
use ATProto::PDS::LexiconRegistry;
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
  $self->helper(lexicons => sub ($c) { state $registry = ATProto::PDS::LexiconRegistry->new(root => $root) });

  my $routes = $self->routes;
  $routes->get('/')->to(cb => sub ($c) {
    $c->render(json => {
      service   => 'perlds',
      status    => 'booting',
      did       => service_did($c->app->settings),
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

  $routes->get('/.well-known/did.json')->to(cb => sub ($c) {
    $c->render(json => {
      '@context' => ['https://www.w3.org/ns/did/v1'],
      id         => service_did($c->app->settings),
      service    => [{
        id              => service_did($c->app->settings) . '#atproto_pds',
        type            => 'AtprotoPersonalDataServer',
        serviceEndpoint => $c->config_value('base_url', 'http://127.0.0.1:7755'),
      }],
    });
  });

  register_builtin_handlers($self->api_registry, $self);
  ATProto::PDS::XRPC::Dispatcher->new(
    app     => $self,
    routes  => $routes,
    catalog => endpoint_catalog($root),
  )->register_routes;
}

1;
