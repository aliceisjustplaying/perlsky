package ATProto::PDS;

use v5.34;
use warnings;

use Mojo::Base 'Mojolicious', -signatures;
use Mojo::JSON ();
use ATProto::PDS::API::Registry;
use ATProto::PDS::LexiconCatalog qw(endpoint_catalog);

has project_root => '';
has settings     => sub { {} };

sub startup ($self) {
  my $config = $self->settings;
  my $root   = $self->project_root;

  $self->secrets([$config->{jwt_secret} // 'perlds-dev-secret']);
  $self->helper(api_registry => sub { state $registry = ATProto::PDS::API::Registry->new });
  $self->helper(config_value => sub ($c, $key, $default = undef) { $c->app->settings->{$key} // $default });

  my $routes = $self->routes;
  $routes->get('/_health')->to(cb => sub ($c) {
    $c->render(json => {
      ok        => Mojo::JSON->true,
      service   => 'perlds',
      endpoints => scalar @{ endpoint_catalog($root) },
    });
  });

  for my $endpoint (@{ endpoint_catalog($root) }) {
    my $route = $endpoint->{type} eq 'query'
      ? $routes->get($endpoint->{path})
      : $routes->post($endpoint->{path});

    $route->to(cb => sub ($c) {
      my $handler = $c->app->api_registry->handler_for($endpoint->{id});
      return $handler->($c, $endpoint) if $handler;

      $c->render(
        status => 501,
        json   => {
          error   => 'NotYetImplemented',
          message => "No handler registered for $endpoint->{id}",
          nsid    => $endpoint->{id},
        },
      );
    });
  }
}

1;
