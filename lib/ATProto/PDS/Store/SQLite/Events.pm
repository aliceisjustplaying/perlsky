package ATProto::PDS::Store::SQLite::Events;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';

use ATProto::PDS::Metrics::Store qw(observe_store_operation);

our @EXPORT_OK = qw(
  append_event
  list_events_after
  list_events_from
  next_event_after_seq
  latest_event_seq
  earliest_event_seq_after_time
);

sub append_event ($self, %args) {
  return observe_store_operation($self->{metrics}, 'append_event', sub {
    my $now = $args{created_at} // time;
    ATProto::PDS::Store::SQLite::_execute_sql(
      $self->dbh,
      q{
        INSERT INTO events (
          did, type, rev, commit_cid, payload_json, car_bytes, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
      },
      [
        $args{did},
        $args{type},
        $args{rev},
        $args{commit_cid},
        ATProto::PDS::Store::SQLite::_maybe_json($args{payload}),
        $args{car_bytes},
        $now,
      ],
      ATProto::PDS::Store::SQLite::_blob_bind_positions_for_names(
        [qw(did type rev commit_cid payload_json car_bytes created_at)],
        qw(car_bytes),
      ),
    );
    return $self->dbh->sqlite_last_insert_rowid;
  });
}

sub list_events_after ($self, $cursor, %args) {
  my $limit = $args{limit} // 100;
  my $sql = q{SELECT * FROM events WHERE seq > ? ORDER BY seq LIMIT ?};
  my $rows = $self->dbh->selectall_arrayref($sql, { Slice => {} }, $cursor // 0, $limit);
  return [
    map {
      ATProto::PDS::Store::SQLite::_row_from_blob_columns(
        ATProto::PDS::Store::SQLite::_row_from_json_columns($_, qw(payload_json)),
        qw(car_bytes),
      )
    } @$rows
  ];
}

sub list_events_from ($self, $cursor, %args) {
  return observe_store_operation($self->{metrics}, 'list_events_from', sub {
    my $limit = $args{limit} // 100;
    my $sql = q{SELECT * FROM events WHERE seq >= ? ORDER BY seq LIMIT ?};
    my $rows = $self->dbh->selectall_arrayref($sql, { Slice => {} }, $cursor // 0, $limit);
    return [
      map {
        ATProto::PDS::Store::SQLite::_row_from_blob_columns(
          ATProto::PDS::Store::SQLite::_row_from_json_columns($_, qw(payload_json)),
          qw(car_bytes),
        )
      } @$rows
    ];
  });
}

sub next_event_after_seq ($self, $cursor) {
  return observe_store_operation($self->{metrics}, 'next_event_after_seq', sub {
    return ATProto::PDS::Store::SQLite::_row_from_blob_columns(
      ATProto::PDS::Store::SQLite::_row_from_json_columns(
        $self->dbh->selectrow_hashref(
          q{SELECT * FROM events WHERE seq > ? ORDER BY seq LIMIT 1},
          undef,
          $cursor // 0,
        ),
        qw(payload_json),
      ),
      qw(car_bytes),
    );
  });
}

sub latest_event_seq ($self) {
  return observe_store_operation($self->{metrics}, 'latest_event_seq', sub {
    return $self->dbh->selectrow_array(
      q{SELECT COALESCE(MAX(seq), 0) FROM events},
    ) // 0;
  });
}

sub earliest_event_seq_after_time ($self, $created_at) {
  return observe_store_operation($self->{metrics}, 'earliest_event_seq_after_time', sub {
    my $value = $self->dbh->selectrow_array(
      q{SELECT MIN(seq) FROM events WHERE created_at >= ?},
      undef,
      $created_at,
    );
    return $value;
  });
}

1;
