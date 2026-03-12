package ATProto::PDS::Store::SQLite::ActionTokens;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';

our @EXPORT_OK = qw(
  consume_action_token
  consume_action_tokens_by_did
  create_action_token
  get_action_token
  latest_action_token
);

sub create_action_token ($self, %args) {
  my $token   = $args{token}   // ATProto::PDS::Store::SQLite::_random_id();
  my $purpose = $args{purpose} // die 'purpose is required';
  my $now     = $args{created_at} // time;
  $self->dbh->do(
    q{
      INSERT INTO action_tokens (
        token, did, email, purpose, payload_json, created_at, expires_at, consumed_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    },
    undef,
    $token,
    $args{did},
    $args{email},
    $purpose,
    ATProto::PDS::Store::SQLite::_maybe_json($args{payload}),
    $now,
    $args{expires_at},
    $args{consumed_at},
  );
  return $self->get_action_token($token);
}

sub get_action_token ($self, $token) {
  my $row = $self->dbh->selectrow_hashref(
    q{SELECT * FROM action_tokens WHERE token = ?},
    undef,
    $token,
  );
  return ATProto::PDS::Store::SQLite::_row_from_json_columns($row, qw(payload_json));
}

sub consume_action_token ($self, $token, %args) {
  $self->dbh->do(
    q{UPDATE action_tokens SET consumed_at = ? WHERE token = ?},
    undef,
    $args{consumed_at} // time,
    $token,
  );
  return $self->get_action_token($token);
}

sub consume_action_tokens_by_did ($self, $did, %args) {
  my @where = ('did = ?', 'consumed_at IS NULL');
  my @bind = ($args{consumed_at} // time, $did);
  if (my $purposes = $args{purposes}) {
    if (ref($purposes) eq 'ARRAY' && @$purposes) {
      push @where, 'purpose IN (' . join(', ', ('?') x @$purposes) . ')';
      push @bind, @$purposes;
    }
  }
  $self->dbh->do(
    'UPDATE action_tokens SET consumed_at = ? WHERE ' . join(' AND ', @where),
    undef,
    @bind,
  );
  return;
}

sub latest_action_token ($self, %args) {
  my @where;
  my @bind;
  for my $pair (
    [ purpose => 'purpose' ],
    [ did     => 'did' ],
    [ email   => 'email' ],
  ) {
    my ($arg, $column) = @$pair;
    next unless defined $args{$arg};
    push @where, "$column = ?";
    push @bind, $args{$arg};
  }
  my $sql = q{SELECT * FROM action_tokens};
  $sql .= q{ WHERE } . join(q{ AND }, @where) if @where;
  $sql .= q{ ORDER BY created_at DESC, token DESC LIMIT 1};
  my $row = $self->dbh->selectrow_hashref($sql, undef, @bind);
  return ATProto::PDS::Store::SQLite::_row_from_json_columns($row, qw(payload_json));
}

1;
