package ATProto::PDS::Store::SQLite::Preferences;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';

use JSON::PP qw(decode_json encode_json);

our @EXPORT_OK = qw(
  list_preferences
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

1;
