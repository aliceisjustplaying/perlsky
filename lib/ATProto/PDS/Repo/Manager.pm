package ATProto::PDS::Repo::Manager;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use JSON::PP qw(decode_json);
use Crypt::PK::Ed25519;

use ATProto::PDS::Repo::Bytes;
use ATProto::PDS::Repo::CAR qw(read_car write_car);
use ATProto::PDS::Repo::CID;
use ATProto::PDS::Repo::DagCbor qw(encode_dag_cbor);
use ATProto::PDS::Repo::MST qw(build_mst);
use ATProto::PDS::Util::BaseX qw(encode_base58btc);
use ATProto::PDS::Util::TID qw(next_tid);

sub new ($class, %args) {
  die 'store is required' unless $args{store};
  return bless \%args, $class;
}

sub store ($self) {
  return $self->{store};
}

sub generate_signing_key ($self) {
  my $pk = Crypt::PK::Ed25519->new;
  $pk->generate_key;
  my $private = $pk->export_key_raw('private');
  my $public  = $pk->export_key_raw('public');
  my $multibase = 'z' . encode_base58btc(pack('C*', 0xed, 0x01) . $public);
  return {
    private_key         => $private,
    public_key          => $public,
    public_key_multibase => $multibase,
  };
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
  my $pk = Crypt::PK::Ed25519->new;
  $pk->import_key_raw($account->{private_key}, 'private');
  my $sig = $pk->sign_message($unsigned_bytes);
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

1;
