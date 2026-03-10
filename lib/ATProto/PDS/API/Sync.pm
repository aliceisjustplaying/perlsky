package ATProto::PDS::API::Sync;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use JSON::PP ();
use Mojo::IOLoop;

use ATProto::PDS::EventStream qw(encode_error_frame encode_info_frame encode_message_frame);
use ATProto::PDS::API::Util qw(iso8601 resolve_did_account xrpc_error);
use ATProto::PDS::Identity qw(service_host);
use ATProto::PDS::Repo::CAR qw(write_car);
use ATProto::PDS::Repo::CID;
use ATProto::PDS::Repo::Bytes;

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
    my $cursor_param = $c->param('cursor');
    my $latest = $c->store->latest_event_seq;
    my $oldest = $c->store->oldest_event_seq;

    my $next_seq;
    if (!defined $cursor_param || $cursor_param eq q()) {
      $next_seq = $latest + 1;
    } else {
      my $cursor = int($cursor_param);
      if ($cursor > $latest + 1) {
        $c->send({ binary => encode_error_frame('FutureCursor', 'Cursor is ahead of the local event stream') });
        $c->finish(1008);
        return;
      }
      if ($oldest && $cursor && $cursor < $oldest) {
        $c->send({ binary => encode_info_frame('OutdatedCursor', 'Cursor predates the oldest locally retained event') });
        $next_seq = $oldest;
      } else {
        $next_seq = $cursor || ($oldest || ($latest + 1));
      }
    }

    my $drain;
    $drain = sub {
      my $events = $c->store->list_events_from($next_seq, limit => 100);
      for my $event (@$events) {
        my $frame = _event_frame($event);
        next unless $frame;
        $next_seq = $event->{seq} + 1;
        $c->send({ binary => $frame });
      }
    };

    $drain->();
    my $timer_id = Mojo::IOLoop->recurring(0.25 => sub { $drain->() });
    $c->on(finish => sub ($c, $code, $reason = undef) {
      Mojo::IOLoop->remove($timer_id) if defined $timer_id;
    });
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

sub _event_frame ($event) {
  if (($event->{type} // q()) eq 'commit') {
    return encode_message_frame('#commit', {
      seq    => 0 + $event->{seq},
      rebase => JSON::PP::false,
      tooBig => JSON::PP::false,
      repo   => $event->{did},
      commit => ATProto::PDS::Repo::CID->from_string($event->{commit_cid}),
      rev    => $event->{rev},
      since  => $event->{payload}{since},
      blocks => ATProto::PDS::Repo::Bytes->new($event->{car_bytes} // q()),
      ops    => [
        map {
          +{
            action => $_->{action},
            path   => $_->{path},
            cid    => defined($_->{cid}) ? ATProto::PDS::Repo::CID->from_string($_->{cid}) : undef,
            (defined($_->{prev}) ? (prev => ATProto::PDS::Repo::CID->from_string($_->{prev})) : ()),
          }
        } @{ $event->{payload}{ops} || [] }
      ],
      blobs  => [],
      (defined($event->{payload}{prevData}) ? (prevData => ATProto::PDS::Repo::CID->from_string($event->{payload}{prevData})) : ()),
      time   => iso8601($event->{created_at}),
    });
  }

  if (($event->{type} // q()) eq 'identity') {
    return encode_message_frame('#identity', {
      seq    => 0 + $event->{seq},
      did    => $event->{did},
      handle => $event->{payload}{handle},
      time   => iso8601($event->{created_at}),
    });
  }

  if (($event->{type} // q()) eq 'account') {
    return encode_message_frame('#account', {
      seq    => 0 + $event->{seq},
      did    => $event->{did},
      active => $event->{payload}{active} ? JSON::PP::true : JSON::PP::false,
      ($event->{payload}{status} ? (status => $event->{payload}{status}) : ()),
      time   => iso8601($event->{created_at}),
    });
  }

  return undef;
}

1;
