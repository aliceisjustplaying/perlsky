package ATProto::PDS::Repo::Manager;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use JSON::PP qw(decode_json);
use Scalar::Util qw(blessed);

use ATProto::PDS::Crypto::Secp256k1 qw(generate_keypair sign_compact_low_s);
use ATProto::PDS::API::Util qw(xrpc_error);
use ATProto::PDS::Repo::Bytes;
use ATProto::PDS::Repo::CAR qw(read_car write_car);
use ATProto::PDS::Repo::CID;
use ATProto::PDS::Repo::DagCbor qw(decode_dag_cbor encode_dag_cbor);
use ATProto::PDS::Repo::MST qw(build_mst);
use ATProto::PDS::Util::TID qw(next_tid);

sub new ($class, %args) {
  die 'store is required' unless $args{store};
  return bless \%args, $class;
}

sub store ($self) {
  return $self->{store};
}

sub generate_signing_key ($self) {
  return generate_keypair();
}

sub initialize_repo ($self, $account) {
  return $self->apply_writes($account, []);
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
      push @results, {};
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
      } unless $blob && ($blob->{did} // q()) eq $did;
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

  my %mst_input = map {
    $_ => ATProto::PDS::Repo::CID->from_string($records->{$_}{cid})
  } sort keys %$records;
  my $mst = build_mst(\%mst_input);

  my $rev = next_tid($latest ? $latest->{rev} : undef);
  my $unsigned = {
    did     => $did,
    version => 3,
    data    => $mst->{root},
    rev     => $rev,
    prev    => $latest ? ATProto::PDS::Repo::CID->from_string($latest->{cid}) : undef,
  };
  my $unsigned_bytes = encode_dag_cbor($unsigned);
  my $sig = sign_compact_low_s($account->{private_key}, $unsigned_bytes);
  my $commit = { %$unsigned, sig => ATProto::PDS::Repo::Bytes->new($sig) };
  my $commit_bytes = encode_dag_cbor($commit);
  my $commit_cid = ATProto::PDS::Repo::CID->for_dag_cbor($commit_bytes);

  my @blocks = (
    { cid => $commit_cid, bytes => $commit_bytes },
    @{ $mst->{blocks} },
    map {
      +{
        cid   => ATProto::PDS::Repo::CID->from_string($_->{cid}),
        bytes => $_->{record_bytes},
      }
    } values %$records,
  );
  my $car_bytes = write_car($commit_cid, \@blocks);

  $store->txn(sub ($dbh) {
    for my $block (@blocks) {
      $store->put_block(
        cid   => $block->{cid}->to_string,
        codec => $block->{cid}->codec,
        bytes => $block->{bytes},
      );
    }
    $store->replace_records_for_did($did, [ values %$records ]);
    for my $record (values %$records) {
      $store->mark_blobs_referenced(_blob_cids($record->{value}));
    }
    $store->put_commit(
      did         => $did,
      rev         => $rev,
      cid         => $commit_cid->to_string,
      root_cid    => $mst->{root}->to_string,
      prev_cid    => $latest ? $latest->{cid} : undef,
      commit_bytes => $commit_bytes,
      car_bytes   => $car_bytes,
    );
    $store->append_event(
      did        => $did,
      type       => 'commit',
      rev        => $rev,
      commit_cid => $commit_cid->to_string,
      payload    => {
        ops      => \@ops,
        since    => undef,
        prevData => $latest ? $latest->{root_cid} : undef,
      },
      car_bytes  => $car_bytes,
    );
  });

  return {
    cid      => $commit_cid->to_string,
    rev      => $rev,
    root_cid => $mst->{root}->to_string,
    car_bytes => $car_bytes,
    results  => \@results,
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
  my %mst_input = map {
    $_->{collection} . '/' . $_->{rkey} => ATProto::PDS::Repo::CID->from_string($_->{cid})
  } @$records;
  my $mst = build_mst(\%mst_input);
  my $rev = next_tid($latest ? $latest->{rev} : undef);
  my $unsigned = {
    did     => $did,
    version => 3,
    data    => $mst->{root},
    rev     => $rev,
    prev    => $latest ? ATProto::PDS::Repo::CID->from_string($latest->{cid}) : undef,
  };
  my $unsigned_bytes = encode_dag_cbor($unsigned);
  my $sig = sign_compact_low_s($account->{private_key}, $unsigned_bytes);
  my $next_commit = { %$unsigned, sig => ATProto::PDS::Repo::Bytes->new($sig) };
  my $commit_bytes = encode_dag_cbor($next_commit);
  my $commit_cid = ATProto::PDS::Repo::CID->for_dag_cbor($commit_bytes);
  my $root_cid = $mst->{root}->to_string;
  my @repo_blocks = (
    { cid => $commit_cid, bytes => $commit_bytes },
    @{ $mst->{blocks} },
    map {
      +{
        cid   => ATProto::PDS::Repo::CID->from_string($_->{cid}),
        bytes => $_->{record_bytes},
      }
    } @$records,
  );
  my $next_car_bytes = write_car($commit_cid, \@repo_blocks);

  $store->txn(sub ($dbh) {
    for my $block (values %blocks, @repo_blocks) {
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
      car_bytes    => $next_car_bytes,
    );
    $store->append_event(
      did        => $did,
      type       => 'commit',
      rev        => $rev,
      commit_cid => $commit_cid->to_string,
      payload    => {
        ops      => \@ops,
        since    => undef,
        prevData => $prev_data,
      },
      car_bytes  => $next_car_bytes,
    );
  });

  return {
    cid      => $commit_cid->to_string,
    rev      => $rev,
    root_cid => $root_cid,
    records  => $records,
  };
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
