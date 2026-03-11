package ATProto::PDS::Store::SQLite::Operations;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';

our @EXPORT_OK = qw(
  get_host_notice
  get_repo_head
  list_host_notices
  log_outbound_email
  set_repo_head
  touch_host_notice
);

sub log_outbound_email ($self, %args) {
  my $now = $args{created_at} // time;
  $self->dbh->do(
    q{
      INSERT INTO outbound_emails (
        recipient_did, recipient_email, sender_did, subject, content, comment, sent, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    },
    undef,
    $args{recipient_did},
    $args{recipient_email},
    $args{sender_did},
    $args{subject},
    $args{content},
    $args{comment},
    $args{sent} ? 1 : 0,
    $now,
  );
  return $self->dbh->sqlite_last_insert_rowid;
}

sub touch_host_notice ($self, %args) {
  my $hostname = $args{hostname} // die 'hostname is required';
  my $now      = time;
  my $requested_at = $args{requested_at};
  my $notified_at  = $args{notified_at};
  $self->dbh->do(
    q{
      INSERT INTO crawl_hosts (
        hostname, requested_at, notified_at, last_seq, status_json
      ) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(hostname) DO UPDATE SET
        requested_at = COALESCE(excluded.requested_at, crawl_hosts.requested_at),
        notified_at = COALESCE(excluded.notified_at, crawl_hosts.notified_at),
        last_seq = COALESCE(excluded.last_seq, crawl_hosts.last_seq),
        status_json = COALESCE(excluded.status_json, crawl_hosts.status_json)
    },
    undef,
    $hostname,
    $requested_at,
    $notified_at,
    $args{last_seq},
    ATProto::PDS::Store::SQLite::_maybe_json($args{status}),
  );
  return $now && $self->get_host_notice($hostname);
}

sub get_host_notice ($self, $hostname) {
  my $row = $self->dbh->selectrow_hashref(
    q{SELECT * FROM crawl_hosts WHERE hostname = ?},
    undef,
    $hostname,
  );
  return ATProto::PDS::Store::SQLite::_row_from_json_columns($row, qw(status_json));
}

sub list_host_notices ($self, %args) {
  my $limit = $args{limit} // 200;
  $limit = 1000 if $limit > 1000;
  my $cursor = $args{cursor};
  my @bind;
  my $sql = q{SELECT * FROM crawl_hosts};
  if (defined $cursor && length $cursor) {
    $sql .= q{ WHERE hostname > ?};
    push @bind, $cursor;
  }
  $sql .= q{ ORDER BY hostname LIMIT ?};
  push @bind, $limit + 1;
  my $rows = $self->dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
  my $page = ATProto::PDS::Store::SQLite::_paginate($rows, $limit, 'hostname');
  $page->{items} = [
    map { ATProto::PDS::Store::SQLite::_row_from_json_columns($_, qw(status_json)) } @{ $page->{items} }
  ];
  return $page;
}

sub set_repo_head ($self, %args) {
  my $did = $args{did} // die 'did is required';
  my $now = $args{indexed_at} // time;
  $self->dbh->do(
    q{
      INSERT INTO repo_heads (did, indexed_at)
      VALUES (?, ?)
      ON CONFLICT(did) DO UPDATE SET
        commit_cid = NULL,
        rev = NULL,
        root_cid = NULL,
        indexed_at = excluded.indexed_at
    },
    undef,
    $did,
    $now,
  );
  $self->dbh->do(
    q{
      UPDATE accounts
      SET repo_commit_cid = ?, repo_root_cid = ?, repo_rev = ?, updated_at = ?
      WHERE did = ?
    },
    undef,
    $args{commit_cid},
    $args{root_cid},
    $args{rev},
    $now,
    $did,
  );
  return {
    did        => $did,
    commit_cid => $args{commit_cid},
    rev        => $args{rev},
    root_cid   => $args{root_cid},
    indexed_at => $now,
  };
}

sub get_repo_head ($self, $did) {
  return $self->dbh->selectrow_hashref(
    q{
      SELECT
        accounts.did,
        accounts.repo_commit_cid AS commit_cid,
        accounts.repo_rev AS rev,
        accounts.repo_root_cid AS root_cid,
        repo_heads.indexed_at
      FROM accounts
      LEFT JOIN repo_heads ON repo_heads.did = accounts.did
      WHERE accounts.did = ? AND accounts.repo_commit_cid IS NOT NULL
    },
    undef,
    $did,
  );
}

1;
