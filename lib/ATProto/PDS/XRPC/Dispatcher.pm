package ATProto::PDS::XRPC::Dispatcher;

use v5.34;
use warnings;

use Mojo::Base -base, -signatures;

has app     => undef;
has routes  => undef;
has catalog => sub { [] };

sub register_routes ($self) {
  my %by_id = map { $_->{id} => $_ } @{ $self->catalog };

  $self->routes->websocket('/xrpc/*nsid')->to(cb => sub ($c) {
    my $endpoint = $by_id{ $c->stash('nsid') // q() };
    return $c->finish(1008) unless $endpoint;

    if ($endpoint->{type} ne 'subscription') {
      $c->send({ json => {
        error   => 'MethodNotAllowed',
        message => "$endpoint->{id} is not a subscription endpoint",
      }});
      return $c->finish(1008);
    }

    my $handler = $c->app->api_registry->handler_for($endpoint->{id});
    if ($handler) {
      return $handler->($c, $endpoint);
    }

    $c->send({ json => {
      error   => 'NotImplemented',
      message => "No subscription handler registered for $endpoint->{id}",
      nsid    => $endpoint->{id},
    }});
    $c->finish(1000);
  });

  $self->routes->any('/xrpc/*nsid')->to(cb => sub ($c) {
    my $endpoint = $by_id{ $c->stash('nsid') // q() };
    unless ($endpoint) {
      return $c->render(
        status => 404,
        json   => {
          error   => 'UnknownMethod',
          message => 'Unknown XRPC method',
        },
      );
    }

    if ($endpoint->{type} eq 'subscription') {
      return $c->render(
        status => 426,
        json   => {
          error   => 'UpgradeRequired',
          message => "$endpoint->{id} requires a websocket upgrade",
        },
      );
    }

    if ($endpoint->{type} eq 'query' && $c->req->method ne 'GET') {
      return $c->render(
        status => 405,
        json   => {
          error   => 'MethodNotAllowed',
          message => "$endpoint->{id} expects GET",
        },
      );
    }

    if ($endpoint->{type} eq 'procedure' && $c->req->method ne 'POST') {
      return $c->render(
        status => 405,
        json   => {
          error   => 'MethodNotAllowed',
          message => "$endpoint->{id} expects POST",
        },
      );
    }

    my $handler = $c->app->api_registry->handler_for($endpoint->{id});
    unless ($handler) {
      return $c->render(
        status => 501,
        json   => {
          error   => 'NotImplemented',
          message => "No handler registered for $endpoint->{id}",
          nsid    => $endpoint->{id},
          type    => $endpoint->{type},
        },
      );
    }

    my $result = eval { $handler->($c, $endpoint) };
    if (my $err = $@) {
      if (ref($err) eq 'HASH' && $err->{error}) {
        return $c->render(
          status => $err->{status} // 400,
          json   => {
            error   => $err->{error},
            message => $err->{message} // $err->{error},
          },
        );
      }
      die $err;
    }

    return unless defined $result;
    return $c->render(json => $result);
  });
}

1;
