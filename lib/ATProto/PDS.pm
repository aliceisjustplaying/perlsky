package ATProto::PDS;

use v5.34;
use warnings;

use Mojo::Base 'Mojolicious', -signatures;
use Mojo::JSON ();
use ATProto::PDS::API::Builtins qw(register_builtin_handlers);
use ATProto::PDS::API::Repo qw(register_repo_handlers);
use ATProto::PDS::API::Registry;
use ATProto::PDS::API::Server qw(register_server_handlers);
use ATProto::PDS::API::Sync qw(register_sync_handlers);
use ATProto::PDS::Identity qw(account_did_doc service_did);
use ATProto::PDS::LexiconCatalog qw(endpoint_catalog);
use ATProto::PDS::LexiconRegistry;
use ATProto::PDS::Repo::Manager;
use ATProto::PDS::Store::SQLite;
use ATProto::PDS::XRPC::Dispatcher;
use File::Spec;

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
  $self->helper(store => sub ($c) {
    state $store = ATProto::PDS::Store::SQLite->new(
      path => $c->app->settings->{db_path} || File::Spec->catfile($root, 'data', 'runtime', 'perlds.sqlite'),
    )->bootstrap;
  });
  $self->helper(repo_manager => sub ($c) {
    state $manager = ATProto::PDS::Repo::Manager->new(store => $c->store);
  });

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

  $routes->get('/users/:account_id/did.json')->to(cb => sub ($c) {
    my $match = $c->store->get_account_by_id($c->stash('account_id'));
    return $c->render(status => 404, json => { error => 'DidNotFound' }) unless $match;
    $c->render(json => account_did_doc($c->app->settings, $match));
  });

  register_builtin_handlers($self->api_registry, $self);
  register_server_handlers($self->api_registry, $self);
  register_repo_handlers($self->api_registry, $self);
  register_sync_handlers($self->api_registry, $self);
  ATProto::PDS::XRPC::Dispatcher->new(
    app     => $self,
    routes  => $routes,
    catalog => endpoint_catalog($root),
  )->register_routes;
}

1;
