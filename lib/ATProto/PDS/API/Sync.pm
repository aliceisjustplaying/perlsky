package ATProto::PDS::API::Sync;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use JSON::PP ();

use ATProto::PDS::EventStream qw(encode_message_frame);
use ATProto::PDS::API::Util qw(flatten_params iso8601 pump_event_subscription resolve_did_account subscription_start_seq xrpc_error);
use ATProto::PDS::Constants qw(
  EVENT_TYPE_ACCOUNT
  EVENT_TYPE_COMMIT
  EVENT_TYPE_IDENTITY
  EVENT_TYPE_SYNC
);
use ATProto::PDS::Identity qw(service_host);
use ATProto::PDS::Moderation qw(assert_blob_readable assert_repo_readable);
use ATProto::PDS::Repo::CAR qw(write_car);
use ATProto::PDS::Repo::CID;
use ATProto::PDS::Repo::Bytes;
use ATProto::PDS::Repo::MST qw(build_mst);

our @EXPORT_OK = qw(register_sync_handlers);

sub register_sync_handlers ($registry, $app) {
  $registry->register('com.atproto.sync.getLatestCommit', sub ($c, $endpoint) {
    my $account = _readable_repo_by_did($c);
    my $head = _repo_head_or_error($c, $account->{did});
    return {
      cid => $head->{commit_cid},
      rev => $head->{rev},
    };
  });

  $registry->register('com.atproto.sync.getHead', sub ($c, $endpoint) {
    my $account = _readable_repo_by_did(
      $c,
      missing_error    => 'HeadNotFound',
      missing_message  => 'Repository head was not found',
      readable_error   => 'HeadNotFound',
      readable_message => 'Repository head was not found',
    );
    my $head = _repo_head_or_error(
      $c,
      $account->{did},
      error   => 'HeadNotFound',
      message => 'Repository head was not found',
    );
    return {
      root => $head->{commit_cid},
    };
  });

  $registry->register('com.atproto.sync.getRepoStatus', sub ($c, $endpoint) {
    my $account = _readable_repo_by_did($c);
    return {
      did    => $account->{did},
      active => defined($account->{deactivated_at}) ? JSON::PP::false : JSON::PP::true,
      (defined($account->{repo_rev}) ? (rev => $account->{repo_rev}) : ()),
      (defined($account->{deactivated_at}) ? (status => 'deactivated') : ()),
      (defined($account->{deleted_at}) ? (status => 'deleted') : ()),
    };
  });

  $registry->register('com.atproto.sync.getRepo', sub ($c, $endpoint) {
    my $account = _readable_repo_by_did($c);
    return _render_repo_car($c, $account->{did});
  });

  $registry->register('com.atproto.sync.getCheckout', sub ($c, $endpoint) {
    my $account = _readable_repo_by_did($c);
    return _render_repo_car($c, $account->{did});
  });

  $registry->register('com.atproto.sync.getRecord', sub ($c, $endpoint) {
    my $account = _readable_repo_by_did($c);
    return _render_car(
      $c,
      _record_proof_car(
        $c,
        $account->{did},
        $c->param('collection') // q(),
        $c->param('rkey') // q(),
      ),
    );
  });

  $registry->register('com.atproto.sync.getBlocks', sub ($c, $endpoint) {
    my $account = _readable_repo_by_did($c);
    my @cids = flatten_params($c->every_param('cids'));
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
    return _render_car($c, write_car($blocks[0]{cid}, \@blocks));
  });

  $registry->register('com.atproto.sync.getBlob', sub ($c, $endpoint) {
    my $account = _repo_by_did_or_error($c);
    my $blob = $c->store->get_blob($c->param('cid') // q());
    xrpc_error(404, 'BlobNotFound', 'Blob was not found')
      unless $blob && $c->store->blob_owned_by_did($c->param('cid') // q(), $account->{did});
    assert_blob_readable($c, $account, $blob);
    xrpc_error(404, 'BlobNotFound', 'Blob content is not available')
      unless $blob->{storage_path} && -f $blob->{storage_path};
    open(my $fh, '<:raw', $blob->{storage_path}) or xrpc_error(500, 'StorageFailure', 'Unable to read blob');
    local $/ = undef;
    my $bytes = <$fh>;
    close($fh);
    $c->res->headers->content_type($blob->{mime_type} || 'application/octet-stream');
    $c->res->headers->header('Cross-Origin-Resource-Policy' => 'cross-origin');
    $c->res->headers->header('X-Content-Type-Options' => 'nosniff');
    $c->res->headers->header('Content-Disposition' => 'attachment; filename="' . ($c->param('cid') // q()) . '"');
    $c->res->headers->header('Content-Security-Policy' => q{default-src 'none'; sandbox});
    $c->observe_blob_egress($blob->{mime_type}, length($bytes));
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
    my $account = _readable_repo_by_did($c);
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
    my $next_seq = subscription_start_seq(
      $c,
      cursor_param   => $c->param('cursor'),
      future_message => 'Cursor is ahead of the local event stream',
    );
    return unless defined $next_seq;
    pump_event_subscription($c, $next_seq, sub ($event) {
      my $frame = _event_frame($event);
      return unless defined $frame;
      return ($frame, $event->{type} // 'message');
    });
    return;
  });
}

sub _host_view ($c, $row) {
  return {
    hostname     => $row->{hostname},
    seq          => 0 + ($row->{last_seq} // 0),
    accountCount => 0 + scalar(@{ $c->store->list_accounts }),
    status       => $row->{status}{status} || 'active',
  };
}

sub _did_param ($c) {
  return $c->param('did') // q();
}

sub _repo_lookup_message ($did) {
  return 'Could not find repo for DID: ' . $did;
}

sub _repo_by_did_or_error ($c, %args) {
  my $did = $args{did} // _did_param($c);
  my $account = resolve_did_account($c, $did);
  xrpc_error(
    $args{missing_status} // 404,
    $args{missing_error} // 'RepoNotFound',
    $args{missing_message} // 'Repository was not found',
  ) unless $account;
  return $account;
}

sub _readable_repo_by_did ($c, %args) {
  my $did = $args{did} // _did_param($c);
  my $account = _repo_by_did_or_error(
    $c,
    did             => $did,
    missing_status  => $args{missing_status},
    missing_error   => $args{missing_error},
    missing_message => $args{missing_message},
  );
  assert_repo_readable(
    $c,
    $account,
    (defined $args{readable_status} ? (status => $args{readable_status}) : ()),
    (defined $args{readable_error} ? (error => $args{readable_error}) : ()),
    message => $args{readable_message} // _repo_lookup_message($did),
  );
  return $account;
}

sub _repo_head_or_error ($c, $did, %args) {
  my $head = $c->store->get_repo_head($did);
  xrpc_error(
    $args{status} // 404,
    $args{error} // 'RepoNotFound',
    $args{message} // 'Repository was not found',
  ) unless $head;
  return $head;
}

sub _render_repo_car ($c, $did, %args) {
  my $car = $c->store->repo_car($did);
  xrpc_error(
    $args{status} // 404,
    $args{error} // 'RepoNotFound',
    $args{message} // 'Repository was not found',
  ) unless defined $car;
  return _render_car($c, $car);
}

sub _record_proof_car ($c, $did, $collection, $rkey) {
  my $head = $c->store->get_latest_commit($did);
  xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless $head;
  my $records = $c->store->all_records_for_did($did);
  my %mst_input = map {
    $_->{collection} . '/' . $_->{rkey} => ATProto::PDS::Repo::CID->from_string($_->{cid})
  } @$records;
  my $mst = build_mst(\%mst_input);
  my @blocks = (
    {
      cid   => ATProto::PDS::Repo::CID->from_string($head->{cid}),
      bytes => $head->{commit_bytes},
    },
    @{ $mst->{blocks} },
  );

  my $record = $c->store->get_record($did, $collection, $rkey);
  if ($record) {
    push @blocks, {
      cid   => ATProto::PDS::Repo::CID->from_string($record->{cid}),
      bytes => $record->{record_bytes},
    };
  }

  return write_car($blocks[0]{cid}, \@blocks);
}

sub _render_car ($c, $car) {
  $c->res->headers->content_type('application/vnd.ipld.car');
  $c->render(data => $car);
  return;
}

sub _event_frame ($event) {
  if (($event->{type} // q()) eq EVENT_TYPE_COMMIT) {
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

  if (($event->{type} // q()) eq EVENT_TYPE_SYNC) {
    return encode_message_frame('#sync', {
      seq    => 0 + $event->{seq},
      did    => $event->{did},
      rev    => $event->{rev},
      blocks => ATProto::PDS::Repo::Bytes->new($event->{car_bytes} // q()),
      time   => iso8601($event->{created_at}),
    });
  }

  if (($event->{type} // q()) eq EVENT_TYPE_IDENTITY) {
    return encode_message_frame('#identity', {
      seq    => 0 + $event->{seq},
      did    => $event->{did},
      handle => $event->{payload}{handle},
      time   => iso8601($event->{created_at}),
    });
  }

  if (($event->{type} // q()) eq EVENT_TYPE_ACCOUNT) {
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
