package ATProto::PDS::API::Sync;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use JSON::PP ();

our @EXPORT_OK = qw(register_sync_handlers);

sub register_sync_handlers ($registry, $app) {
  $registry->register('com.atproto.sync.getLatestCommit', sub ($c, $endpoint) {
    my $account = _account_for_did($c, $c->param('did') // q());
    _xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless $account;
    my $head = $c->store->get_repo_head($account->{did});
    _xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless $head;
    return {
      cid => $head->{commit_cid},
      rev => $head->{rev},
    };
  });

  $registry->register('com.atproto.sync.getRepoStatus', sub ($c, $endpoint) {
    my $account = _account_for_did($c, $c->param('did') // q());
    _xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless $account;
    return {
      did    => $account->{did},
      active => defined($account->{deactivated_at}) ? JSON::PP::false : JSON::PP::true,
      (defined($account->{repo_rev}) ? (rev => $account->{repo_rev}) : ()),
      (defined($account->{deactivated_at}) ? (status => 'deactivated') : ()),
    };
  });

  $registry->register('com.atproto.sync.getRepo', sub ($c, $endpoint) {
    my $account = _account_for_did($c, $c->param('did') // q());
    _xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless $account;
    my $car = $c->store->repo_car($account->{did});
    _xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless defined $car;
    $c->res->headers->content_type('application/vnd.ipld.car');
    $c->render(data => $car);
    return;
  });

  $registry->register('com.atproto.sync.getRecord', sub ($c, $endpoint) {
    my $account = _account_for_did($c, $c->param('did') // q());
    _xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless $account;
    my $record = $c->store->get_record($account->{did}, $c->param('collection'), $c->param('rkey'));
    _xrpc_error(404, 'RecordNotFound', 'Record was not found') unless $record;
    my $car = $c->store->repo_car($account->{did});
    _xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless defined $car;
    $c->res->headers->content_type('application/vnd.ipld.car');
    $c->render(data => $car);
    return;
  });

  $registry->register('com.atproto.sync.listRepos', sub ($c, $endpoint) {
    my $page = $c->store->list_repos(
      limit  => $c->param('limit') // 500,
      cursor => $c->param('cursor'),
    );
    return {
      (defined $page->{cursor} ? (cursor => $page->{cursor}) : ()),
      repos => $page->{items},
    };
  });

  $registry->register('com.atproto.sync.listBlobs', sub ($c, $endpoint) {
    my $account = _account_for_did($c, $c->param('did') // q());
    _xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless $account;
    my $page = $c->store->list_blobs_by_did(
      $account->{did},
      limit  => $c->param('limit') // 500,
      cursor => $c->param('cursor'),
    );
    return {
      (defined $page->{cursor} ? (cursor => $page->{cursor}) : ()),
      cids => [ map { $_->{cid} } @{ $page->{items} } ],
    };
  });
}

sub _account_for_did ($c, $did) {
  my $account = $c->store->get_account_by_did($did);
  return $account if $account;
  my $target = lc($did // q());
  $target =~ s/%3a/:/ig;
  for my $row (@{ $c->store->list_accounts }) {
    my $candidate = lc($row->{did} // q());
    $candidate =~ s/%3a/:/ig;
    return $row if $candidate eq $target;
  }
  return undef;
}

sub _xrpc_error ($status, $error, $message) {
  die {
    status  => $status,
    error   => $error,
    message => $message,
  };
}

1;
