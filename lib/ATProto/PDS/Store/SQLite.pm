package ATProto::PDS::Store::SQLite;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use DBI;
use Exporter 'import';
use File::Basename qw(dirname);
use File::Path qw(make_path);
use JSON::PP qw(decode_json encode_json);

our @EXPORT_OK = qw(default_migrations);

sub new ($class, %args) {
  die 'path is required' unless defined $args{path} && length $args{path};
  return bless {
    path => $args{path},
    dbh  => undef,
  }, $class;
}

sub path ($self) {
  return $self->{path};
}

sub dbh ($self) {
  return $self->{dbh} ||= $self->_connect;
}

sub bootstrap ($self) {
  $self->migrate;
  return $self;
}

sub migrate ($self) {
  my $dbh = $self->dbh;
  $dbh->do(q{
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version INTEGER PRIMARY KEY,
      applied_at INTEGER NOT NULL
    )
  });

  my %applied = map { $_->{version} => 1 } @{ $dbh->selectall_arrayref(
    q{SELECT version FROM schema_migrations ORDER BY version},
    { Slice => {} },
  ) };

  for my $migration (default_migrations()) {
    next if $applied{ $migration->{version} };
    $self->txn(sub ($txn) {
      $txn->do($_) for @{ $migration->{statements} };
      $txn->do(
        q{INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)},
        undef,
        $migration->{version},
        time,
      );
    });
  }

  return 1;
}

sub close ($self) {
  return unless $self->{dbh};
  $self->{dbh}->disconnect;
  $self->{dbh} = undef;
}

sub txn ($self, $code) {
  my $dbh = $self->dbh;
  $dbh->begin_work;
  my $wantarray = wantarray;
  my @result;
  my $ok = eval {
    if (!defined $wantarray) {
      $code->($dbh);
    } elsif ($wantarray) {
      @result = $code->($dbh);
    } else {
      $result[0] = $code->($dbh);
    }
    1;
  };
  if (!$ok) {
    my $err = $@ || 'transaction failed';
    eval { $dbh->rollback };
    die $err;
  }
  $dbh->commit;
  return if !defined $wantarray;
  return $wantarray ? @result : $result[0];
}

