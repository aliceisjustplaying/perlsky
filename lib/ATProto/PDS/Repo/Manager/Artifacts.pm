package ATProto::PDS::Repo::Manager::Artifacts;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';

use ATProto::PDS::Crypto::Secp256k1 qw(sign_compact_low_s);
use ATProto::PDS::Repo::Bytes;
use ATProto::PDS::Repo::CAR qw(write_car);
use ATProto::PDS::Repo::CID;
use ATProto::PDS::Repo::DagCbor qw(encode_dag_cbor);
use ATProto::PDS::Repo::MST qw(build_mst);
use ATProto::PDS::Util::TID qw(next_tid);

our @EXPORT_OK = qw(
  _build_commit_artifacts
  _build_snapshot_car
  _firehose_record_paths
  sync_car_for_commit
);

sub sync_car_for_commit ($self, $commit) {
  return undef unless $commit && defined($commit->{commit_bytes});
  return write_car(
    ATProto::PDS::Repo::CID->from_string($commit->{cid}),
    [{
      cid   => ATProto::PDS::Repo::CID->from_string($commit->{cid}),
      bytes => $commit->{commit_bytes},
    }],
  );
}

sub _build_snapshot_car ($self, $account, $records, $rev = undef) {
  my %records_by_path = map {
    $_->{collection} . '/' . $_->{rkey} => $_
  } @$records;
  my $artifacts = $self->_build_commit_artifacts(
    $account,
    \%records_by_path,
    rev          => $rev // next_tid(),
    record_paths => [ sort keys %records_by_path ],
    cars         => [ 'snapshot' ],
  );
  return $artifacts->{snapshot_car_bytes};
}

sub _build_commit_artifacts ($self, $account, $records_by_path, %opts) {
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
    rev          => $rev,
    root_cid     => $mst->{root}->to_string,
    mst          => $mst,
    commit_cid   => $commit_cid,
    commit_bytes => $commit_bytes,
    repo_blocks  => \@repo_blocks,
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
  $artifacts{sync_car_bytes} = $self->sync_car_for_commit({
    cid          => $commit_cid->to_string,
    commit_bytes => $commit_bytes,
  }) if $cars{sync};
  return \%artifacts;
}

sub _firehose_record_paths ($ops) {
  my %paths = map {
    my $path = $_->{path} // q();
    (($_->{action} // q()) ne 'delete' && length $path) ? ($path => 1) : ();
  } @$ops;
  return [ sort keys %paths ];
}

1;
