package ATProto::PDS::XRPC::Dispatcher;

use v5.34;
use warnings;

use Mojo::Base -base, -signatures;
use Mojo::JSON ();

has app     => undef;
has routes  => undef;
has catalog => sub { [] };

sub register_routes ($self) {
  for my $endpoint (@{ $self->catalog }) {
    if ($endpoint->{type} eq 'subscription') {
      $self->routes->websocket($endpoint->{path})->to(cb => sub ($c) {
        my $handler = $c->app->api_registry->handler_for($endpoint->{id});
        return $handler->($c, $endpoint) if $handler;

        $c->send({ json => {
          error   => 'NotYetImplemented',
          message => "No subscription handler registered for $endpoint->{id}",
          nsid    => $endpoint->{id},
        }});
        $c->finish(1000);
      });
      next;
    }

    my $route = $endpoint->{type} eq 'query'
      ? $self->routes->get($endpoint->{path})
      : $self->routes->post($endpoint->{path});

    $route->to(cb => sub ($c) {
      my $handler = $c->app->api_registry->handler_for($endpoint->{id});
      return $handler->($c, $endpoint) if $handler;

      $c->render(
        status => 501,
        json   => {
          error   => 'NotYetImplemented',
          message => "No handler registered for $endpoint->{id}",
          nsid    => $endpoint->{id},
          type    => $endpoint->{type},
        },
      );
    });
  }
}

1;