sub create_account ($self, %args) {
  my $did        = $args{did}        // die 'did is required';
  my $account_id = $args{account_id} // $args{id} // _random_id();
  my $handle     = $args{handle}     // die 'handle is required';
  my $now        = $args{created_at} // time;

  $self->dbh->do(
    q{
      INSERT INTO accounts (
        id, account_id, did, handle, email, password_hash, password_salt,
        created_at, updated_at, deactivated_at, deleted_at,
        did_doc_json, private_key, public_key, public_key_multibase,
        repo_commit_cid, repo_root_cid, repo_rev
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    },
    undef,
    $account_id,
    $account_id,
    $did,
    $handle,
    $args{email},
    $args{password_hash},
    $args{password_salt},
    $now,
    $now,
    $args{deactivated_at},
    $args{deleted_at},
    _maybe_json($args{did_doc}),
    $args{private_key},
    $args{public_key},
    $args{public_key_multibase},
    $args{repo_commit_cid},
    $args{repo_root_cid},
    $args{repo_rev},
  );

  return $self->get_account_by_did($did);
}

sub update_account ($self, $did, %changes) {
  my %allowed = map { $_ => 1 } qw(
    handle email password_hash password_salt updated_at deactivated_at deleted_at
    did_doc private_key public_key public_key_multibase
    repo_commit_cid repo_root_cid repo_rev
  );
  my (@sets, @bind);
  for my $key (sort keys %changes) {
    next unless $allowed{$key};
    my $column = $key eq 'did_doc' ? 'did_doc_json' : $key;
    push @sets, "$column = ?";
    push @bind, $key eq 'did_doc' ? _maybe_json($changes{$key}) : $changes{$key};
  }
  return $self->get_account_by_did($did) unless @sets;

  push @sets, 'updated_at = ?';
  push @bind, ($changes{updated_at} // time), $did;
  $self->dbh->do(
    'UPDATE accounts SET ' . join(', ', @sets) . ' WHERE did = ?',
    undef,
    @bind,
  );
  return $self->get_account_by_did($did);
}

sub get_account_by_did ($self, $did) {
  return $self->_row_to_account($self->dbh->selectrow_hashref(
    q{SELECT * FROM accounts WHERE did = ?},
    undef,
    $did,
  ));
}

sub get_account_by_id ($self, $account_id) {
  return $self->_row_to_account($self->dbh->selectrow_hashref(
    q{SELECT * FROM accounts WHERE account_id = ? OR id = ?},
    undef,
    $account_id,
    $account_id,
  ));
}

sub get_account_by_handle ($self, $handle) {
  return $self->_row_to_account($self->dbh->selectrow_hashref(
    q{SELECT * FROM accounts WHERE handle = ?},
    undef,
    $handle,
  ));
}

sub get_account_by_email ($self, $email) {
  return $self->_row_to_account($self->dbh->selectrow_hashref(
    q{SELECT * FROM accounts WHERE email = ?},
    undef,
    $email,
  ));
}

sub get_account_by_identifier ($self, $identifier) {
  return $self->get_account_by_did($identifier) if defined $identifier && $identifier =~ /^did:/;
  return $self->get_account_by_handle($identifier);
}

sub list_accounts ($self) {
  return [
    map { $self->_row_to_account($_) }
    @{ $self->dbh->selectall_arrayref(
      q{SELECT * FROM accounts ORDER BY created_at, did},
      { Slice => {} },
    ) }
  ];
}

sub create_session ($self, %args) {
  my $did = $args{did} // die 'did is required';
  my $id  = $args{id}  // _random_id();
  my $now = $args{created_at} // time;

  $self->dbh->do(
    q{
      INSERT INTO sessions (
        id, did, token, kind, scope, created_at, expires_at,
        revoked_at, ip, user_agent
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    },
    undef,
    $id,
    $did,
    $args{token},
    $args{kind} // 'refresh',
    $args{scope} // 'atproto',
    $now,
    $args{expires_at},
    $args{revoked_at},
    $args{ip},
    $args{user_agent},
  );

  return $self->get_session($id);
}

sub get_session ($self, $id) {
  return $self->dbh->selectrow_hashref(
    q{SELECT * FROM sessions WHERE id = ?},
    undef,
    $id,
  );
}

sub revoke_session ($self, $id, %args) {
  $self->dbh->do(
    q{UPDATE sessions SET revoked_at = ? WHERE id = ?},
    undef,
    $args{revoked_at} // time,
    $id,
  );
  return $self->get_session($id);
}

sub revoke_sessions_by_did ($self, $did, %args) {
  $self->dbh->do(
    q{UPDATE sessions SET revoked_at = ? WHERE did = ? AND revoked_at IS NULL},
    undef,
    $args{revoked_at} // time,
    $did,
  );
  return $self->list_sessions_by_did($did);
}

sub list_sessions_by_did ($self, $did) {
  return $self->dbh->selectall_arrayref(
    q{SELECT * FROM sessions WHERE did = ? ORDER BY created_at DESC, id DESC},
    { Slice => {} },
    $did,
  );
}

sub create_app_password ($self, %args) {
  my $did = $args{did} // die 'did is required';
  my $id  = $args{id}  // _random_id();
  my $now = $args{created_at} // time;

  $self->dbh->do(
    q{
      INSERT INTO app_passwords (
        id, did, name, password_hash, created_at, revoked_at
      ) VALUES (?, ?, ?, ?, ?, ?)
    },
    undef,
    $id,
    $did,
    $args{name} // 'app-password',
    $args{password_hash},
    $now,
    $args{revoked_at},
  );

  return $self->get_app_password($id);
}

sub get_app_password ($self, $id) {
  return $self->dbh->selectrow_hashref(
    q{SELECT * FROM app_passwords WHERE id = ?},
    undef,
    $id,
  );
}

sub get_app_password_by_name ($self, $did, $name) {
  return $self->dbh->selectrow_hashref(
    q{SELECT * FROM app_passwords WHERE did = ? AND name = ? ORDER BY created_at DESC LIMIT 1},
    undef,
    $did,
    $name,
  );
}

sub revoke_app_password ($self, $id, %args) {
  $self->dbh->do(
    q{UPDATE app_passwords SET revoked_at = ? WHERE id = ?},
    undef,
    $args{revoked_at} // time,
    $id,
  );
  return $self->get_app_password($id);
}

sub list_app_passwords_by_did ($self, $did) {
  return $self->dbh->selectall_arrayref(
    q{SELECT * FROM app_passwords WHERE did = ? ORDER BY created_at DESC, id DESC},
    { Slice => {} },
    $did,
  );
}

sub put_blob ($self, %args) {
  my $cid = $args{cid} // die 'cid is required';
  my $now = $args{created_at} // time;
  $self->dbh->do(
    q{
      INSERT INTO blobs (
        cid, did, mime_type, byte_size, storage_path, temporary,
        created_at, referenced_at, quarantined_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(cid) DO UPDATE SET
        did = excluded.did,
        mime_type = excluded.mime_type,
        byte_size = excluded.byte_size,
        storage_path = excluded.storage_path,
        temporary = excluded.temporary,
        referenced_at = COALESCE(excluded.referenced_at, blobs.referenced_at),
        quarantined_at = excluded.quarantined_at
    },
    undef,
    $cid,
    $args{did},
    $args{mime_type},
    $args{byte_size},
    $args{storage_path},
    $args{temporary} ? 1 : 0,
    $now,
    $args{referenced_at},
    $args{quarantined_at},
  );
  return $self->get_blob($cid);
}

sub get_blob ($self, $cid) {
  return $self->dbh->selectrow_hashref(
    q{SELECT * FROM blobs WHERE cid = ?},
    undef,
    $cid,
  );
}

sub list_blobs_by_did ($self, $did, %args) {
  my $limit = $args{limit} // 500;
  my $cursor = $args{cursor};
  my @bind = ($did);
  my $sql = q{SELECT * FROM blobs WHERE did = ?};
  if (defined $cursor && length $cursor) {
    $sql .= q{ AND cid > ?};
    push @bind, $cursor;
  }
  $sql .= q{ ORDER BY cid LIMIT ?};
  push @bind, $limit + 1;
  my $rows = $self->dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
  return _paginate($rows, $limit, 'cid');
}

sub put_record ($self, %args) {
  my $did        = $args{did}        // die 'did is required';
  my $collection = $args{collection} // die 'collection is required';
  my $rkey       = $args{rkey}       // die 'rkey is required';
  my $cid        = $args{cid}        // die 'cid is required';
  my $now        = $args{updated_at} // time;

  $self->dbh->do(
    q{
      INSERT INTO records (
        did, collection, rkey, cid, value_json, record_bytes, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(did, collection, rkey) DO UPDATE SET
        cid = excluded.cid,
        value_json = excluded.value_json,
        record_bytes = excluded.record_bytes,
        updated_at = excluded.updated_at
    },
    undef,
    $did,
    $collection,
    $rkey,
    $cid,
    encode_json($args{value}),
    $args{record_bytes},
    $args{created_at} // $now,
    $now,
  );

  return $self->get_record($did, $collection, $rkey);
}

sub replace_records_for_did ($self, $did, $records) {
  my $dbh = $self->dbh;
  $dbh->do(q{DELETE FROM records WHERE did = ?}, undef, $did);
  for my $record (@$records) {
    $dbh->do(
      q{
        INSERT INTO records (
          did, collection, rkey, cid, value_json, record_bytes, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      },
      undef,
      $did,
      $record->{collection},
      $record->{rkey},
      $record->{cid},
      encode_json($record->{value}),
      $record->{record_bytes},
      $record->{created_at} // time,
      $record->{updated_at} // time,
    );
  }
  return 1;
}

sub delete_record ($self, $did, $collection, $rkey) {
  $self->dbh->do(
    q{DELETE FROM records WHERE did = ? AND collection = ? AND rkey = ?},
    undef,
    $did,
    $collection,
    $rkey,
  );
  return 1;
}

sub get_record ($self, $did, $collection, $rkey) {
  my $row = $self->dbh->selectrow_hashref(
    q{
      SELECT * FROM records
      WHERE did = ? AND collection = ? AND rkey = ?
    },
    undef,
    $did,
    $collection,
    $rkey,
  );
  return _row_to_record($row);
}

sub list_records ($self, $did, $collection, %args) {
  my $limit = $args{limit} // 50;
  $limit = 100 if $limit > 100;
  my $cursor = $args{cursor};
  my $reverse = $args{reverse} ? 1 : 0;
  my @bind = ($did, $collection);
  my $sql = q{
    SELECT * FROM records
    WHERE did = ? AND collection = ?
  };
  if (defined $cursor && length $cursor) {
    $sql .= $reverse ? q{ AND rkey < ?} : q{ AND rkey > ?};
    push @bind, $cursor;
  }
  $sql .= $reverse ? q{ ORDER BY rkey DESC} : q{ ORDER BY rkey ASC};
  $sql .= q{ LIMIT ?};
  push @bind, $limit + 1;
  my $rows = $self->dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
  my $page = _paginate($rows, $limit, 'rkey');
  $page->{items} = [ map { _row_to_record($_) } @{ $page->{items} } ];
  return $page;
}

sub all_records_for_did ($self, $did) {
  my $rows = $self->dbh->selectall_arrayref(
    q{SELECT * FROM records WHERE did = ? ORDER BY collection, rkey},
    { Slice => {} },
    $did,
  );
  return [ map { _row_to_record($_) } @$rows ];
}

sub list_collections_for_did ($self, $did) {
  my $rows = $self->dbh->selectall_arrayref(
    q{SELECT DISTINCT collection FROM records WHERE did = ? ORDER BY collection},
    { Slice => {} },
    $did,
  );
  return [ map { $_->{collection} } @$rows ];
}

sub put_block ($self, %args) {
  my $cid = $args{cid} // die 'cid is required';
  my $now = $args{created_at} // time;
  $self->dbh->do(
    q{
      INSERT INTO blocks (cid, codec, bytes, created_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(cid) DO UPDATE SET
        codec = excluded.codec,
        bytes = excluded.bytes
    },
    undef,
    $cid,
    $args{codec},
    $args{bytes},
    $now,
  );
  return $self->get_block($cid);
}

sub get_block ($self, $cid) {
  return $self->dbh->selectrow_hashref(
    q{SELECT * FROM blocks WHERE cid = ?},
    undef,
    $cid,
  );
}

sub get_blocks ($self, $cids) {
  return [] unless @$cids;
  my $placeholders = join(', ', ('?') x @$cids);
  my $rows = $self->dbh->selectall_arrayref(
    "SELECT * FROM blocks WHERE cid IN ($placeholders)",
    { Slice => {} },
    @$cids,
  );
  return $rows;
}

sub put_commit ($self, %args) {
  my $did = $args{did} // die 'did is required';
  my $now = $args{created_at} // time;
  $self->dbh->do(
    q{
      INSERT INTO commits (
        did, rev, cid, root_cid, prev_cid, commit_bytes, car_bytes, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    },
    undef,
    $did,
    $args{rev},
    $args{cid},
    $args{root_cid},
    $args{prev_cid},
    $args{commit_bytes},
    $args{car_bytes},
    $now,
  );
  $self->set_repo_head(
    did        => $did,
    commit_cid => $args{cid},
    rev        => $args{rev},
    root_cid   => $args{root_cid},
    indexed_at => $now,
    car_bytes  => $args{car_bytes},
  );
  return $self->get_commit_by_rev($did, $args{rev});
}

sub get_commit_by_rev ($self, $did, $rev) {
  return $self->dbh->selectrow_hashref(
    q{SELECT * FROM commits WHERE did = ? AND rev = ?},
    undef,
    $did,
    $rev,
  );
}

sub get_latest_commit ($self, $did) {
  return $self->dbh->selectrow_hashref(
    q{SELECT * FROM commits WHERE did = ? ORDER BY created_at DESC, rev DESC LIMIT 1},
    undef,
    $did,
  );
}

sub repo_car ($self, $did) {
  my $row = $self->get_latest_commit($did);
  return $row ? $row->{car_bytes} : undef;
}

sub list_repos ($self, %args) {
  my $limit = $args{limit} // 500;
  $limit = 1000 if $limit > 1000;
  my $cursor = $args{cursor};
  my @bind;
  my $sql = q{
    SELECT did, repo_commit_cid AS head, repo_rev AS rev, deleted_at, deactivated_at
    FROM accounts
    WHERE repo_commit_cid IS NOT NULL
  };
  if (defined $cursor && length $cursor) {
    $sql .= q{ AND did > ?};
    push @bind, $cursor;
  }
  $sql .= q{ ORDER BY did LIMIT ?};
  push @bind, $limit + 1;
  my $rows = $self->dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
  my $page = _paginate($rows, $limit, 'did');
  $page->{items} = [
    map {
      +{
        did    => $_->{did},
        head   => $_->{head},
        rev    => $_->{rev},
        active => ($_->{deleted_at} || $_->{deactivated_at}) ? JSON::PP::false : JSON::PP::true,
      }
    } @{ $page->{items} }
  ];
  return $page;
}

sub append_event ($self, %args) {
  my $now = $args{created_at} // time;
  $self->dbh->do(
    q{
      INSERT INTO events (
        did, type, rev, commit_cid, payload_json, car_bytes, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
    },
    undef,
    $args{did},
    $args{type},
    $args{rev},
    $args{commit_cid},
    _maybe_json($args{payload}),
    $args{car_bytes},
    $now,
  );
  return $self->dbh->sqlite_last_insert_rowid;
}

sub list_events_after ($self, $cursor, %args) {
  my $limit = $args{limit} // 100;
  my $sql = q{SELECT * FROM events WHERE seq > ? ORDER BY seq LIMIT ?};
  return $self->dbh->selectall_arrayref($sql, { Slice => {} }, $cursor // 0, $limit);
}

sub set_repo_head ($self, %args) {
  my $did = $args{did} // die 'did is required';
  my $now = $args{indexed_at} // time;
  $self->dbh->do(
    q{
      INSERT INTO repo_heads (did, commit_cid, rev, root_cid, indexed_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(did) DO UPDATE SET
        commit_cid = excluded.commit_cid,
        rev = excluded.rev,
        root_cid = excluded.root_cid,
        indexed_at = excluded.indexed_at
    },
    undef,
    $did,
    $args{commit_cid},
    $args{rev},
    $args{root_cid},
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
  return $self->get_repo_head($did);
}

sub get_repo_head ($self, $did) {
  return $self->dbh->selectrow_hashref(
    q{SELECT * FROM repo_heads WHERE did = ?},
    undef,
    $did,
  );
}

sub default_migrations {
  return (
    {
      version => 1,
      statements => [
        q{
          CREATE TABLE IF NOT EXISTS accounts (
            id TEXT PRIMARY KEY,
            did TEXT NOT NULL UNIQUE,
            handle TEXT NOT NULL UNIQUE,
            email TEXT UNIQUE,
            password_hash TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deactivated_at INTEGER,
            deleted_at INTEGER,
            did_doc_json TEXT,
            signing_key TEXT,
            recovery_key TEXT
          )
        },
        q{
          CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            did TEXT NOT NULL,
            token TEXT,
            kind TEXT NOT NULL,
            scope TEXT,
            created_at INTEGER NOT NULL,
            expires_at INTEGER,
            revoked_at INTEGER,
            ip TEXT,
            user_agent TEXT,
            FOREIGN KEY (did) REFERENCES accounts(did)
          )
        },
        q{CREATE INDEX IF NOT EXISTS sessions_by_did ON sessions (did, created_at DESC)},
        q{
          CREATE TABLE IF NOT EXISTS app_passwords (
            id TEXT PRIMARY KEY,
            did TEXT NOT NULL,
            name TEXT NOT NULL,
            password_hash TEXT,
            created_at INTEGER NOT NULL,
            revoked_at INTEGER,
            FOREIGN KEY (did) REFERENCES accounts(did)
          )
        },
        q{CREATE INDEX IF NOT EXISTS app_passwords_by_did ON app_passwords (did, created_at DESC)},
        q{
          CREATE TABLE IF NOT EXISTS blobs (
            cid TEXT PRIMARY KEY,
            did TEXT,
            mime_type TEXT,
            byte_size INTEGER,
            storage_path TEXT,
            temporary INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            referenced_at INTEGER,
            quarantined_at INTEGER,
            FOREIGN KEY (did) REFERENCES accounts(did)
          )
        },
        q{CREATE INDEX IF NOT EXISTS blobs_by_did ON blobs (did, created_at DESC)},
        q{
          CREATE TABLE IF NOT EXISTS repo_heads (
            did TEXT PRIMARY KEY,
            commit_cid TEXT,
            rev TEXT,
            root_cid TEXT,
            indexed_at INTEGER NOT NULL,
            FOREIGN KEY (did) REFERENCES accounts(did)
          )
        },
      ],
    },
    {
      version => 2,
      statements => [
        q{ALTER TABLE accounts ADD COLUMN account_id TEXT},
        q{ALTER TABLE accounts ADD COLUMN password_salt BLOB},
        q{ALTER TABLE accounts ADD COLUMN private_key BLOB},
        q{ALTER TABLE accounts ADD COLUMN public_key BLOB},
        q{ALTER TABLE accounts ADD COLUMN public_key_multibase TEXT},
        q{ALTER TABLE accounts ADD COLUMN repo_commit_cid TEXT},
        q{ALTER TABLE accounts ADD COLUMN repo_root_cid TEXT},
        q{ALTER TABLE accounts ADD COLUMN repo_rev TEXT},
        q{CREATE UNIQUE INDEX IF NOT EXISTS accounts_account_id_idx ON accounts(account_id)},
        q{
          CREATE TABLE IF NOT EXISTS records (
            did TEXT NOT NULL,
            collection TEXT NOT NULL,
            rkey TEXT NOT NULL,
            cid TEXT NOT NULL,
            value_json TEXT NOT NULL,
            record_bytes BLOB NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (did, collection, rkey)
          )
        },
        q{CREATE INDEX IF NOT EXISTS records_by_collection ON records(did, collection, rkey)},
        q{
          CREATE TABLE IF NOT EXISTS blocks (
            cid TEXT PRIMARY KEY,
            codec INTEGER NOT NULL,
            bytes BLOB NOT NULL,
            created_at INTEGER NOT NULL
          )
        },
        q{
          CREATE TABLE IF NOT EXISTS commits (
            did TEXT NOT NULL,
            rev TEXT NOT NULL,
            cid TEXT NOT NULL UNIQUE,
            root_cid TEXT NOT NULL,
            prev_cid TEXT,
            commit_bytes BLOB NOT NULL,
            car_bytes BLOB NOT NULL,
            created_at INTEGER NOT NULL,
            PRIMARY KEY (did, rev)
          )
        },
        q{CREATE INDEX IF NOT EXISTS commits_latest_idx ON commits(did, created_at DESC, rev DESC)},
        q{
          CREATE TABLE IF NOT EXISTS events (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            did TEXT NOT NULL,
            type TEXT NOT NULL,
            rev TEXT,
            commit_cid TEXT,
            payload_json TEXT,
            car_bytes BLOB,
            created_at INTEGER NOT NULL
          )
        },
        q{CREATE INDEX IF NOT EXISTS events_seq_idx ON events(seq)},
      ],
    },
  );
}

sub _connect ($self) {
  make_path(dirname($self->path));
  my $dbh = DBI->connect(
    'dbi:SQLite:dbname=' . $self->path,
    q(),
    q(),
    {
      AutoCommit     => 1,
      RaiseError     => 1,
      PrintError     => 0,
      sqlite_unicode => 1,
    },
  );
  $dbh->do('PRAGMA foreign_keys = ON');
  $dbh->do('PRAGMA busy_timeout = 5000');
  $dbh->do('PRAGMA journal_mode = WAL');
  return $dbh;
}

sub _row_to_account ($self, $row) {
  return undef unless $row;
  if (defined $row->{did_doc_json} && length $row->{did_doc_json}) {
    $row->{did_doc} = decode_json($row->{did_doc_json});
  }
  delete $row->{did_doc_json};
  $row->{account_id} //= $row->{id};
  return $row;
}

sub _row_to_record ($row) {
  return undef unless $row;
  $row->{value} = decode_json($row->{value_json}) if defined $row->{value_json};
  delete $row->{value_json};
  return $row;
}

sub _paginate ($rows, $limit, $cursor_key) {
  my @items = @$rows;
  my $cursor;
  if (@items > $limit) {
    my $last = pop @items;
    $cursor = $last->{$cursor_key};
  }
  return {
    items  => \@items,
    cursor => $cursor,
  };
}

sub _maybe_json ($value) {
  return undef unless defined $value;
  return ref($value) ? encode_json($value) : $value;
}

sub _random_id {
  open(my $fh, '<:raw', '/dev/urandom') or die "open(/dev/urandom): $!";
  my $bytes = q();
  my $read = read($fh, $bytes, 12);
  CORE::close($fh);
  die 'failed to read random bytes' unless defined $read && $read == 12;
  return unpack('H*', $bytes);
}

1;
