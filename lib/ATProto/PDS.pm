package ATProto::PDS;

use v5.34;
use warnings;

use Mojo::Base 'Mojolicious', -signatures;
use Mojo::JSON ();
use Mojo::Path;
use Mojo::URL;
use ATProto::PDS::API::Admin qw(register_admin_handlers);
use ATProto::PDS::API::Builtins qw(register_builtin_handlers);
use ATProto::PDS::API::Misc qw(register_misc_handlers);
use ATProto::PDS::API::Repo qw(register_repo_handlers);
use ATProto::PDS::API::Registry;
use ATProto::PDS::API::Server qw(register_server_handlers);
use ATProto::PDS::API::Sync qw(register_sync_handlers);
use ATProto::PDS::Crawlers;
use ATProto::PDS::Identity qw(account_did_doc normalize_handle service_did);
use ATProto::PDS::LexiconCatalog qw(endpoint_catalog);
use ATProto::PDS::LexiconRegistry;
use ATProto::PDS::Metrics;
use ATProto::PDS::Repo::Manager;
use ATProto::PDS::ServiceProxy;
use ATProto::PDS::Store::SQLite;
use ATProto::PDS::XRPC::Dispatcher;
use File::Spec;

has project_root => '';
has settings     => sub { {} };

sub startup ($self) {
  my $config = $self->settings;
  my $root   = $self->project_root;
  my $public_url = Mojo::URL->new($config->{base_url} // 'http://127.0.0.1:7755');
  my $metrics = ATProto::PDS::Metrics->new(
    service => $config->{service_name} // 'perlsky',
  );
  my $crawler_notifier = ATProto::PDS::Crawlers->new(
    hostname     => ($config->{hostname} // lc($public_url->host // 'localhost')),
    crawlers     => $config->{crawlers} // [],
    min_interval => $config->{crawler_notify_interval} // (20 * 60),
    metrics      => $metrics,
  );

  $self->secrets([$config->{jwt_secret} // 'perlsky-dev-secret']);
  $self->hook(before_dispatch => sub ($c) {
    return unless _cors_path($c->req->url->path);

    _apply_cors_headers($c);
    return unless $c->req->method eq 'OPTIONS';

    $c->res->code(204);
    $c->rendered(204);
  });
  $self->helper(metrics => sub { $metrics });
  $self->helper(api_registry => sub { state $registry = ATProto::PDS::API::Registry->new });
  $self->helper(endpoint_catalog => sub ($c) { endpoint_catalog($root) });
  $self->helper(config_value => sub ($c, $key, $default = undef) { $c->app->settings->{$key} // $default });
  $self->helper(lexicons => sub ($c) { state $registry = ATProto::PDS::LexiconRegistry->new(root => $root) });
  $self->helper(store => sub ($c) {
    state $store = ATProto::PDS::Store::SQLite->new(
      path => $c->app->settings->{db_path} || File::Spec->catfile($root, 'data', 'runtime', 'perlsky.sqlite'),
      metrics => $metrics,
    )->bootstrap;
  });
  $self->helper(crawler_notifier => sub ($c) {
    state $notifier = do {
      $crawler_notifier->{store} = $c->store;
      $crawler_notifier;
    };
  });
  $self->helper(append_event => sub ($c, %args) {
    my $seq = $c->store->append_event(%args);
    $c->crawler_notifier->notify_of_update(last_seq => $seq);
    return $seq;
  });
  $self->helper(subscription_send => sub ($c, %args) {
    my $nsid      = $args{nsid}      // $c->stash('nsid') // 'unknown';
    my $frame_type = $args{frame_type} // 'message';
    my $encoding  = exists $args{binary} ? 'binary' : 'json';
    my $payload_size = exists $args{binary}
      ? length($args{binary} // q())
      : length(Mojo::JSON::encode_json($args{json} // {}));

    $c->app->metrics->increment_counter('perlsky_subscription_frames_total', 1, {
      nsid      => $nsid,
      frame_type => $frame_type,
      encoding  => $encoding,
    });
    $c->app->metrics->increment_counter('perlsky_subscription_bytes_total', $payload_size, {
      nsid     => $nsid,
      encoding => $encoding,
    });

    return exists $args{binary}
      ? $c->send({ binary => $args{binary} })
      : $c->send({ json => $args{json} });
  });
  $self->helper(observe_blob_ingress => sub ($c, $mime_type, $bytes) {
    $c->app->metrics->increment_counter('perlsky_blob_ingress_bytes_total', $bytes, {
      mime_type => $mime_type || 'application/octet-stream',
    });
  });
  $self->helper(observe_blob_egress => sub ($c, $mime_type, $bytes) {
    $c->app->metrics->increment_counter('perlsky_blob_egress_bytes_total', $bytes, {
      mime_type => $mime_type || 'application/octet-stream',
    });
  });
  $self->helper(repo_manager => sub ($c) {
    state $manager = ATProto::PDS::Repo::Manager->new(
      store            => $c->store,
      crawler_notifier => $c->crawler_notifier,
    );
  });
  $self->helper(service_proxy => sub ($c) {
    state $proxy = ATProto::PDS::ServiceProxy->new(
      settings => $c->app->settings,
    );
  });

  my $routes = $self->routes;
  $routes->get('/')->to(cb => sub ($c) {
    $c->render(json => {
      service   => 'perlsky',
      status    => 'booting',
      did       => service_did($c->app->settings),
      endpoints => scalar @{ $c->endpoint_catalog },
    });
  });

  my $health = sub ($c) {
    $c->render(json => {
      ok        => Mojo::JSON->true,
      service   => 'perlsky',
      endpoints => scalar @{ endpoint_catalog($root) },
    });
  };
  $routes->get('/_health')->to(cb => $health);
  $routes->get('/xrpc/_health')->to(cb => $health);

  $routes->get('/metrics')->to(cb => sub ($c) {
    my $token = $c->config_value('metrics_token');
    if (defined $token && length $token) {
      my $auth = $c->req->headers->authorization // q();
      return $c->render(
        status => 401,
        text   => 'metrics authorization required',
      ) unless $auth eq "Bearer $token";
    }

    $c->res->headers->content_type('text/plain; version=0.0.4; charset=utf-8');
    $c->render(data => $c->app->metrics->render_prometheus);
  });

  $routes->get('/_allow-cert')->to(cb => sub ($c) {
    my $domain = lc($c->param('domain') // q());
    my $suffix = lc($c->config_value('service_handle_domain', 'localhost'));
    my $hostname = lc($c->config_value('hostname', $suffix));
    my $allowed = length($domain)
      && (
        $domain eq $hostname
        || defined normalize_handle($domain, $suffix, { no_append => 1 })
      );

    return $c->render(status => 403, text => 'forbidden') unless $allowed;
    $c->render(text => 'ok');
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

  $routes->get('/.well-known/atproto-did')->to(cb => sub ($c) {
    my $host = lc($c->req->url->to_abs->host // ($c->req->headers->host // q()));
    $host =~ s/:\d+\z//;
    my $account = $c->store->get_account_by_handle($host);
    return $c->render(status => 404, text => 'handle not found') unless $account;

    $c->res->headers->content_type('text/plain; charset=utf-8');
    $c->render(data => $account->{did});
  });

  $routes->get('/users/:account_id/did.json')->to(cb => sub ($c) {
    my $match = $c->store->get_account_by_id($c->stash('account_id'));
    return $c->render(status => 404, json => { error => 'DidNotFound' }) unless $match;
    $c->render(json => account_did_doc($c->app->settings, $match));
  });

  register_builtin_handlers($self->api_registry, $self);
  register_server_handlers($self->api_registry, $self);
  register_misc_handlers($self->api_registry, $self);
  register_repo_handlers($self->api_registry, $self);
  register_sync_handlers($self->api_registry, $self);
  register_admin_handlers($self->api_registry, $self);
  ATProto::PDS::XRPC::Dispatcher->new(
    app     => $self,
    routes  => $routes,
    catalog => endpoint_catalog($root),
  )->register_routes;
}

sub _cors_path ($path) {
  my $text = ref($path) ? $path->to_string : ($path // q());
  return 1 if $text =~ m{\A/xrpc(?:/|\z)};
  return 1 if $text eq '/.well-known/did.json';
  return 1 if $text eq '/.well-known/atproto-did';
  return 0;
}

sub _apply_cors_headers ($c) {
  my $headers = $c->res->headers;
  my $allow_headers = _allowed_cors_headers($c);
  $headers->header('Access-Control-Allow-Origin'  => '*');
  $headers->header('Access-Control-Allow-Methods' => 'GET, POST, OPTIONS');
  $headers->header('Access-Control-Allow-Headers' => $allow_headers);
  $headers->header('Access-Control-Expose-Headers' => 'WWW-Authenticate, DPoP-Nonce');
  $headers->header('Access-Control-Max-Age'       => 86400);
  $headers->header('Vary'                         => 'Origin, Access-Control-Request-Headers');
}

sub _allowed_cors_headers ($c) {
  my @defaults = qw(Authorization Content-Type DPoP Atproto-Accept-Labelers Atproto-Proxy);
  my @requested = split /\s*,\s*/, ($c->req->headers->header('Access-Control-Request-Headers') // q());
  my %seen;
  return join(', ', grep { length && !$seen{lc $_}++ } (@requested, @defaults));
}

1;
