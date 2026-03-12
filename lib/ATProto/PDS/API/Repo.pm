package ATProto::PDS::API::Repo;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use File::Path qw(make_path);
use File::Spec;
use JSON::PP ();
use Mojo::URL;

use ATProto::PDS::API::Server qw(require_auth);
use ATProto::PDS::API::Util qw(blob_ref resolve_repo xrpc_error);
use ATProto::PDS::Auth::OAuth qw(
  oauth_required_permission_scope
  oauth_scope_allows_permission
);
use ATProto::PDS::Constants qw(TOKEN_AUD_ACCESS);
use ATProto::PDS::Identity qw(account_did_doc normalize_handle resolve_handle_to_did);
use ATProto::PDS::Moderation qw(assert_record_readable assert_repo_readable assert_repo_writable is_record_takedown parse_at_uri);
use ATProto::PDS::Repo::CID;
use ATProto::PDS::Repo::DagCbor qw(encode_dag_cbor);

our @EXPORT_OK = qw(register_repo_handlers);

sub register_repo_handlers ($registry, $app) {
  $registry->register('com.atproto.repo.describeRepo', sub ($c, $endpoint) {
    my $account = _readable_repo($c, $c->param('repo'));
    my $did_doc = _describe_repo_did_doc($c, $account);

    return {
      handle          => $account->{handle},
      did             => $account->{did},
      didDoc          => $did_doc,
      collections     => $c->store->list_collections_for_did($account->{did}),
      handleIsCorrect => _describe_repo_handle_is_correct($c, $account, $did_doc)
        ? JSON::PP::true
        : JSON::PP::false,
    };
  });

  $registry->register('com.atproto.repo.createRecord', sub ($c, $endpoint) {
    my $body = $c->req->json || {};
    return _apply_single_write($c, $body, {
      action     => 'create',
      collection => $body->{collection},
      rkey       => $body->{rkey},
      value      => $body->{record},
      (exists $body->{swapRecord}
        ? (
          swap_record_present => 1,
          swap_record         => $body->{swapRecord},
        )
        : ()),
    }, include_result => 1);
  });

  $registry->register('com.atproto.repo.putRecord', sub ($c, $endpoint) {
    my $body = $c->req->json || {};
    return _put_record($c, $body);
  });

  $registry->register('com.atproto.repo.deleteRecord', sub ($c, $endpoint) {
    my $body = $c->req->json || {};
    return _delete_record($c, $body);
  });

  $registry->register('com.atproto.repo.applyWrites', sub ($c, $endpoint) {
    my $body = $c->req->json || {};
    my ($claims, $account) = _require_repo_owner($c, $body->{repo});
    my @writes = map { _normalize_apply_writes_input($_) } @{ $body->{writes} || [] };
    xrpc_error(400, 'InvalidRequest', 'Too many writes. Max: 200')
      if @writes > 200;
    _assert_oauth_write_permissions($claims, \@writes);
    my $commit = $c->repo_manager->apply_writes(
      $account,
      \@writes,
      swap_commit => $body->{swapCommit},
    );
    return {
      commit  => _commit_view($commit),
      results => $commit->{results},
    };
  });

  $registry->register('com.atproto.repo.getRecord', sub ($c, $endpoint) {
    my $account = resolve_repo($c, $c->param('repo'));
    unless ($account) {
      _proxy_remote_get_record($c);
      return undef;
    }
    assert_repo_readable($c, $account);
    my $row = $c->store->get_record(
      $account->{did},
      $c->param('collection'),
      $c->param('rkey'),
      $c->param('cid'),
    );
    xrpc_error(404, 'RecordNotFound', 'Record was not found') unless $row;
    assert_record_readable($c, _record_uri($account->{did}, $row->{collection}, $row->{rkey}));
    return _record_view($account->{did}, $row);
  });

  $registry->register('com.atproto.repo.listRecords', sub ($c, $endpoint) {
    my $account = _readable_repo(
      $c,
      $c->param('repo'),
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
      records => [ map { _record_view($account->{did}, $_) } @{ $page->{items} } ],
    };
  });

  $registry->register('com.atproto.repo.uploadBlob', sub ($c, $endpoint) {
    my ($claims, $account) = require_auth($c, audience => TOKEN_AUD_ACCESS);
    assert_repo_writable($c, $account);
    my $bytes = $c->req->body // q();
    my $mime_type = $c->req->headers->content_type || 'application/octet-stream';
    _assert_oauth_permission(
      $claims,
      type => 'blob',
      mime => $mime_type,
    );
    my $cid = ATProto::PDS::Repo::CID->for_raw($bytes)->to_string;
    my $existing = $c->store->get_blob($cid);
    xrpc_error(400, 'BlobTakenDown', 'Blob has been taken down')
      if $existing && defined $existing->{quarantined_at};
    my $data_dir = $c->config_value('data_dir', File::Spec->catdir($c->app->project_root, 'data', 'runtime'));
    my $blob_dir = File::Spec->catdir($data_dir, 'blobs');
    make_path($blob_dir);
    my $path = File::Spec->catfile($blob_dir, $cid);
    open(my $fh, '>:raw', $path) or xrpc_error(500, 'StorageFailure', "Unable to write blob $cid");
    my $write_ok = print {$fh} $bytes;
    my $close_ok = close($fh);
    unless ($write_ok && $close_ok) {
      unlink $path if -e $path;
      xrpc_error(500, 'StorageFailure', "Unable to write blob $cid");
    }

    $c->observe_blob_ingress($mime_type, length($bytes));
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
    my (undef, $account) = require_auth($c, audience => TOKEN_AUD_ACCESS);
    assert_repo_writable($c, $account);
    my $page = _missing_blobs_page(
      $c,
      $account->{did},
      limit  => $c->param('limit') // 500,
      cursor => $c->param('cursor'),
    );
    return {
      blobs => $page->{items},
      (defined $page->{cursor} ? (cursor => $page->{cursor}) : ()),
    };
  });

  $registry->register('com.atproto.repo.importRepo', sub ($c, $endpoint) {
    my ($claims, $account) = require_auth($c, audience => TOKEN_AUD_ACCESS, required_scope => 'full');
    assert_repo_writable($c, $account);
    _assert_oauth_permission(
      $claims,
      type   => 'account',
      attr   => 'repo',
      action => 'manage',
    );
    xrpc_error(400, 'InvalidRequest', 'Service is not accepting repo imports')
      unless $c->config_value('accepting_imports', 1);
    my $car_bytes = $c->req->body // q();
    xrpc_error(400, 'InvalidRequest', 'Repo import requires a CAR payload')
      unless length $car_bytes;
    eval {
      $c->repo_manager->import_repo_car($account, $car_bytes);
      1;
    } or do {
      my $err = $@;
      die $err if ref($err) eq 'HASH';
      xrpc_error(400, 'InvalidRequest', 'Repo import CAR was invalid');
    };
    return {};
  });
}

