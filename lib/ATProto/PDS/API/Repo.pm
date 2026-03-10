package ATProto::PDS::API::Repo;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use File::Path qw(make_path);
use File::Spec;
use JSON::PP ();

use ATProto::PDS::API::Server qw(require_auth);
use ATProto::PDS::API::Util qw(blob_ref);
use ATProto::PDS::Moderation qw(assert_record_readable assert_repo_readable assert_repo_writable is_record_takedown parse_at_uri);
use ATProto::PDS::Repo::CID;

our @EXPORT_OK = qw(register_repo_handlers);

sub register_repo_handlers ($registry, $app) {
  $registry->register('com.atproto.repo.describeRepo', sub ($c, $endpoint) {
    my $account = _resolve_repo($c, $c->param('repo'));
    _xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless $account;
    assert_repo_readable($c, $account);

    return {
      handle          => $account->{handle},
      did             => $account->{did},
      didDoc          => $account->{did_doc},
      collections     => $c->store->list_collections_for_did($account->{did}),
      handleIsCorrect => JSON::PP::true,
    };
  });

  $registry->register('com.atproto.repo.createRecord', sub ($c, $endpoint) {
    my $body = $c->req->json || {};
    my $account = _require_repo_owner($c, $body->{repo});
    my $commit = $c->repo_manager->apply_writes($account, [{
      action     => 'create',
      collection => $body->{collection},
      rkey       => $body->{rkey},
      value      => $body->{record},
    }], swap_commit => $body->{swapCommit});
    my $result = $commit->{results}[0];
    return {
      %$result,
      commit => {
        cid => $commit->{cid},
        rev => $commit->{rev},
      },
    };
  });

  $registry->register('com.atproto.repo.putRecord', sub ($c, $endpoint) {
    my $body = $c->req->json || {};
    my $account = _require_repo_owner($c, $body->{repo});
    my $commit = $c->repo_manager->apply_writes($account, [{
      action     => 'update',
      collection => $body->{collection},
      rkey       => $body->{rkey},
      value      => $body->{record},
    }], swap_commit => $body->{swapCommit});
    my $result = $commit->{results}[0];
    return {
      %$result,
      commit => {
        cid => $commit->{cid},
        rev => $commit->{rev},
      },
    };
  });

  $registry->register('com.atproto.repo.deleteRecord', sub ($c, $endpoint) {
    my $body = $c->req->json || {};
    my $account = _require_repo_owner($c, $body->{repo});
    my $commit = $c->repo_manager->apply_writes($account, [{
      action     => 'delete',
      collection => $body->{collection},
      rkey       => $body->{rkey},
    }], swap_commit => $body->{swapCommit});
    return {
      commit => {
        cid => $commit->{cid},
        rev => $commit->{rev},
      },
    };
  });

  $registry->register('com.atproto.repo.applyWrites', sub ($c, $endpoint) {
    my $body = $c->req->json || {};
    my $account = _require_repo_owner($c, $body->{repo});
    my $commit = $c->repo_manager->apply_writes(
      $account,
      $body->{writes} || [],
      swap_commit => $body->{swapCommit},
    );
    return {
      commit => {
        cid => $commit->{cid},
        rev => $commit->{rev},
      },
      results => $commit->{results},
    };
  });

  $registry->register('com.atproto.repo.getRecord', sub ($c, $endpoint) {
    my $account = _resolve_repo($c, $c->param('repo'));
    _xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless $account;
    assert_repo_readable($c, $account);
    my $row = $c->store->get_record($account->{did}, $c->param('collection'), $c->param('rkey'));
    _xrpc_error(404, 'RecordNotFound', 'Record was not found') unless $row;
    assert_record_readable($c, "at://$account->{did}/$row->{collection}/$row->{rkey}");
    return {
      uri   => "at://$account->{did}/$row->{collection}/$row->{rkey}",
      cid   => $row->{cid},
      value => $row->{value},
    };
  });

  $registry->register('com.atproto.repo.listRecords', sub ($c, $endpoint) {
    my $account = _resolve_repo($c, $c->param('repo'));
    _xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless $account;
    assert_repo_readable(
      $c,
      $account,
      status  => 400,
      error   => 'InvalidRequest',
      message => 'Could not find repo: ' . ($c->param('repo') // q()),
    );
    my $page = _list_visible_records(
      $c,
      $account->{did},
      $c->param('collection'),
      limit   => $c->param('limit') // 50,
      cursor  => $c->param('cursor'),
      reverse => $c->param('reverse') ? 1 : 0,
    );
    return {
      (defined $page->{cursor} ? (cursor => $page->{cursor}) : ()),
      records => [
        map {
          +{
            uri   => "at://$account->{did}/$_->{collection}/$_->{rkey}",
            cid   => $_->{cid},
            value => $_->{value},
          }
        } @{ $page->{items} }
      ],
    };
  });

  $registry->register('com.atproto.repo.uploadBlob', sub ($c, $endpoint) {
    my (undef, $account) = require_auth($c, audience => 'access', allow_refresh => 1);
    assert_repo_writable($c, $account);
    my $bytes = $c->req->body // q();
    my $cid = ATProto::PDS::Repo::CID->for_raw($bytes)->to_string;
    my $existing = $c->store->get_blob($cid);
    _xrpc_error(400, 'BlobTakenDown', 'Blob has been taken down')
      if $existing && defined $existing->{quarantined_at};
    my $data_dir = $c->config_value('data_dir', File::Spec->catdir($c->app->project_root, 'data', 'runtime'));
    my $blob_dir = File::Spec->catdir($data_dir, 'blobs');
    make_path($blob_dir);
    my $path = File::Spec->catfile($blob_dir, $cid);
    open(my $fh, '>:raw', $path) or _xrpc_error(500, 'StorageFailure', "Unable to write blob $cid");
    print {$fh} $bytes;
    close($fh);

    my $mime_type = $c->req->headers->content_type || 'application/octet-stream';
    $c->store->put_blob(
      cid          => $cid,
      did          => $account->{did},
      mime_type    => $mime_type,
      byte_size    => length($bytes),
      storage_path => $path,
      temporary    => 1,
    );

    return {
      blob => blob_ref($cid, $mime_type, length($bytes)),
    };
  });

  $registry->register('com.atproto.repo.listMissingBlobs', sub ($c, $endpoint) {
    my (undef, $account) = require_auth($c, audience => 'access', allow_refresh => 1);
    assert_repo_writable($c, $account);
    my $page = {
      items  => [],
      cursor => undef,
    };
    return {
      blobs => $page->{items},
    };
  });

  $registry->register('com.atproto.repo.importRepo', sub ($c, $endpoint) {
    my (undef, $account) = require_auth($c, audience => 'access', allow_refresh => 1);
    assert_repo_writable($c, $account);
    _xrpc_error(400, 'InvalidRequest', 'Service is not accepting repo imports')
      unless $c->config_value('accepting_imports', 1);
    my $car_bytes = $c->req->body // q();
    _xrpc_error(400, 'InvalidRequest', 'Repo import requires a CAR payload')
      unless length $car_bytes;
    $c->repo_manager->import_repo_car($account, $car_bytes);
    return {};
  });
}

sub _resolve_repo ($c, $repo) {
  return undef unless defined $repo && length $repo;
  return $c->store->get_account_by_handle($repo) unless $repo =~ /\Adid:/;

  my $account = $c->store->get_account_by_did($repo);
  return $account if $account;

  my $target = lc $repo;
  $target =~ s/%3a/:/ig;
  for my $row (@{ $c->store->list_accounts }) {
    my $candidate = lc($row->{did} // q());
    $candidate =~ s/%3a/:/ig;
    return $row if $candidate eq $target;
  }

  return undef;
}

sub _require_repo_owner ($c, $repo) {
  my $account = _resolve_repo($c, $repo);
  _xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless $account;
  my ($claims) = require_auth($c, audience => 'access', allow_refresh => 1);
  _xrpc_error(401, 'AuthRequired', 'Token is not authorized for that repo') unless ($claims->{sub} // '') eq $account->{did};
  assert_repo_writable($c, $account);
  return $account;
}

sub _list_visible_records ($c, $did, $collection, %args) {
  my $limit = $args{limit} // 50;
  my $cursor = $args{cursor};
  my $reverse = $args{reverse} ? 1 : 0;
  my @visible;
  my $next_cursor = $cursor;
  while (@visible < $limit + 1) {
    my $page = $c->store->list_records(
      $did,
      $collection,
      limit   => $limit + 1,
      cursor  => $next_cursor,
      reverse => $reverse,
    );
    last unless @{ $page->{items} };
    for my $row (@{ $page->{items} }) {
      next if is_record_takedown($c, "at://$did/$row->{collection}/$row->{rkey}");
      push @visible, $row;
      last if @visible >= $limit + 1;
    }
    last unless defined $page->{cursor};
    $next_cursor = $page->{cursor};
  }

  my $out_cursor;
  if (@visible > $limit) {
    my $last = pop @visible;
    $out_cursor = $last->{rkey};
  }

  return {
    items  => \@visible,
    cursor => $out_cursor,
  };
}

sub _xrpc_error ($status, $error, $message) {
  die {
    status  => $status,
    error   => $error,
    message => $message,
  };
}

1;
