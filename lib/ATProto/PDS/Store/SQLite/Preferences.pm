package ATProto::PDS::Store::SQLite::Preferences;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';

use JSON::PP qw(decode_json encode_json);

our @EXPORT_OK = qw(
  get_notification_preferences
  list_preferences
  put_notification_preferences
  put_preferences
);

sub put_preferences ($self, $did, $namespace, $preferences, %args) {
  die 'did is required' unless defined $did && length $did;
  die 'namespace is required' unless defined $namespace && length $namespace;
  die 'preferences must be an arrayref' unless ref($preferences) eq 'ARRAY';

  my $now = $args{updated_at} // time;
  $self->txn(sub ($dbh) {
    $dbh->do(
      q{DELETE FROM preferences WHERE did = ? AND namespace = ?},
      undef,
      $did,
      $namespace,
    );

    for my $pref (@$preferences) {
      next unless ref($pref) eq 'HASH';
      my $type = $pref->{'$type'} // next;
      $dbh->do(
        q{
          INSERT INTO preferences (
            did, namespace, pref_type, pref_json, updated_at
          ) VALUES (?, ?, ?, ?, ?)
        },
        undef,
        $did,
        $namespace,
        $type,
        encode_json($pref),
        $now,
      );
    }
  });

  return $self->list_preferences($did, $namespace);
}

sub list_preferences ($self, $did, $namespace) {
  die 'did is required' unless defined $did && length $did;
  die 'namespace is required' unless defined $namespace && length $namespace;

  my $rows = $self->dbh->selectall_arrayref(
    q{
      SELECT pref_json
      FROM preferences
      WHERE did = ? AND namespace = ?
      ORDER BY pref_type ASC
    },
    { Slice => {} },
    $did,
    $namespace,
  );
  return [ map { decode_json($_->{pref_json}) } @$rows ];
}

sub put_notification_preferences ($self, $did, $preferences, %args) {
  die 'did is required' unless defined $did && length $did;
  die 'preferences must be a hashref' unless ref($preferences) eq 'HASH';

  my $now = $args{updated_at} // time;
  my $pref_type = 'app.bsky.notification.defs#preferences';
  my $json = encode_json($preferences);
  $self->txn(sub ($dbh) {
    $dbh->do(
      q{DELETE FROM preferences WHERE did = ? AND namespace = ?},
      undef,
      $did,
      'app.bsky.notification',
    );
    $dbh->do(
      q{
        INSERT INTO preferences (
          did, namespace, pref_type, pref_json, updated_at
        ) VALUES (?, ?, ?, ?, ?)
      },
      undef,
      $did,
      'app.bsky.notification',
      $pref_type,
      $json,
      $now,
    );
  });

  return $self->get_notification_preferences($did);
}

sub get_notification_preferences ($self, $did) {
  die 'did is required' unless defined $did && length $did;

  my $row = $self->dbh->selectrow_hashref(
    q{
      SELECT pref_json
      FROM preferences
      WHERE did = ? AND namespace = ?
      ORDER BY updated_at DESC, pref_type ASC
      LIMIT 1
    },
    undef,
    $did,
    'app.bsky.notification',
  );

  return undef unless $row;
  return decode_json($row->{pref_json});
}

1;
