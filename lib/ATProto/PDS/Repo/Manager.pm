package ATProto::PDS::Repo::Manager;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use JSON::PP qw(encode_json);
use Scalar::Util qw(blessed);

use ATProto::PDS::Crypto::Secp256k1 qw(generate_keypair sign_compact_low_s);
use ATProto::PDS::API::Util qw(xrpc_error);
use ATProto::PDS::Repo::Bytes;
use ATProto::PDS::Repo::CAR qw(read_car write_car);
use ATProto::PDS::Repo::CID;
use ATProto::PDS::Repo::DagCbor qw(decode_dag_cbor encode_dag_cbor);
use ATProto::PDS::Repo::MST qw(build_mst);
use ATProto::PDS::Util::TID qw(is_valid_tid next_tid repair_tid);

sub new ($class, %args) {
  die 'store is required' unless $args{store};
  return bless \%args, $class;
}

sub store ($self) {
  return $self->{store};
}

sub crawler_notifier ($self) {
  return $self->{crawler_notifier};
}

sub generate_signing_key ($self) {
  return generate_keypair();
}

sub initialize_repo ($self, $account) {
  return $self->apply_writes($account, [], emit_event => 0);
}

sub apply_writes ($self, $account, $writes, %opts) {
  my $store = $self->store;
  my $did = $account->{did};
  my $latest = $store->get_latest_commit($did);
  if (defined $opts{swap_commit} && length($opts{swap_commit} // q())) {
    my $current = $latest ? $latest->{cid} : undef;
    die {
      status  => 400,
      error   => 'InvalidSwap',
      message => 'swapCommit did not match the current repo head',
    } unless defined $current && $current eq $opts{swap_commit};
  }

  my $records = {
    map {
      my $path = $_->{collection} . '/' . $_->{rkey};
      $path => {
        collection  => $_->{collection},
        rkey        => $_->{rkey},
        cid         => $_->{cid},
        value       => $_->{value},
        record_bytes => $_->{record_bytes},
      }
    } @{ $store->all_records_for_did($did) }
  };
  my %previous_records = map { $_ => { %{ $records->{$_} } } } keys %$records;

  my @results;
  my @ops;
  for my $write (@$writes) {
    my $action = $write->{action} // '';
    if ($action eq 'delete') {
      my $path = join('/', grep { defined && length } $write->{collection}, $write->{rkey});
      my $previous = $previous_records{$path};
      delete $records->{$path};
      push @results, {
        '$type' => 'com.atproto.repo.applyWrites#deleteResult',
      };
      push @ops, {
        action => 'delete',
        path   => $path,
        cid    => undef,
        ($previous ? (prev => $previous->{cid}) : ()),
      };
      next;
    }

    my $collection = $write->{collection};
    my $rkey = $write->{rkey} // next_tid();
    my $value = $write->{value} // $write->{record};
    my @blob_cids = _blob_cids($value);
    for my $blob_cid (@blob_cids) {
      my $blob = $store->get_blob($blob_cid);
      die {
        status  => 400,
        error   => 'InvalidBlob',
        message => "Could not find blob: $blob_cid",
      } unless $blob && $store->blob_owned_by_did($blob_cid, $did);
      die {
        status  => 400,
        error   => 'BlobTakenDown',
        message => "Blob has been taken down: $blob_cid",
      } if defined $blob->{quarantined_at};
    }
    my $bytes = encode_dag_cbor($value);
    my $cid = ATProto::PDS::Repo::CID->for_dag_cbor($bytes);
    my $path = $collection . '/' . $rkey;
    my $previous = $previous_records{$path};
    $records->{$path} = {
      collection   => $collection,
      rkey         => $rkey,
      cid          => $cid->to_string,
      value        => $value,
      record_bytes => $bytes,
    };
    push @results, {
      '$type'           => $previous ? 'com.atproto.repo.applyWrites#updateResult' : 'com.atproto.repo.applyWrites#createResult',
      uri              => "at://$did/$collection/$rkey",
      cid              => $cid->to_string,
      validationStatus => 'unknown',
    };
    push @ops, {
      action => $previous ? 'update' : 'create',
      path   => $path,
      cid    => $cid->to_string,
      ($previous ? (prev => $previous->{cid}) : ()),
    };
  }

  my $artifacts = _build_commit_artifacts(
    $account,
    $records,
    rev          => next_tid($latest ? $latest->{rev} : undef),
    record_paths => [ sort keys %$records ],
    firehose_paths => _firehose_record_paths(\@ops),
    cars         => [ qw(snapshot firehose sync) ],
  );
  my $rev = $artifacts->{rev};
  my $commit_cid = $artifacts->{commit_cid};
  my $commit_bytes = $artifacts->{commit_bytes};
  my $snapshot_car_bytes = $artifacts->{snapshot_car_bytes};
  my $car_bytes = $artifacts->{firehose_car_bytes};
  my $sync_car_bytes = $artifacts->{sync_car_bytes};

  $store->txn(sub ($dbh) {
    for my $block (@{ $artifacts->{repo_blocks} }) {
      $store->put_block(
        cid   => $block->{cid}->to_string,
        codec => $block->{cid}->codec,
        bytes => $block->{bytes},
      );
    }
    $store->replace_records_for_did($did, [ values %$records ]);
    for my $record (values %$records) {
      $store->mark_blobs_referenced($did, _blob_cids($record->{value}));
    }
    $store->put_commit(
      did         => $did,
      rev         => $rev,
      cid         => $commit_cid->to_string,
      root_cid    => $artifacts->{root_cid},
      prev_cid    => $latest ? $latest->{cid} : undef,
      commit_bytes => $commit_bytes,
      car_bytes   => $snapshot_car_bytes,
    );
    if ($opts{emit_event} // 1) {
      $store->append_event(
        did        => $did,
        type       => 'commit',
        rev        => $rev,
        commit_cid => $commit_cid->to_string,
        payload    => {
          ops      => \@ops,
          since    => $latest ? $latest->{rev} : undef,
          prevData => $latest ? $latest->{root_cid} : undef,
        },
        car_bytes  => $car_bytes,
      );
    }
  });
  $self->crawler_notifier->notify_of_update()
    if ($opts{emit_event} // 1) && $self->crawler_notifier;

  return {
    cid            => $commit_cid->to_string,
    rev            => $rev,
    root_cid       => $artifacts->{root_cid},
    car_bytes      => $car_bytes,
    sync_car_bytes => $sync_car_bytes,
    results        => \@results,
  };
}

sub _blob_cids ($value) {
  return () unless defined $value;
  if (ref($value) eq 'HASH') {
    if (($value->{'$type'} // q()) eq 'blob' && ref($value->{ref}) eq 'HASH' && defined($value->{ref}{'$link'})) {
      return ($value->{ref}{'$link'});
    }
    my @found;
    for my $child (values %$value) {
      push @found, _blob_cids($child);
    }
    return @found;
  }
  if (ref($value) eq 'ARRAY') {
    my @found;
    for my $child (@$value) {
      push @found, _blob_cids($child);
    }
    return @found;
  }
  return ();
}

sub import_repo_car ($self, $account, $car_bytes) {
  my $store = $self->store;
  my $did   = $account->{did};
  my $car   = read_car($car_bytes);
  die {
    status  => 400,
    error   => 'InvalidRepoImport',
    message => 'expected one root',
  } unless @{ $car->{roots} || [] } == 1;

  my %blocks = map { $_->{cid}->to_string => $_ } @{ $car->{blocks} || [] };
  my $import_root_cid = $car->{roots}[0];
  my $commit_block = $blocks{ $import_root_cid->to_string } or die {
    status  => 400,
    error   => 'InvalidRepoImport',
    message => 'root commit block is missing from the CAR',
  };
  my $commit = decode_dag_cbor($commit_block->{bytes});
  die {
    status  => 400,
    error   => 'InvalidRepoImport',
    message => 'imported repo belongs to a different DID',
  } unless ($commit->{did} // q()) eq $did;

  my $records = _records_from_import($commit->{data}, \%blocks);
  my %imported = map { $_->{collection} . '/' . $_->{rkey} => $_ } @$records;
  my %previous = map {
    $_->{collection} . '/' . $_->{rkey} => $_
  } @{ $store->all_records_for_did($did) };
  my @ops = _diff_record_sets(\%previous, \%imported);
  my $latest = $store->get_latest_commit($did);
  my $prev_data = $latest ? $latest->{root_cid} : undef;
  my %records_by_path = map {
    $_->{collection} . '/' . $_->{rkey} => $_
  } @$records;
  my $artifacts = _build_commit_artifacts(
    $account,
    \%records_by_path,
    rev            => next_tid($latest ? $latest->{rev} : undef),
    record_paths   => [ sort keys %records_by_path ],
    firehose_paths => _firehose_record_paths(\@ops),
    cars           => [ qw(snapshot firehose) ],
  );
  my $rev = $artifacts->{rev};
  my $commit_cid = $artifacts->{commit_cid};
  my $commit_bytes = $artifacts->{commit_bytes};
  my $root_cid = $artifacts->{root_cid};
  my $next_snapshot_car_bytes = $artifacts->{snapshot_car_bytes};
  my $next_car_bytes = $artifacts->{firehose_car_bytes};

  $store->txn(sub ($dbh) {
    for my $block (values %blocks, @{ $artifacts->{repo_blocks} }) {
      $store->put_block(
        cid   => $block->{cid}->to_string,
        codec => $block->{cid}->codec,
        bytes => $block->{bytes},
      );
    }
    $store->replace_records_for_did($did, $records);
    $store->put_commit(
      did          => $did,
      rev          => $rev,
      cid          => $commit_cid->to_string,
      root_cid     => $root_cid,
      prev_cid     => $latest ? $latest->{cid} : undef,
      commit_bytes => $commit_bytes,
      car_bytes    => $next_snapshot_car_bytes,
    );
    $store->append_event(
      did        => $did,
      type       => 'commit',
      rev        => $rev,
      commit_cid => $commit_cid->to_string,
      payload    => {
        ops      => \@ops,
        since    => $latest ? $latest->{rev} : undef,
        prevData => $prev_data,
      },
      car_bytes  => $next_car_bytes,
    );
  });
  $self->crawler_notifier->notify_of_update()
    if $self->crawler_notifier;

  return {
    cid      => $commit_cid->to_string,
    rev      => $rev,
    root_cid => $root_cid,
    records  => $records,
  };
}

sub repair_invalid_tids ($self, $account, %opts) {
  my $store   = $self->store;
  my $did     = $account->{did};
  my $latest  = $store->get_latest_commit($did);
  my $records = $store->all_records_for_did($did);

  my $repaired = _repair_records_for_repo($account, $records);
  my $rev_needs_repair = defined($latest->{rev}) && !is_valid_tid($latest->{rev}) && defined(repair_tid($latest->{rev}));
  my $needs_repair = $repaired->{changed} || $rev_needs_repair || ($opts{force} // 0);

  return {
    changed         => 0,
    repaired_paths  => $repaired->{repaired_paths},
    rewritten_refs  => $repaired->{rewritten_refs},
    rev_repaired    => $rev_needs_repair ? 1 : 0,
    imported        => undef,
  } unless $needs_repair;

  my $snapshot_car = _build_snapshot_car(
    $account,
    $repaired->{records},
    $latest ? (repair_tid($latest->{rev}) // $latest->{rev}) : undef,
  );
  my $imported = $self->import_repo_car($account, $snapshot_car);

  return {
    changed         => 1,
    repaired_paths  => $repaired->{repaired_paths},
    rewritten_refs  => $repaired->{rewritten_refs},
    rev_repaired    => $rev_needs_repair ? 1 : 0,
    imported        => $imported,
  };
}

sub _repair_records_for_repo ($account, $records) {
  my $did    = $account->{did};
  my $handle = $account->{handle};
  my %path_map;
  my %occupied = map {
    $_->{collection} . '/' . $_->{rkey} => 1
  } @$records;

  my $repaired_paths = 0;
  for my $record (@$records) {
    my $old_path = $record->{collection} . '/' . $record->{rkey};
    my $repaired_rkey = repair_tid($record->{rkey});
    next unless defined $repaired_rkey && $repaired_rkey ne $record->{rkey};

    my $new_path = $record->{collection} . '/' . $repaired_rkey;
    die {
      status  => 500,
      error   => 'RepoRepairCollision',
      message => "repair would collide at '$new_path'",
    } if $occupied{$new_path} && $new_path ne $old_path;

    delete $occupied{$old_path};
    $occupied{$new_path} = 1;
    $path_map{$old_path} = $new_path;
    $repaired_paths++;
  }

  my $rewritten_refs = 0;
  my @repaired;
  for my $record (@$records) {
    my $old_path = $record->{collection} . '/' . $record->{rkey};
    my $new_path = $path_map{$old_path} // $old_path;
    my ($collection, $rkey) = split m{/}, $new_path, 2;

    my $counter = 0;
    my $value = _rewrite_owned_at_uris(
      $record->{value},
      {
        $did    => 1,
        ($handle ? ($handle => 1) : ()),
      },
      \%path_map,
      \$counter,
    );
    $rewritten_refs += $counter;

    my $record_bytes = encode_dag_cbor($value);
    my $cid = ATProto::PDS::Repo::CID->for_dag_cbor($record_bytes)->to_string;
    push @repaired, {
      %$record,
      collection   => $collection,
      rkey         => $rkey,
      value        => $value,
      cid          => $cid,
      record_bytes => $record_bytes,
    };
  }

  my $changed = $repaired_paths || $rewritten_refs;
  if (!$changed) {
    for my $idx (0 .. $#repaired) {
      my $before = $records->[$idx];
      my $after  = $repaired[$idx];
      if (($before->{collection} // q()) ne ($after->{collection} // q())
        || ($before->{rkey} // q()) ne ($after->{rkey} // q())
        || ($before->{cid} // q()) ne ($after->{cid} // q())
      ) {
        $changed = 1;
        last;
      }
    }
  }

  return {
    changed        => $changed ? 1 : 0,
    repaired_paths => $repaired_paths,
    rewritten_refs => $rewritten_refs,
    records        => \@repaired,
    path_map       => \%path_map,
  };
}

sub _rewrite_owned_at_uris ($value, $hosts, $path_map, $counter_ref) {
  return undef unless defined $value;

  if (!ref($value)) {
    if ($value =~ m{\Aat://([^/]+)/([^/]+/[^/?#]+)\z}) {
      my ($host, $path) = ($1, $2);
      if ($hosts->{$host} && defined $path_map->{$path}) {
        $$counter_ref++ if $counter_ref;
        return "at://$host/$path_map->{$path}";
      }
    }
    return $value;
  }

  if (ref($value) eq 'ARRAY') {
    return [ map { _rewrite_owned_at_uris($_, $hosts, $path_map, $counter_ref) } @$value ];
  }

  if (ref($value) eq 'HASH') {
    return {
      map {
        $_ => _rewrite_owned_at_uris($value->{$_}, $hosts, $path_map, $counter_ref)
      } sort keys %$value
    };
  }

  return $value;
}

sub _build_snapshot_car ($account, $records, $rev = undef) {
  my %records_by_path = map {
    $_->{collection} . '/' . $_->{rkey} => $_
  } @$records;
  my $artifacts = _build_commit_artifacts(
    $account,
    \%records_by_path,
    rev          => $rev // next_tid(),
    record_paths => [ sort keys %records_by_path ],
    cars         => [ 'snapshot' ],
  );
  return $artifacts->{snapshot_car_bytes};
}

sub _build_commit_artifacts ($account, $records_by_path, %opts) {
  my %mst_input = map {
    $_ => ATProto::PDS::Repo::CID->from_string($records_by_path->{$_}{cid})
  } sort keys %$records_by_path;
  my $mst = build_mst(\%mst_input);
  my $rev = $opts{rev} // next_tid();
  my $unsigned = {
    did     => $account->{did},
    version => 3,
    data    => $mst->{root},
    rev     => $rev,
    prev    => undef,
  };
  my $unsigned_bytes = encode_dag_cbor($unsigned);
  my $sig = sign_compact_low_s($account->{private_key}, $unsigned_bytes);
  my $commit = { %$unsigned, sig => ATProto::PDS::Repo::Bytes->new($sig) };
  my $commit_bytes = encode_dag_cbor($commit);
  my $commit_cid = ATProto::PDS::Repo::CID->for_dag_cbor($commit_bytes);
  my @record_paths = @{ $opts{record_paths} // [ sort keys %$records_by_path ] };
  my @repo_blocks = (
    { cid => $commit_cid, bytes => $commit_bytes },
    @{ $mst->{blocks} },
    map {
      my $record = $records_by_path->{$_};
      +{
        cid   => ATProto::PDS::Repo::CID->from_string($record->{cid}),
        bytes => $record->{record_bytes},
      }
    } @record_paths,
  );

  my %cars = map { $_ => 1 } @{ $opts{cars} // [] };
  my %artifacts = (
    rev         => $rev,
    root_cid    => $mst->{root}->to_string,
    mst         => $mst,
    commit_cid  => $commit_cid,
    commit_bytes => $commit_bytes,
    repo_blocks => \@repo_blocks,
  );
  $artifacts{snapshot_car_bytes} = write_car($commit_cid, \@repo_blocks)
    if $cars{snapshot};
  if ($cars{firehose}) {
    my @firehose_blocks = (
      { cid => $commit_cid, bytes => $commit_bytes },
      @{ $mst->{blocks} },
      map {
        my $record = $records_by_path->{$_};
        +{
          cid   => ATProto::PDS::Repo::CID->from_string($record->{cid}),
          bytes => $record->{record_bytes},
        }
      } @{ $opts{firehose_paths} // [] },
    );
    $artifacts{firehose_car_bytes} = write_car($commit_cid, \@firehose_blocks);
  }
  $artifacts{sync_car_bytes} = write_car($commit_cid, [
    { cid => $commit_cid, bytes => $commit_bytes },
  ]) if $cars{sync};
  return \%artifacts;
}

sub _firehose_record_paths ($ops) {
  my %paths = map {
    my $path = $_->{path} // q();
    (($_->{action} // q()) ne 'delete' && length $path) ? ($path => 1) : ();
  } @$ops;
  return [ sort keys %paths ];
}

sub _records_from_import ($root_cid, $blocks) {
  my @records;
  _walk_mst($root_cid, $blocks, \@records);
  return \@records;
}

sub _walk_mst ($cid, $blocks, $records) {
  return unless $cid;
  my $block = $blocks->{ _cid_string($cid) } or die {
    status  => 400,
    error   => 'InvalidRepoImport',
    message => 'missing MST block in imported CAR',
  };
  my $node = decode_dag_cbor($block->{bytes});
  _walk_mst($node->{l}, $blocks, $records) if $node->{l};

  my $previous = q();
  for my $entry (@{ $node->{e} || [] }) {
    my $suffix = blessed($entry->{k}) && $entry->{k}->isa('ATProto::PDS::Repo::Bytes')
      ? $entry->{k}->bytes
      : ($entry->{k} // q());
    my $path = substr($previous, 0, $entry->{p} // 0) . $suffix;
    my ($collection, $rkey) = split m{/}, $path, 2;
    die {
      status  => 400,
      error   => 'InvalidRepoImport',
      message => "invalid repo path '$path' in imported MST",
    } unless defined($collection) && length($collection) && defined($rkey) && length($rkey);

    my $record_cid = $entry->{v};
    my $record_block = $blocks->{ _cid_string($record_cid) } or die {
      status  => 400,
      error   => 'InvalidRepoImport',
      message => "missing record block for '$path' in imported CAR",
    };
    push @$records, {
      collection   => $collection,
      rkey         => $rkey,
      cid          => _cid_string($record_cid),
      value        => decode_dag_cbor($record_block->{bytes}),
      record_bytes => $record_block->{bytes},
      created_at   => time,
      updated_at   => time,
    };

    _walk_mst($entry->{t}, $blocks, $records) if $entry->{t};
    $previous = $path;
  }
}

sub _diff_record_sets ($previous, $imported) {
  my %paths = map { $_ => 1 } (keys %$previous, keys %$imported);
  my @ops;
  for my $path (sort keys %paths) {
    my $before = $previous->{$path};
    my $after  = $imported->{$path};
    if ($before && !$after) {
      push @ops, {
        action => 'delete',
        path   => $path,
        cid    => undef,
        prev   => $before->{cid},
      };
      next;
    }
    if (!$before && $after) {
      push @ops, {
        action => 'create',
        path   => $path,
        cid    => $after->{cid},
      };
      next;
    }
    next if ($before->{cid} // q()) eq ($after->{cid} // q());
    push @ops, {
      action => 'update',
      path   => $path,
      cid    => $after->{cid},
      prev   => $before->{cid},
    };
  }
  return @ops;
}

sub _cid_string ($cid) {
  return undef unless $cid;
  return $cid->to_string if blessed($cid) && $cid->isa('ATProto::PDS::Repo::CID');
  return $cid;
}

1;
