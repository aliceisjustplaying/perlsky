package ATProto::PDS::Repo::Manager::Import;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use Scalar::Util qw(blessed);

use ATProto::PDS::Constants qw(EVENT_TYPE_COMMIT);
use ATProto::PDS::Repo::Manager::Artifacts qw(_firehose_record_paths);
use ATProto::PDS::Repo::CAR qw(read_car);
use ATProto::PDS::Repo::CID;
use ATProto::PDS::Repo::DagCbor qw(decode_dag_cbor encode_dag_cbor);
use ATProto::PDS::Util::TID qw(is_valid_tid next_tid repair_tid);

our @EXPORT_OK = qw(
  _cid_string
  _diff_record_sets
  _records_from_import
  _repair_records_for_repo
  _rewrite_owned_at_uris
  _walk_mst
  import_repo_car
  repair_invalid_tids
);

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

  my $records = _records_from_import($commit->{data}, \%blocks, $commit->{rev});
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
  my $artifacts = $self->_build_commit_artifacts(
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
      type       => EVENT_TYPE_COMMIT,
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

  my $snapshot_car = $self->_build_snapshot_car(
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
      repo_rev     => $account->{repo_rev},
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

sub _records_from_import ($root_cid, $blocks, $import_rev = undef) {
  my @records;
  _walk_mst($root_cid, $blocks, \@records, $import_rev);
  return \@records;
}

sub _walk_mst ($cid, $blocks, $records, $import_rev = undef) {
  return unless $cid;
  my $block = $blocks->{ _cid_string($cid) } or die {
    status  => 400,
    error   => 'InvalidRepoImport',
    message => 'missing MST block in imported CAR',
  };
  my $node = decode_dag_cbor($block->{bytes});
    _walk_mst($node->{l}, $blocks, $records, $import_rev) if $node->{l};

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
      repo_rev     => $import_rev,
      created_at   => time,
      updated_at   => time,
    };

    _walk_mst($entry->{t}, $blocks, $records, $import_rev) if $entry->{t};
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
