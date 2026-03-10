package ATProto::PDS::XRPC::Dispatcher;

use v5.34;
use warnings;

use Mojo::Base -base, -signatures;
use Time::HiRes qw(time);

has app     => undef;
has routes  => undef;
has catalog => sub { [] };

sub register_routes ($self) {
  my %by_id = map { $_->{id} => $_ } @{ $self->catalog };

  $self->routes->websocket('/xrpc/*nsid')->to(cb => sub ($c) {
    my $started = time;
    my $nsid = $c->stash('nsid') // q();
    my $endpoint = $by_id{ $c->stash('nsid') // q() };
    return $c->finish(1008) unless $endpoint;

    if ($endpoint->{type} ne 'subscription') {
      $c->app->metrics->increment_counter('perlds_subscription_closes_total', 1, {
        nsid => $endpoint->{id},
        code => 1008,
      });
      $c->subscription_send(json => {
        error   => 'MethodNotAllowed',
        message => "$endpoint->{id} is not a subscription endpoint",
      }, frame_type => 'error', nsid => $endpoint->{id});
      return $c->finish(1008);
    }

    my $labels = { nsid => $endpoint->{id} };
    $c->app->metrics->increment_counter('perlds_subscription_connections_total', 1, $labels);
    $c->app->metrics->add_gauge('perlds_subscription_active', 1, $labels);
    $c->on(finish => sub ($c, $code, $reason = undef) {
      $c->app->metrics->add_gauge('perlds_subscription_active', -1, $labels);
      $c->app->metrics->increment_counter('perlds_subscription_closes_total', 1, {
        %{$labels},
        code => defined($code) ? $code : 0,
      });
      $c->app->metrics->observe_histogram(
        'perlds_subscription_duration_seconds',
        time - $started,
        $labels,
      );
    });

    my $handler = $c->app->api_registry->handler_for($endpoint->{id});
    if ($handler) {
      return $handler->($c, $endpoint);
    }

    $c->subscription_send(json => {
      error   => 'NotImplemented',
      message => "No subscription handler registered for $endpoint->{id}",
      nsid    => $endpoint->{id},
    }, frame_type => 'error', nsid => $endpoint->{id});
    $c->finish(1000);
  });

  $self->routes->any('/xrpc/*nsid')->to(cb => sub ($c) {
    my $started = time;
    my $method  = $c->req->method;
    my $finish_metrics = sub ($status, $endpoint_type = 'unknown', $nsid = $c->stash('nsid') // 'unknown') {
      my $labels = {
        method       => $method,
        nsid         => $nsid,
        endpoint_type => $endpoint_type,
        status       => $status,
      };
      $c->app->metrics->increment_counter('perlds_xrpc_requests_total', 1, $labels);
      $c->app->metrics->observe_histogram(
        'perlds_xrpc_request_duration_seconds',
        time - $started,
        $labels,
      );
    };

    my $endpoint = $by_id{ $c->stash('nsid') // q() };
    unless ($endpoint) {
      $finish_metrics->(404);
      return $c->render(
        status => 404,
        json   => {
          error   => 'UnknownMethod',
          message => 'Unknown XRPC method',
        },
      );
    }

    if ($endpoint->{type} eq 'subscription') {
      $finish_metrics->(426, $endpoint->{type}, $endpoint->{id});
      return $c->render(
        status => 426,
        json   => {
          error   => 'UpgradeRequired',
          message => "$endpoint->{id} requires a websocket upgrade",
        },
      );
    }

    if ($endpoint->{type} eq 'query' && $c->req->method ne 'GET') {
      $finish_metrics->(405, $endpoint->{type}, $endpoint->{id});
      return $c->render(
        status => 405,
        json   => {
          error   => 'MethodNotAllowed',
          message => "$endpoint->{id} expects GET",
        },
      );
    }

    if ($endpoint->{type} eq 'procedure' && $c->req->method ne 'POST') {
      $finish_metrics->(405, $endpoint->{type}, $endpoint->{id});
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
      $finish_metrics->(501, $endpoint->{type}, $endpoint->{id});
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
        $finish_metrics->($err->{status} // 400, $endpoint->{type}, $endpoint->{id});
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

    if (!defined $result) {
      my $status = $c->res->code || 200;
      $finish_metrics->($status, $endpoint->{type}, $endpoint->{id});
      return;
    }
    $finish_metrics->(200, $endpoint->{type}, $endpoint->{id});
    return $c->render(json => $result);
  });
}

1;