sub _require_repo_owner ($c, $repo) {
  my ($claims) = require_auth($c, audience => TOKEN_AUD_ACCESS);
  my $account = resolve_repo($c, $repo);
  xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless $account;
  xrpc_error(401, 'AuthRequired', 'Token is not authorized for that repo') unless ($claims->{sub} // '') eq $account->{did};
  assert_repo_writable($c, $account);
  return ($claims, $account);
}

sub _readable_repo ($c, $repo, %args) {
  my $account = resolve_repo($c, $repo);
  xrpc_error(404, 'RepoNotFound', 'Repository was not found') unless $account;
  assert_repo_readable($c, $account, %args);
  return $account;
}

sub _proxy_remote_get_record ($c) {
  my $appview_url = $c->service_proxy->_config('bsky_appview_url', 'https://api.bsky.app');
  xrpc_error(404, 'RepoNotFound', 'Repository was not found')
    unless defined($appview_url) && length($appview_url);

  my $url = Mojo::URL->new($appview_url);
  $url->path($c->req->url->path->to_string);
  $url->query($c->req->url->query->clone);

  my %headers = (
    'Accept-Encoding' => 'identity',
  );
  for my $pair (
    ['Accept-Language', 'Accept-Language'],
    ['Atproto-Accept-Labelers', 'Atproto-Accept-Labelers'],
    ['X-Bsky-Topics', 'X-Bsky-Topics'],
  ) {
    my ($source, $dest) = @$pair;
    my $value = $c->req->headers->header($source);
    $headers{$dest} = $value if defined $value && length $value;
  }

  my $res = $c->service_proxy->_perform_upstream_request(
    method  => $c->req->method,
    url     => $url,
    headers => \%headers,
  );

  my $status = $res->code // 502;
  my $headers_out = $c->res->headers;
  for my $name (
    qw(
      Content-Type
      Content-Language
      Cache-Control
      ETag
      Last-Modified
      Expires
      Atproto-Repo-Rev
      Atproto-Content-Labelers
      Retry-After
      WWW-Authenticate
      DPoP-Nonce
    )
  ) {
    my $value = $res->headers->header($name);
    $headers_out->header($name => $value) if defined $value && length $value;
  }

  if ($c->req->method eq 'HEAD') {
    $c->res->code($status);
    $c->rendered($status);
    return;
  }

  $c->render(
    status => $status,
    data   => $res->body,
  );
  return;
}

sub _apply_single_write ($c, $body, $write, %args) {
  my ($claims, $account) = _require_repo_owner($c, $body->{repo});
  _assert_oauth_write_permissions($claims, [$write]);
  my $commit = $c->repo_manager->apply_writes(
    $account,
    [$write],
    swap_commit => $body->{swapCommit},
  );
  my %response = (
    commit => _commit_view($commit),
  );
  if ($args{include_result}) {
    my $result = $commit->{results}[0];
    return {
      %$result,
      %response,
    };
  }
  return \%response;
}

sub _put_record ($c, $body) {
  my ($claims, $account) = _require_repo_owner($c, $body->{repo});
  my $did = $account->{did};
  my $collection = $body->{collection};
  my $rkey = $body->{rkey};
  my $uri = _record_uri($did, $collection, $rkey);
  my $current = $c->store->get_record($did, $collection, $rkey);
  my $record_bytes = encode_dag_cbor($body->{record});

  _assert_oauth_write_permissions($claims, [
    {
      action     => 'create',
      collection => $collection,
    },
    {
      action     => 'update',
      collection => $collection,
    },
  ]);

  if ($current && defined($current->{record_bytes}) && $current->{record_bytes} eq $record_bytes) {
    return {
      uri              => $uri,
      cid              => $current->{cid},
      validationStatus => 'unknown',
    };
  }

  my $commit = $c->repo_manager->apply_writes(
    $account,
    [{
      action     => $current ? 'update' : 'create',
      collection => $collection,
      rkey       => $rkey,
      value      => $body->{record},
      (exists $body->{swapRecord}
        ? (
          swap_record_present => 1,
          swap_record         => $body->{swapRecord},
        )
        : ()),
    }],
    swap_commit => $body->{swapCommit},
  );
  return {
    %{ $commit->{results}[0] },
    commit => _commit_view($commit),
  };
}

sub _delete_record ($c, $body) {
  my ($claims, $account) = _require_repo_owner($c, $body->{repo});
  my $current = $c->store->get_record($account->{did}, $body->{collection}, $body->{rkey});
  return {} unless $current;
  _assert_oauth_write_permissions($claims, [{
    action     => 'delete',
    collection => $body->{collection},
  }]);
  my $commit = $c->repo_manager->apply_writes(
    $account,
    [{
      action     => 'delete',
      collection => $body->{collection},
      rkey       => $body->{rkey},
      (exists $body->{swapRecord}
        ? (
          swap_record_present => 1,
          swap_record         => $body->{swapRecord},
        )
        : ()),
    }],
    swap_commit => $body->{swapCommit},
  );
  return {
    commit => _commit_view($commit),
  };
}

sub _assert_oauth_write_permissions ($claims, $writes) {
  return unless ($claims->{typ} // q()) eq 'oauth_access';

  for my $write (@$writes) {
    _assert_oauth_permission(
      $claims,
      type       => 'repo',
      action     => $write->{action},
      collection => $write->{collection},
    );
  }
}

sub _assert_oauth_permission ($claims, %required) {
  return unless ($claims->{typ} // q()) eq 'oauth_access';
  return if oauth_scope_allows_permission($claims->{scope}, %required);
  my $needed = oauth_required_permission_scope(%required);
  xrpc_error(403, 'Forbidden', qq{Missing required scope "$needed"});
}

sub _commit_view ($commit) {
  return {
    cid => $commit->{cid},
    rev => $commit->{rev},
  };
}

sub _record_uri ($did, $collection, $rkey) {
  return "at://$did/$collection/$rkey";
}

sub _describe_repo_did_doc ($c, $account) {
  return $account->{did_doc} if ref($account->{did_doc}) eq 'HASH';
  return account_did_doc($c->app->settings, $account);
}

sub _describe_repo_handle_is_correct ($c, $account, $did_doc) {
  my $handle = normalize_handle($account->{handle}, undef, { no_append => 1 });
  return 0 unless defined $handle;
  my $doc_handle = _did_doc_handle($did_doc);
  return defined($doc_handle) && lc($doc_handle) eq lc($handle) ? 1 : 0;
}

sub _did_doc_handle ($did_doc) {
  return undef unless ref($did_doc) eq 'HASH';
  for my $aka (@{ $did_doc->{alsoKnownAs} || [] }) {
    next unless defined $aka && $aka =~ m{\Aat://(.+)\z};
    my $handle = normalize_handle($1, undef, { no_append => 1 });
    return $handle if defined $handle;
  }
  return undef;
}

sub _record_view ($did, $row) {
  return {
    uri   => _record_uri($did, $row->{collection}, $row->{rkey}),
    cid   => $row->{cid},
    value => $row->{value},
  };
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

sub _missing_blobs_page ($c, $did, %args) {
  my $limit = $args{limit} // 500;
  my $cursor = $args{cursor};
  my %missing_by_cid;

  for my $row (@{ $c->store->all_records_for_did($did) }) {
    my $record_uri = _record_uri($did, $row->{collection}, $row->{rkey});
    for my $cid (_record_blob_cids($row->{value})) {
      next if defined($cursor) && length($cursor) && $cid le $cursor;
      next if $c->store->get_blob($cid);
      my $current = $missing_by_cid{$cid};
      if (!$current || ($record_uri cmp $current->{recordUri}) < 0) {
        $missing_by_cid{$cid} = {
          cid       => $cid,
          recordUri => $record_uri,
        };
      }
    }
  }

  my @items = map { $missing_by_cid{$_} } sort keys %missing_by_cid;
  splice @items, $limit if @items > $limit;
  return {
    items  => \@items,
    cursor => @items ? $items[-1]{cid} : undef,
  };
}

sub _record_blob_cids ($value) {
  return () unless defined $value;
  if (ref($value) eq 'HASH') {
    if (($value->{'$type'} // q()) eq 'blob' && ref($value->{ref}) eq 'HASH' && defined($value->{ref}{'$link'})) {
      return ($value->{ref}{'$link'});
    }
    my @found;
    for my $child (values %$value) {
      push @found, _record_blob_cids($child);
    }
    return @found;
  }
  if (ref($value) eq 'ARRAY') {
    my @found;
    for my $child (@$value) {
      push @found, _record_blob_cids($child);
    }
    return @found;
  }
  return ();
}

sub _normalize_apply_writes_input ($write) {
  my $type = $write->{'$type'} // q();
  my $action =
      $type =~ /#create\z/ ? 'create'
    : $type =~ /#update\z/ ? 'update'
    : $type =~ /#delete\z/ ? 'delete'
    : $write->{action};
  return {
    %$write,
    action => $action,
  };
}

1;
