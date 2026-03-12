package ATProto::PDS::Repo::Manager;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use JSON::PP qw(encode_json);

use ATProto::PDS::Crypto::Secp256k1 qw(generate_keypair sign_compact_low_s);
use ATProto::PDS::API::Util qw(xrpc_error);
use ATProto::PDS::Constants qw(EVENT_TYPE_COMMIT);
use ATProto::PDS::Repo::Bytes;
use ATProto::PDS::Repo::CAR qw(read_car write_car);
use ATProto::PDS::Repo::CID;
use ATProto::PDS::Repo::DagCbor qw(decode_dag_cbor encode_dag_cbor);
use ATProto::PDS::Repo::Manager::Artifacts qw(
  _build_commit_artifacts
  _build_snapshot_car
  _firehose_record_paths
  sync_car_for_commit
);
use ATProto::PDS::Repo::Manager::Import qw(
  _cid_string
  _diff_record_sets
  _records_from_import
  _repair_records_for_repo
  _rewrite_owned_at_uris
  _walk_mst
  import_repo_car
  repair_invalid_tids
);
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
        repo_rev    => $_->{repo_rev},
        record_bytes => $_->{record_bytes},
      }
    } @{ $store->all_records_for_did($did) }
  };
  my %previous_records = map { $_ => { %{ $records->{$_} } } } keys %$records;

  my @results;
  my @ops;
  for my $write (@$writes) {
    my $action = $write->{action} // '';
    my $collection = $write->{collection};
    my $rkey = $write->{rkey} // next_tid();
    my $path = $collection . '/' . $rkey;
    my $previous = $previous_records{$path};
    my $current_cid = $previous ? $previous->{cid} : undef;

    if ($write->{swap_record_present}) {
      my $swap_record = $write->{swap_record};
      die {
        status  => 400,
        error   => 'InvalidSwap',
        message => 'swapRecord did not match the current record',
      } if $action eq 'create' && defined $swap_record;
      die {
        status  => 400,
        error   => 'InvalidSwap',
        message => 'swapRecord did not match the current record',
      } if ($action eq 'update' || $action eq 'delete') && !defined $swap_record;
      my $mismatch = (defined($current_cid) || defined($swap_record))
        && (!defined($current_cid) || !defined($swap_record) || $current_cid ne $swap_record);
      die {
        status  => 400,
        error   => 'InvalidSwap',
        message => 'swapRecord did not match the current record',
      } if $mismatch;
    }

    if ($action eq 'delete') {
      xrpc_error(400, 'InvalidRequest', 'Could not locate record: at://' . $did . '/' . $path)
        unless $previous;
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

    if ($action eq 'create') {
      xrpc_error(400, 'InvalidRequest', "There is already a value at key: $path")
        if $previous;
    } elsif ($action eq 'update') {
      xrpc_error(400, 'InvalidRequest', 'Could not locate record: at://' . $did . '/' . $path)
        unless $previous;
    } else {
      xrpc_error(400, 'InvalidRequest', "Action not supported: $action");
    }

    my $bytes = encode_dag_cbor($value);
    my $cid = ATProto::PDS::Repo::CID->for_dag_cbor($bytes);
    $records->{$path} = {
      collection   => $collection,
      rkey         => $rkey,
      cid          => $cid->to_string,
      value        => $value,
      record_bytes => $bytes,
    };
    push @results, {
      '$type'           => 'com.atproto.repo.applyWrites#' . ($action eq 'create' ? 'create' : 'update') . 'Result',
      uri              => "at://$did/$collection/$rkey",
      cid              => $cid->to_string,
      validationStatus => 'unknown',
    };
    push @ops, {
      action => $action,
      path   => $path,
      cid    => $cid->to_string,
      ($previous ? (prev => $previous->{cid}) : ()),
    };
  }

  my $artifacts = $self->_build_commit_artifacts(
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

  for my $op (@ops) {
    next if ($op->{action} // q()) eq 'delete';
    next unless $records->{ $op->{path} };
    $records->{ $op->{path} }{repo_rev} = $rev;
  }

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
        type       => EVENT_TYPE_COMMIT,
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

1;
