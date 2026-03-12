package ATProto::PDS::Store::SQLite::Invites;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';

our @EXPORT_OK = qw(
  create_invite_code
  disable_invite_codes
  get_invite_code
  get_invited_by_for_account
  list_invite_code_uses
  list_invite_codes
  list_invite_codes_for_account
  record_invite_code_use
);

sub create_invite_code ($self, %args) {
  my $code = $args{code} // die 'code is required';
  my $now  = $args{created_at} // time;
  $self->dbh->do(
    q{
      INSERT INTO invite_codes (
        code, for_account, created_by, use_count, disabled, note, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
    },
    undef,
    $code,
    $args{for_account},
    $args{created_by},
    $args{use_count} // 1,
    $args{disabled} ? 1 : 0,
    $args{note},
    $now,
  );
  return $self->get_invite_code($code);
}

sub get_invite_code ($self, $code) {
  my $row = $self->dbh->selectrow_hashref(
    q{SELECT * FROM invite_codes WHERE code = ?},
    undef,
    $code,
  );
  return undef unless $row;
  my $uses = $self->dbh->selectrow_array(
    q{SELECT COUNT(*) FROM invite_code_uses WHERE code = ?},
    undef,
    $code,
  ) // 0;
  $row->{use_count_consumed} = $uses;
  return $row;
}

sub list_invite_codes ($self, %args) {
  my $limit = $args{limit} // 100;
  $limit = 500 if $limit > 500;
  my $cursor = $args{cursor};
  my $sort = $args{sort} // 'recent';
  my @bind;
  my @where;
  my $sql = q{
    SELECT invite_codes.*, COUNT(invite_code_uses.code) AS use_count_consumed
    FROM invite_codes
    LEFT JOIN invite_code_uses ON invite_code_uses.code = invite_codes.code
  };
  if ($sort eq 'usage') {
    if (defined $cursor && length $cursor) {
      my ($cursor_use_count, $cursor_code) = ATProto::PDS::Store::SQLite::_parse_usage_cursor($cursor);
      push @where, q{(invite_codes.use_count < ? OR (invite_codes.use_count = ? AND invite_codes.code > ?))};
      push @bind, $cursor_use_count, $cursor_use_count, $cursor_code;
    }
    $sql .= q{ WHERE } . join(q{ AND }, @where) if @where;
    $sql .= q{ GROUP BY invite_codes.code ORDER BY invite_codes.use_count DESC, invite_codes.code ASC};
  } else {
    if (defined $cursor && length $cursor) {
      push @where, q{invite_codes.code > ?};
      push @bind, $cursor;
    }
    $sql .= q{ WHERE } . join(q{ AND }, @where) if @where;
    $sql .= q{ GROUP BY invite_codes.code ORDER BY invite_codes.created_at DESC, invite_codes.code DESC};
  }
  $sql .= q{ LIMIT ?};
  push @bind, $limit + 1;
  my $rows = $self->dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
  return ATProto::PDS::Store::SQLite::_paginate(
    $rows,
    $limit,
    $sort eq 'usage'
      ? sub ($row) { ATProto::PDS::Store::SQLite::_usage_cursor($row->{use_count}, $row->{code}) }
      : 'code',
  );
}

sub list_invite_codes_for_account ($self, $did) {
  return $self->dbh->selectall_arrayref(
    q{
      SELECT invite_codes.*, COUNT(invite_code_uses.code) AS use_count_consumed
      FROM invite_codes
      LEFT JOIN invite_code_uses ON invite_code_uses.code = invite_codes.code
      WHERE invite_codes.for_account = ?
      GROUP BY invite_codes.code
      ORDER BY invite_codes.created_at DESC, invite_codes.code DESC
    },
    { Slice => {} },
    $did,
  );
}

sub get_invited_by_for_account ($self, $did) {
  my $rows = $self->dbh->selectall_arrayref(
    q{
      SELECT invite_codes.*, COUNT(all_uses.code) AS use_count_consumed
      FROM invite_code_uses AS used
      JOIN invite_codes ON invite_codes.code = used.code
      LEFT JOIN invite_code_uses AS all_uses ON all_uses.code = invite_codes.code
      WHERE used.used_by = ?
      GROUP BY invite_codes.code, invite_codes.for_account, invite_codes.created_by,
               invite_codes.use_count, invite_codes.disabled, invite_codes.note, invite_codes.created_at
      ORDER BY used.used_at ASC, invite_codes.code ASC
      LIMIT 1
    },
    { Slice => {} },
    $did,
  );
  return $rows && @$rows ? $rows->[0] : undef;
}

sub record_invite_code_use ($self, %args) {
  my $code    = $args{code}    // die 'code is required';
  my $used_by = $args{used_by} // die 'used_by is required';
  my $used_at = $args{used_at} // time;
  $self->dbh->do(
    q{
      INSERT INTO invite_code_uses (code, used_by, used_at)
      VALUES (?, ?, ?)
      ON CONFLICT(code, used_by) DO UPDATE SET
        used_at = excluded.used_at
    },
    undef,
    $code,
    $used_by,
    $used_at,
  );
  return $self->list_invite_code_uses($code);
}

sub list_invite_code_uses ($self, $code) {
  return $self->dbh->selectall_arrayref(
    q{SELECT * FROM invite_code_uses WHERE code = ? ORDER BY used_at ASC, used_by ASC},
    { Slice => {} },
    $code,
  );
}

sub disable_invite_codes ($self, %args) {
  my $now = $args{updated_at} // time;
  if (my $codes = $args{codes}) {
    return [] unless @$codes;
    my $placeholders = join(', ', ('?') x @$codes);
    $self->dbh->do(
      "UPDATE invite_codes SET disabled = 1, note = COALESCE(?, note) WHERE code IN ($placeholders)",
      undef,
      $args{note},
      @$codes,
    );
  }
  if (my $accounts = $args{accounts}) {
    return [] unless @$accounts;
    my $placeholders = join(', ', ('?') x @$accounts);
    $self->dbh->do(
      "UPDATE invite_codes SET disabled = 1, note = COALESCE(?, note) WHERE for_account IN ($placeholders)",
      undef,
      $args{note},
      @$accounts,
    );
  }
  return $now;
}

1;
