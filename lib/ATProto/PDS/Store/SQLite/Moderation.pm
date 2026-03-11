package ATProto::PDS::Store::SQLite::Moderation;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';

our @EXPORT_OK = qw(
  create_report
  get_report
  get_subject_status
  list_subject_statuses
  put_subject_status
);

sub create_report ($self, %args) {
  my $now = $args{created_at} // time;
  $self->dbh->do(
    q{
      INSERT INTO moderation_reports (
        reason_type, reason, subject_json, reported_by, mod_tool_json, created_at
      ) VALUES (?, ?, ?, ?, ?, ?)
    },
    undef,
    $args{reason_type},
    $args{reason},
    ATProto::PDS::Store::SQLite::_maybe_json($args{subject}),
    $args{reported_by},
    ATProto::PDS::Store::SQLite::_maybe_json($args{mod_tool}),
    $now,
  );
  my $id = $self->dbh->sqlite_last_insert_rowid;
  return $self->get_report($id);
}

sub get_report ($self, $id) {
  my $row = $self->dbh->selectrow_hashref(
    q{SELECT * FROM moderation_reports WHERE id = ?},
    undef,
    $id,
  );
  return ATProto::PDS::Store::SQLite::_row_from_json_columns($row, qw(subject_json mod_tool_json));
}

sub put_subject_status ($self, %args) {
  my $subject_key = $args{subject_key} // die 'subject_key is required';
  my $now         = $args{updated_at} // time;
  $self->dbh->do(
    q{
      INSERT INTO subject_statuses (
        subject_key, subject_json, takedown_json, deactivated_json, updated_at
      ) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(subject_key) DO UPDATE SET
        subject_json = excluded.subject_json,
        takedown_json = excluded.takedown_json,
        deactivated_json = excluded.deactivated_json,
        updated_at = excluded.updated_at
    },
    undef,
    $subject_key,
    ATProto::PDS::Store::SQLite::_maybe_json($args{subject}),
    ATProto::PDS::Store::SQLite::_maybe_json($args{takedown}),
    ATProto::PDS::Store::SQLite::_maybe_json($args{deactivated}),
    $now,
  );
  return $self->get_subject_status($subject_key);
}

sub get_subject_status ($self, $subject_key) {
  my $row = $self->dbh->selectrow_hashref(
    q{SELECT * FROM subject_statuses WHERE subject_key = ?},
    undef,
    $subject_key,
  );
  return ATProto::PDS::Store::SQLite::_row_from_json_columns($row, qw(subject_json takedown_json deactivated_json));
}

sub list_subject_statuses ($self) {
  my $rows = $self->dbh->selectall_arrayref(
    q{SELECT * FROM subject_statuses ORDER BY updated_at DESC, subject_key ASC},
    { Slice => {} },
  );
  return [
    map {
      ATProto::PDS::Store::SQLite::_row_from_json_columns($_, qw(subject_json takedown_json deactivated_json))
    } @$rows
  ];
}

1;
