package ATProto::PDS::API::Sync;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use JSON::PP ();

use ATProto::PDS::API::Util qw(iso8601 resolve_did_account xrpc_error);
use ATProto::PDS::Identity qw(service_host);
use ATProto::PDS::Repo::CAR qw(write_car);
use ATProto::PDS::Repo::CID;

our @EXPORT_OK = qw(register_sync_handlers);

sub register_sync_handlers ($registry, $app) {
  $registry->register('com.atproto.sync.getLatestCommit', sub ($c, $endpoint) {
    my $account = resolve_did_account($c, $c->param('did') // q());
    xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless $account;
    my $head = $c->store->get_repo_head($account->{did});
    xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless $head;
    return {
      cid => $head->{commit_cid},
      rev => $head->{rev},
    };
  });

  $registry->register('com.atproto.sync.getHead', sub ($c, $endpoint) {
    my $account = resolve_did_account($c, $c->param('did') // q());
    xrpc_error(404, 'HeadNotFound', 'Repository head was not found') unless $account;
    my $head = $c->store->get_repo_head($account->{did});
    xrpc_error(404, 'HeadNotFound', 'Repository head was not found') unless $head;
    return {
      root => $head->{commit_cid},
    };
  });

  $registry->register('com.atproto.sync.getRepoStatus', sub ($c, $endpoint) {
    my $account = resolve_did_account($c, $c->param('did') // q());
    xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless $account;
    return {
      did    => $account->{did},
      active => defined($account->{deactivated_at}) ? JSON::PP::false : JSON::PP::true,
      (defined($account->{repo_rev}) ? (rev => $account->{repo_rev}) : ()),
      (defined($account->{deactivated_at}) ? (status => 'deactivated') : ()),
      (defined($account->{deleted_at}) ? (status => 'deleted') : ()),
    };
  });

  $registry->register('com.atproto.sync.getRepo', sub ($c, $endpoint) {
    my $account = resolve_did_account($c, $c->param('did') // q());
    xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless $account;
    my $car = $c->store->repo_car($account->{did});
    xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless defined $car;
    $c->res->headers->content_type('application/vnd.ipld.car');
    $c->render(data => $car);
    return;
  });

  $registry->register('com.atproto.sync.getCheckout', sub ($c, $endpoint) {
    my $account = resolve_did_account($c, $c->param('did') // q());
    xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless $account;
    my $car = $c->store->repo_car($account->{did});
    xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless defined $car;
    $c->res->headers->content_type('application/vnd.ipld.car');
    $c->render(data => $car);
    return;
  });

  $registry->register('com.atproto.sync.getRecord', sub ($c, $endpoint) {
    my $account = resolve_did_account($c, $c->param('did') // q());
    xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless $account;
    my $record = $c->store->get_record($account->{did}, $c->param('collection'), $c->param('rkey'));
    xrpc_error(404, 'RecordNotFound', 'Record was not found') unless $record;
    my $car = $c->store->repo_car($account->{did});
    xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless defined $car;
    $c->res->headers->content_type('application/vnd.ipld.car');
    $c->render(data => $car);
    return;
  });

  $registry->register('com.atproto.sync.getBlocks', sub ($c, $endpoint) {
    my $account = resolve_did_account($c, $c->param('did') // q());
    xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless $account;
    my @cids = _flatten_params($c->every_param('cids'));
    xrpc_error(400, 'InvalidRequest', 'At least one CID is required') unless @cids;
    my $rows = $c->store->get_blocks(\@cids);
    my %found = map { $_->{cid} => $_ } @$rows;
    for my $cid (@cids) {
      xrpc_error(404, 'BlockNotFound', "Block $cid was not found") unless $found{$cid};
    }
    my @blocks = map {
      +{
        cid   => ATProto::PDS::Repo::CID->from_string($_),
        bytes => $found{$_}{bytes},
      }
    } @cids;
    my $car = write_car($blocks[0]{cid}, \@blocks);
    $c->res->headers->content_type('application/vnd.ipld.car');
    $c->render(data => $car);
    return;
  });

  $registry->register('com.atproto.sync.getBlob', sub ($c, $endpoint) {
    my $account = resolve_did_account($c, $c->param('did') // q());
    xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless $account;
    my $blob = $c->store->get_blob($c->param('cid') // q());
    xrpc_error(404, 'BlobNotFound', 'Blob was not found')
      unless $blob && ($blob->{did} // q()) eq $account->{did};
    xrpc_error(404, 'BlobNotFound', 'Blob content is not available')
      unless $blob->{storage_path} && -f $blob->{storage_path};
    open(my $fh, '<:raw', $blob->{storage_path}) or xrpc_error(500, 'StorageFailure', 'Unable to read blob');
    local $/ = undef;
    my $bytes = <$fh>;
    close($fh);
    $c->res->headers->content_type($blob->{mime_type} || 'application/octet-stream');
    $c->render(data => $bytes);
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

  $registry->register('com.atproto.sync.listReposByCollection', sub ($c, $endpoint) {
    my $page = $c->store->list_repos_by_collection(
      $c->param('collection'),
      limit  => $c->param('limit') // 500,
      cursor => $c->param('cursor'),
    );
    return {
      (defined $page->{cursor} ? (cursor => $page->{cursor}) : ()),
      repos => [ map { +{ did => $_->{did} } } @{ $page->{items} } ],
    };
  });

  $registry->register('com.atproto.sync.listBlobs', sub ($c, $endpoint) {
    my $account = resolve_did_account($c, $c->param('did') // q());
    xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless $account;
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

  $registry->register('com.atproto.sync.requestCrawl', sub ($c, $endpoint) {
    my $body = $c->req->json || {};
    my $host = $c->store->touch_host_notice(
      hostname     => $body->{hostname},
      requested_at => time,
      last_seq     => $c->store->latest_event_seq,
      status       => { status => 'active' },
    );
    return {};
  });

  $registry->register('com.atproto.sync.notifyOfUpdate', sub ($c, $endpoint) {
    my $body = $c->req->json || {};
    $c->store->touch_host_notice(
      hostname    => $body->{hostname},
      notified_at => time,
      last_seq    => $c->store->latest_event_seq,
      status      => { status => 'active' },
    );
    return {};
  });

  $registry->register('com.atproto.sync.listHosts', sub ($c, $endpoint) {
    my $page = $c->store->list_host_notices(
      limit  => $c->param('limit') // 200,
      cursor => $c->param('cursor'),
    );
    my @hosts = map { _host_view($c, $_) } @{ $page->{items} };
    if (!@hosts) {
      push @hosts, _host_view($c, {
        hostname => service_host($c->app->settings),
        last_seq => $c->store->latest_event_seq,
        status   => { status => 'active' },
      });
    }
    return {
      (defined $page->{cursor} ? (cursor => $page->{cursor}) : ()),
      hosts => \@hosts,
    };
  });

  $registry->register('com.atproto.sync.getHostStatus', sub ($c, $endpoint) {
    my $hostname = $c->param('hostname') // q();
    my $host = $c->store->get_host_notice($hostname);
    if (!$host && $hostname eq service_host($c->app->settings)) {
      $host = {
        hostname => $hostname,
        last_seq => $c->store->latest_event_seq,
        status   => { status => 'active' },
      };
    }
    xrpc_error(404, 'HostNotFound', 'Host was not found') unless $host;
    return _host_view($c, $host);
  });

  $registry->register('com.atproto.sync.subscribeRepos', sub ($c, $endpoint) {
    my $cursor = int($c->param('cursor') // 0);
    my $latest = $c->store->latest_event_seq;
    if ($cursor > $latest) {
      $c->send({ json => {
        name    => 'OutdatedCursor',
        message => 'Cursor is ahead of the local event stream',
      }});
      $c->finish(1000);
      return;
    }

    my $events = $c->store->list_events_after($cursor, limit => 100);
    for my $event (@$events) {
      my $message = _event_message($event);
      next unless $message;
      $c->send({ json => $message });
    }

    $c->finish(1000);
    return;
  });
}

sub _flatten_params (@values) {
  my @flat;
  for my $value (@values) {
    push @flat, ref($value) eq 'ARRAY' ? @$value : $value;
  }
  return @flat;
}

sub _host_view ($c, $row) {
  return {
    hostname     => $row->{hostname},
    seq          => 0 + ($row->{last_seq} // 0),
    accountCount => 0 + scalar(@{ $c->store->list_accounts }),
    status       => $row->{status}{status} || 'active',
  };
}

sub _event_message ($event) {
  if (($event->{type} // q()) eq 'commit') {
    my @ops;
    my $writes = $event->{payload}{writes} || [];
    my $results = $event->{payload}{results} || [];
    for my $idx (0 .. $#$writes) {
      my $write = $writes->[$idx];
      my $result = $results->[$idx] || {};
      push @ops, {
        action => $write->{action},
        path   => join('/', grep { defined && length } $write->{collection}, $write->{rkey}),
        cid    => ($write->{action} eq 'delete' ? undef : $result->{cid}),
      };
    }
    return {
      seq    => 0 + $event->{seq},
      rebase => JSON::PP::false,
      tooBig => JSON::PP::false,
      repo   => $event->{did},
      commit => { '$link' => $event->{commit_cid} },
      rev    => $event->{rev},
      since  => undef,
      blocks => unpack('H*', $event->{car_bytes} // q()),
      ops    => \@ops,
      blobs  => [],
      time   => iso8601($event->{created_at}),
    };
  }

  if (($event->{type} // q()) eq 'identity') {
    return {
      seq    => 0 + $event->{seq},
      did    => $event->{did},
      handle => $event->{payload}{handle},
      time   => iso8601($event->{created_at}),
    };
  }

  if (($event->{type} // q()) eq 'account') {
    return {
      seq    => 0 + $event->{seq},
      did    => $event->{did},
      active => $event->{payload}{active} ? JSON::PP::true : JSON::PP::false,
      ($event->{payload}{status} ? (status => $event->{payload}{status}) : ()),
      time   => iso8601($event->{created_at}),
    };
  }

  return undef;
}

1;
