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
      $c->app->metrics->increment_counter('perlsky_subscription_closes_total', 1, {
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
    $c->app->metrics->increment_counter('perlsky_subscription_connections_total', 1, $labels);
    $c->app->metrics->add_gauge('perlsky_subscription_active', 1, $labels);
    $c->on(finish => sub ($c, $code, $reason = undef) {
      $c->app->metrics->add_gauge('perlsky_subscription_active', -1, $labels);
      $c->app->metrics->increment_counter('perlsky_subscription_closes_total', 1, {
        %{$labels},
        code => defined($code) ? $code : 0,
      });
      $c->app->metrics->observe_histogram(
        'perlsky_subscription_duration_seconds',
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
    my $nsid    = $c->stash('nsid') // q();
    my $finish_metrics = sub ($status, $endpoint_type = 'unknown', $nsid = $c->stash('nsid') // 'unknown') {
      my $labels = {
        method       => $method,
        nsid         => $nsid,
        endpoint_type => $endpoint_type,
        status       => $status,
      };
      $c->app->metrics->increment_counter('perlsky_xrpc_requests_total', 1, $labels);
      $c->app->metrics->observe_histogram(
        'perlsky_xrpc_request_duration_seconds',
        time - $started,
        $labels,
      );
    };
    my $observe_error = sub ($status, $error, $endpoint_type = 'unknown', $error_nsid = $c->stash('nsid') // 'unknown') {
      $c->app->metrics->increment_counter('perlsky_xrpc_errors_total', 1, {
        method        => $method,
        nsid          => $error_nsid,
        endpoint_type => $endpoint_type,
        status        => $status,
        error         => $error,
      });
    };
    my $render_error = sub ($status, $error, $message, $endpoint_type = 'unknown', $error_nsid = $c->stash('nsid') // 'unknown') {
      $finish_metrics->($status, $endpoint_type, $error_nsid);
      $observe_error->($status, $error, $endpoint_type, $error_nsid);
      return $c->render(
        status => $status,
        json   => {
          error   => $error,
          message => $message,
        },
      );
    };
    my $render_internal_error = sub ($err, $endpoint_type = 'unknown', $error_nsid = $c->stash('nsid') // 'unknown') {
      my $message = "$err";
      chomp $message;
      $c->app->log->error("Unhandled XRPC exception for $error_nsid: $message");
      $c->app->metrics->increment_counter('perlsky_xrpc_unhandled_exceptions_total', 1, {
        method        => $method,
        nsid          => $error_nsid,
        endpoint_type => $endpoint_type,
      });
      return $render_error->(500, 'InternalServerError', 'Internal server error', $endpoint_type, $error_nsid);
    };

    my $endpoint = $by_id{$nsid};
    unless ($endpoint) {
      my $proxied_status = eval { $c->service_proxy->proxy_xrpc_request($c, $nsid) };
      if (my $err = $@) {
        if (ref($err) eq 'HASH' && $err->{error}) {
          return $render_error->($err->{status} // 400, $err->{error}, $err->{message} // $err->{error}, 'proxy', $nsid);
        }
        return $render_internal_error->($err, 'proxy', $nsid);
      }

      if (defined $proxied_status) {
        $finish_metrics->($proxied_status, 'proxy', $nsid);
        return;
      }

      return $render_error->(404, 'UnknownMethod', 'Unknown XRPC method');
    }

    if ($endpoint->{type} eq 'subscription') {
      return $render_error->(426, 'UpgradeRequired', "$endpoint->{id} requires a websocket upgrade", $endpoint->{type}, $endpoint->{id});
    }

    if ($endpoint->{type} eq 'query' && $c->req->method ne 'GET') {
      return $render_error->(405, 'MethodNotAllowed', "$endpoint->{id} expects GET", $endpoint->{type}, $endpoint->{id});
    }

    if ($endpoint->{type} eq 'procedure' && $c->req->method ne 'POST') {
      return $render_error->(405, 'MethodNotAllowed', "$endpoint->{id} expects POST", $endpoint->{type}, $endpoint->{id});
    }

    my $handler = $c->app->api_registry->handler_for($endpoint->{id});
    unless ($handler) {
      $finish_metrics->(501, $endpoint->{type}, $endpoint->{id});
      $observe_error->(501, 'NotImplemented', $endpoint->{type}, $endpoint->{id});
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
        return $render_error->($err->{status} // 400, $err->{error}, $err->{message} // $err->{error}, $endpoint->{type}, $endpoint->{id});
      }
      return $render_internal_error->($err, $endpoint->{type}, $endpoint->{id});
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
