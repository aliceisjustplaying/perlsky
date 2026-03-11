package ATProto::PDS::Store::SQLite::Reservations;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';

our @EXPORT_OK = qw(
  claim_reserved_signing_key
  get_reserved_handle
  get_reserved_signing_key
  list_reserved_handles
  reserve_handle
  reserve_signing_key
);

sub reserve_signing_key ($self, %args) {
  my $did = $args{did} // die 'did is required';
  my $now = $args{created_at} // time;
  ATProto::PDS::Store::SQLite::_execute_sql(
    $self->dbh,
    q{
      INSERT INTO reserved_signing_keys (
        did, private_key, public_key, public_key_multibase, signing_key_did, created_at, claimed_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(did) DO UPDATE SET
        private_key = excluded.private_key,
        public_key = excluded.public_key,
        public_key_multibase = excluded.public_key_multibase,
        signing_key_did = excluded.signing_key_did,
        created_at = excluded.created_at,
        claimed_at = excluded.claimed_at
    },
    [
      $did,
      $args{private_key},
      $args{public_key},
      $args{public_key_multibase},
      $args{signing_key_did},
      $now,
      $args{claimed_at},
    ],
    ATProto::PDS::Store::SQLite::_blob_bind_positions_for_names(
      [qw(
        did private_key public_key public_key_multibase signing_key_did
        created_at claimed_at
      )],
      qw(private_key public_key),
    ),
  );
  return $self->get_reserved_signing_key($did);
}

sub get_reserved_signing_key ($self, $did) {
  return ATProto::PDS::Store::SQLite::_row_from_blob_columns(
    $self->dbh->selectrow_hashref(
      q{SELECT * FROM reserved_signing_keys WHERE did = ?},
      undef,
      $did,
    ),
    qw(private_key public_key),
  );
}

sub claim_reserved_signing_key ($self, $did, %args) {
  $self->dbh->do(
    q{UPDATE reserved_signing_keys SET claimed_at = ? WHERE did = ?},
    undef,
    $args{claimed_at} // time,
    $did,
  );
  return $self->get_reserved_signing_key($did);
}

sub reserve_handle ($self, $handle, %args) {
  my $now = $args{created_at} // time;
  $self->dbh->do(
    q{
      INSERT INTO reserved_handles (handle, note, created_at)
      VALUES (?, ?, ?)
      ON CONFLICT(handle) DO UPDATE SET
        note = excluded.note
    },
    undef,
    $handle,
    $args{note},
    $now,
  );
  return $self->get_reserved_handle($handle);
}

sub get_reserved_handle ($self, $handle) {
  return $self->dbh->selectrow_hashref(
    q{SELECT * FROM reserved_handles WHERE handle = ?},
    undef,
    $handle,
  );
}

sub list_reserved_handles ($self) {
  return $self->dbh->selectall_arrayref(
    q{SELECT * FROM reserved_handles ORDER BY handle},
    { Slice => {} },
  );
}

1;
