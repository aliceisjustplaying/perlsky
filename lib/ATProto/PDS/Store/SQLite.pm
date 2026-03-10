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

  my $self = bless {
    path => $args{path},
    dbh  => undef,
  }, $class;

  return $self;
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
    $dbh->begin_work;
    eval {
      $dbh->do($_) for @{ $migration->{statements} };
      $dbh->do(
        q{INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)},
        undef,
        $migration->{version},
        time,
      );
      $dbh->commit;
      1;
    } or do {
      my $err = $@ || 'unknown migration failure';
      eval { $dbh->rollback };
      die $err;
    };
  }

  return 1;
}

sub close ($self) {
  return unless $self->{dbh};
  $self->{dbh}->disconnect;
  $self->{dbh} = undef;
}

sub create_account ($self, %args) {
  my $did    = $args{did}    // die 'did is required';
  my $handle = $args{handle} // die 'handle is required';
  my $now    = $args{created_at} // time;
  my $dbh    = $self->dbh;

  $dbh->do(
    q{
      INSERT INTO accounts (
        id, did, handle, email, password_hash, created_at, updated_at,
        deactivated_at, deleted_at, did_doc_json, signing_key, recovery_key
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    },
    undef,
    $args{id} // _random_id(),
    $did,
    $handle,
    $args{email},
    $args{password_hash},
    $now,
    $now,
    $args{deactivated_at},
    $args{deleted_at},
    _maybe_json($args{did_doc}),
    $args{signing_key},
    $args{recovery_key},
  );

  return $self->get_account_by_did($did);
}

sub update_account ($self, $did, %changes) {
  my %allowed = map { $_ => 1 } qw(
    handle email password_hash updated_at deactivated_at deleted_at
    did_doc signing_key recovery_key
  );
  my @sets;
  my @bind;

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
    $args{scope} // 'com.atproto.access',
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

sub list_blobs_by_did ($self, $did) {
  return $self->dbh->selectall_arrayref(
    q{SELECT * FROM blobs WHERE did = ? ORDER BY created_at DESC, cid DESC},
    { Slice => {} },
    $did,
  );
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
  );
}

sub _connect ($self) {
  make_path(dirname($self->path));
  my $dbh = DBI->connect(
    'dbi:SQLite:dbname=' . $self->path,
    q(),
    q(),
    {
      AutoCommit => 1,
      RaiseError => 1,
      PrintError => 0,
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
  return $row;
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
