package ATProto::PDS::Store::SQLite;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use DBI;
use Digest::SHA qw(sha256 sha256_hex);
use File::Path qw(make_path);
use File::Spec;
use JSON::PP qw(decode_json encode_json);
use Mojo::JSON qw(false true);

use Crypt::PK::Ed25519;
use Crypt::PRNG qw(random_bytes);

use ATProto::PDS::Auth::JWT qw(decode_jwt encode_jwt);
use ATProto::PDS::IPLD::Base58 qw(encode_base58btc);
use ATProto::PDS::Identity qw(normalize_handle service_did);
use ATProto::PDS::Repo::Bytes;
use ATProto::PDS::Repo::CAR qw(write_car);
use ATProto::PDS::Repo::CID;
use ATProto::PDS::Repo::DagCbor qw(encode_dag_cbor);
use ATProto::PDS::Repo::MST qw(build_mst);
use ATProto::PDS::Util::TID qw(next_tid);

sub new ($class, %args) {
  my $self = bless {
    config => $args{config} || {},
  }, $class;

  $self->{dbh} = DBI->connect(
    'dbi:SQLite:dbname=' . $self->{config}{db_path},
    '',
    '',
    {
      RaiseError         => 1,
      PrintError         => 0,
      AutoCommit         => 1,
      sqlite_unicode     => 1,
      sqlite_use_immediate_transaction => 1,
    },
  );

  make_path($self->{config}{data_dir});
  make_path($self->_blob_root);
  $self->_init_schema;
  return $self;
}

sub dbh ($self) {
  return $self->{dbh};
}

sub _init_schema ($self) {
  my $dbh = $self->dbh;

  $dbh->do($_) for (
    q{
      CREATE TABLE IF NOT EXISTS accounts (
        did TEXT PRIMARY KEY,
        handle TEXT NOT NULL UNIQUE,
        email TEXT,
        password_salt TEXT NOT NULL,
        password_hash TEXT NOT NULL,
        recovery_key TEXT,
        signing_private BLOB NOT NULL,
        signing_public BLOB NOT NULL,
        plc_operation_json TEXT,
        email_confirmed INTEGER NOT NULL DEFAULT 0,
        active INTEGER NOT NULL DEFAULT 1,
        status TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    },
    q{
      CREATE TABLE IF NOT EXISTS sessions (
        jti TEXT PRIMARY KEY,
        did TEXT NOT NULL,
        scope TEXT NOT NULL,
        app_password_id TEXT,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        revoked_at INTEGER,
        FOREIGN KEY(did) REFERENCES accounts(did)
      )
    },
    q{
      CREATE TABLE IF NOT EXISTS app_passwords (
        id TEXT PRIMARY KEY,
        did TEXT NOT NULL,
        name TEXT NOT NULL,
        privileged INTEGER NOT NULL DEFAULT 0,
        password_salt TEXT NOT NULL,
        password_hash TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        revoked_at INTEGER,
        FOREIGN KEY(did) REFERENCES accounts(did)
      )
    },
    q{
      CREATE TABLE IF NOT EXISTS invite_codes (
        code TEXT PRIMARY KEY,
        created_by TEXT,
        disabled INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    },
    q{
      CREATE TABLE IF NOT EXISTS pending_codes (
        id TEXT PRIMARY KEY,
        did TEXT NOT NULL,
        purpose TEXT NOT NULL,
        target TEXT,
        code TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        used_at INTEGER
      )
    },
    q{
      CREATE TABLE IF NOT EXISTS blobs (
        cid TEXT PRIMARY KEY,
        did TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        size INTEGER NOT NULL,
        sha256 TEXT NOT NULL,
        path TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        FOREIGN KEY(did) REFERENCES accounts(did)
      )
    },
    q{
      CREATE TABLE IF NOT EXISTS records (
        did TEXT NOT NULL,
        collection TEXT NOT NULL,
        rkey TEXT NOT NULL,
        uri TEXT NOT NULL,
        cid TEXT NOT NULL,
        record_json TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY(did, collection, rkey),
        FOREIGN KEY(did) REFERENCES accounts(did)
      )
    },
    q{
      CREATE TABLE IF NOT EXISTS blocks (
        cid TEXT PRIMARY KEY,
        codec INTEGER NOT NULL,
        bytes BLOB NOT NULL,
        created_at INTEGER NOT NULL
      )
    },
    q{
      CREATE TABLE IF NOT EXISTS repo_roots (
        did TEXT PRIMARY KEY,
        commit_cid TEXT NOT NULL,
        data_cid TEXT NOT NULL,
        rev TEXT NOT NULL,
        prev_commit_cid TEXT,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY(did) REFERENCES accounts(did)
      )
    },
    q{
      CREATE TABLE IF NOT EXISTS repo_commits (
        cid TEXT PRIMARY KEY,
        did TEXT NOT NULL,
        rev TEXT NOT NULL,
        prev_commit_cid TEXT,
        data_cid TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        FOREIGN KEY(did) REFERENCES accounts(did)
      )
    },
    q{
      CREATE TABLE IF NOT EXISTS commit_blocks (
        commit_cid TEXT NOT NULL,
        cid TEXT NOT NULL,
        ord INTEGER NOT NULL,
        PRIMARY KEY(commit_cid, cid)
      )
    },
    q{
      CREATE TABLE IF NOT EXISTS moderation_reports (
        id TEXT PRIMARY KEY,
        did TEXT NOT NULL,
        reason_type TEXT,
        reason TEXT,
        subject_json TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    }
  );
}

sub create_account ($self, $input) {
  my $config = $self->{config};
  my $did = $input->{did} || $self->_new_plc_did;
  my $handle = normalize_handle($input->{handle}, $config->{service_handle_domain} // 'localhost')
    or die {
      status  => 400,
      error   => 'InvalidHandle',
      message => 'Handle is not valid for this service',
    };
  my $password = $input->{password} // _token_string(18);
  die {
    status  => 400,
    error   => 'InvalidPassword',
    message => 'Password must be at least 8 characters',
  } if length($password) < 8;

  my $salt = _token_string(16);
  my $now  = time;
  my $key  = Crypt::PK::Ed25519->new->generate_key;
  my $priv = $key->export_key_raw('private');
  my $pub  = $key->export_key_raw('public');

  $self->_txn(sub {
    my $existing = $self->account_by_handle($handle);
    die {
      status  => 400,
      error   => 'HandleNotAvailable',
      message => "Handle already exists: $handle",
    } if $existing;

    $self->dbh->do(
      q{
        INSERT INTO accounts (
          did, handle, email, password_salt, password_hash, recovery_key,
          signing_private, signing_public, plc_operation_json,
          email_confirmed, active, status, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      },
      undef,
      $did,
      $handle,
      $input->{email},
      $salt,
      $self->_hash_password($password, $salt),
      $input->{recoveryKey},
      $priv,
      $pub,
      encode_json($self->_plc_operation_for($did, $handle, $pub)),
      $input->{email} ? 0 : 1,
      1,
      undef,
      $now,
      $now,
    );

    $self->_rebuild_repo($did);
  });

  my $pair = $self->issue_session_pair($did);
  my $account = $self->account_by_did($did);

  return {
    accessJwt => $pair->{accessJwt},
    refreshJwt => $pair->{refreshJwt},
    handle => $account->{handle},
    did => $account->{did},
    didDoc => $self->did_doc($account),
  };
}

sub account_by_did ($self, $did) {
  return $self->dbh->selectrow_hashref(
    q{SELECT * FROM accounts WHERE did = ?},
    undef,
    $did,
  );
}

sub account_by_handle ($self, $handle) {
  return $self->dbh->selectrow_hashref(
    q{SELECT * FROM accounts WHERE lower(handle) = lower(?)},
    undef,
    $handle,
  );
}

sub account_by_identifier ($self, $identifier) {
  return $identifier =~ /^did:/
    ? $self->account_by_did($identifier)
    : $self->account_by_handle($identifier)
      || $self->dbh->selectrow_hashref(q{SELECT * FROM accounts WHERE lower(email) = lower(?)}, undef, $identifier);
}

sub create_session ($self, $identifier, $password) {
  my $account = $self->account_by_identifier($identifier)
    or die {
      status  => 401,
      error   => 'AuthenticationRequired',
      message => 'Invalid identifier or password',
    };

  my $ok = $self->_verify_password($password, $account->{password_salt}, $account->{password_hash});
  my $app_password_id;
  if (!$ok) {
    my $app_password = $self->_find_app_password($account->{did}, $password);
    $ok = !!$app_password;
    $app_password_id = $app_password->{id} if $app_password;
  }

  die {
    status  => 401,
    error   => 'AuthenticationRequired',
    message => 'Invalid identifier or password',
  } unless $ok;

  my $pair = $self->issue_session_pair($account->{did}, $app_password_id);
  return {
    %$pair,
    handle          => $account->{handle},
    did             => $account->{did},
    didDoc          => $self->did_doc($account),
    email           => $account->{email},
    emailConfirmed  => $account->{email_confirmed} ? true : false,
    emailAuthFactor => false,
    active          => $account->{active} ? true : false,
    ($account->{status} ? (status => $account->{status}) : ()),
  };
}

sub issue_session_pair ($self, $did, $app_password_id = undef) {
  my $now = time;
  my $access_exp  = $now + 3600;
  my $refresh_exp = $now + 60 * 60 * 24 * 14;
  my $aud         = service_did($self->{config});

  my $access_jti  = _token_string(24);
  my $refresh_jti = _token_string(24);

  $self->dbh->do(
    q{INSERT INTO sessions (jti, did, scope, app_password_id, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)},
    undef,
    $access_jti, $did, 'access', $app_password_id, $now, $access_exp,
  );
  $self->dbh->do(
    q{INSERT INTO sessions (jti, did, scope, app_password_id, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)},
    undef,
    $refresh_jti, $did, 'refresh', $app_password_id, $now, $refresh_exp,
  );

  my $access = encode_jwt({
    iss   => $aud,
    aud   => $aud,
    sub   => $did,
    scope => 'access',
    jti   => $access_jti,
    iat   => $now,
    exp   => $access_exp,
  }, $self->{config}{jwt_secret});

  my $refresh = encode_jwt({
    iss   => $aud,
    aud   => $aud,
    sub   => $did,
    scope => 'refresh',
    jti   => $refresh_jti,
    iat   => $now,
    exp   => $refresh_exp,
  }, $self->{config}{jwt_secret});

  return {
    accessJwt  => $access,
    refreshJwt => $refresh,
  };
}

sub auth_from_bearer ($self, $token, $expected_scope = undef) {
  my $decoded = eval {
    decode_jwt($token, $self->{config}{jwt_secret}, audience => service_did($self->{config}));
  };
  die {
    status  => 401,
    error   => 'InvalidToken',
    message => 'Invalid bearer token',
  } if $@;

  my $claims = $decoded->{claims};
  my $session = $self->dbh->selectrow_hashref(
    q{SELECT * FROM sessions WHERE jti = ? AND revoked_at IS NULL},
    undef,
    $claims->{jti},
  ) or die {
    status  => 401,
    error   => 'InvalidToken',
    message => 'Session is not active',
  };

  if ($expected_scope && $session->{scope} ne $expected_scope) {
    die {
      status  => 401,
      error   => 'InvalidToken',
      message => 'Token scope mismatch',
    };
  }

  if ($session->{expires_at} <= time) {
    die {
      status  => 401,
      error   => 'ExpiredToken',
      message => 'Token has expired',
    };
  }

  my $account = $self->account_by_did($session->{did})
    or die {
      status  => 401,
      error   => 'InvalidToken',
      message => 'Account not found for token',
    };

  return {
    claims  => $claims,
    session => $session,
    account => $account,
  };
}

sub refresh_session ($self, $refresh_token) {
  my $auth = $self->auth_from_bearer($refresh_token, 'refresh');
  my $account = $auth->{account};
  my $pair = $self->issue_session_pair($account->{did}, $auth->{session}{app_password_id});

  $self->revoke_session_jti($auth->{session}{jti});

  return {
    %$pair,
    handle          => $account->{handle},
    did             => $account->{did},
    didDoc          => $self->did_doc($account),
    email           => $account->{email},
    emailConfirmed  => $account->{email_confirmed} ? true : false,
    emailAuthFactor => false,
    active          => $account->{active} ? true : false,
    ($account->{status} ? (status => $account->{status}) : ()),
  };
}

sub revoke_session_jti ($self, $jti) {
  $self->dbh->do(q{UPDATE sessions SET revoked_at = ? WHERE jti = ?}, undef, time, $jti);
}

sub get_session_view ($self, $access_token) {
  my $auth = $self->auth_from_bearer($access_token, 'access');
  my $account = $auth->{account};
  return {
    handle          => $account->{handle},
    did             => $account->{did},
    didDoc          => $self->did_doc($account),
    email           => $account->{email},
    emailConfirmed  => $account->{email_confirmed} ? true : false,
    emailAuthFactor => false,
    active          => $account->{active} ? true : false,
    ($account->{status} ? (status => $account->{status}) : ()),
  };
}

sub check_account_status ($self, $access_token) {
  my $auth = $self->auth_from_bearer($access_token, 'access');
  my $repo = $self->current_repo($auth->{account}{did});
  return {
    activated => $auth->{account}{active} ? true : false,
    validDid  => true,
    repo      => $repo ? true : false,
    repoRev   => $repo ? $repo->{rev} : undef,
    repoCommit => $repo ? $repo->{commit_cid} : undef,
  };
}

sub did_doc ($self, $account_or_did) {
  my $account = ref($account_or_did) eq 'HASH'
    ? $account_or_did
    : $self->account_by_did($account_or_did);
  return undef unless $account;

  my $did = $account->{did};
  my $multikey = 'z' . encode_base58btc("\xed\x01" . $account->{signing_public});

  return {
    '@context' => [
      'https://www.w3.org/ns/did/v1',
      'https://w3id.org/security/multikey/v1',
    ],
    id => $did,
    alsoKnownAs => [ 'at://' . $account->{handle} ],
    verificationMethod => [{
      id                => "$did#atproto",
      type              => 'Multikey',
      controller        => $did,
      publicKeyMultibase => $multikey,
    }],
    service => [{
      id              => '#atproto_pds',
      type            => 'AtprotoPersonalDataServer',
      serviceEndpoint => $self->{config}{base_url},
    }],
  };
}

sub resolve_handle ($self, $handle) {
  my $account = $self->account_by_handle($handle)
    or die {
      status  => 404,
      error   => 'HandleNotFound',
      message => "No DID found for handle $handle",
    };
  return { did => $account->{did} };
}

sub resolve_did ($self, $did) {
  if ($did eq service_did($self->{config})) {
    return {
      didDoc => {
        '@context' => ['https://www.w3.org/ns/did/v1'],
        id => $did,
        service => [{
          id              => "$did#atproto_pds",
          type            => 'AtprotoPersonalDataServer',
          serviceEndpoint => $self->{config}{base_url},
        }],
      },
    };
  }

  my $account = $self->account_by_did($did)
    or die {
      status  => 404,
      error   => 'DidNotFound',
      message => "No DID document found for $did",
    };
  return { didDoc => $self->did_doc($account) };
}

sub resolve_identity ($self, $identifier) {
  my $account = $self->account_by_identifier($identifier)
    or die {
      status  => 404,
      error   => ($identifier =~ /^did:/ ? 'DidNotFound' : 'HandleNotFound'),
      message => "No identity found for $identifier",
    };

  return {
    did    => $account->{did},
    handle => $account->{handle},
    didDoc => $self->did_doc($account),
  };
}

sub get_recommended_did_credentials ($self, $access_token) {
  my $auth = $self->auth_from_bearer($access_token, 'access');
  my $doc  = $self->did_doc($auth->{account});
  return {
    rotationKeys        => $auth->{account}{recovery_key} ? [ $auth->{account}{recovery_key} ] : undef,
    alsoKnownAs         => $doc->{alsoKnownAs},
    verificationMethods => $doc->{verificationMethod},
    services            => $doc->{service},
  };
}

sub update_handle ($self, $access_token, $handle) {
  my $auth   = $self->auth_from_bearer($access_token, 'access');
  my $did    = $auth->{account}{did};
  my $target = normalize_handle($handle, $self->{config}{service_handle_domain} // 'localhost')
    or die {
      status  => 400,
      error   => 'InvalidHandle',
      message => 'Handle is not valid for this service',
    };

  my $existing = $self->account_by_handle($target);
  if ($existing && $existing->{did} ne $did) {
    die {
      status  => 400,
      error   => 'HandleNotAvailable',
      message => "Handle already exists: $target",
    };
  }

  $self->dbh->do(
    q{UPDATE accounts SET handle = ?, updated_at = ?, plc_operation_json = ? WHERE did = ?},
    undef,
    $target,
    time,
    encode_json($self->_plc_operation_for($did, $target, $auth->{account}{signing_public})),
    $did,
  );

  return {};
}

sub create_app_password ($self, $access_token, $name, $privileged = 0) {
  my $auth = $self->auth_from_bearer($access_token, 'access');
  my $password = join('-', map { substr(_token_string(5), 0, 4) } 1 .. 4);
  my $salt = _token_string(16);
  my $id = _token_string(24);
  my $now = time;

  $self->dbh->do(
    q{INSERT INTO app_passwords (id, did, name, privileged, password_salt, password_hash, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)},
    undef,
    $id, $auth->{account}{did}, $name, $privileged ? 1 : 0, $salt, $self->_hash_password($password, $salt), $now,
  );

  return {
    name       => $name,
    password   => $password,
    createdAt  => _iso8601($now),
    privileged => $privileged ? true : false,
  };
}

sub list_app_passwords ($self, $access_token) {
  my $auth = $self->auth_from_bearer($access_token, 'access');
  my $rows = $self->dbh->selectall_arrayref(
    q{SELECT name, privileged, created_at FROM app_passwords WHERE did = ? AND revoked_at IS NULL ORDER BY created_at DESC},
    { Slice => {} },
    $auth->{account}{did},
  );

  return {
    passwords => [
      map +{
        name       => $_->{name},
        createdAt  => _iso8601($_->{created_at}),
        privileged => $_->{privileged} ? true : false,
      }, @$rows
    ],
  };
}

sub revoke_app_password ($self, $access_token, $name) {
  my $auth = $self->auth_from_bearer($access_token, 'access');
  $self->dbh->do(
    q{UPDATE app_passwords SET revoked_at = ? WHERE did = ? AND name = ? AND revoked_at IS NULL},
    undef,
    time,
    $auth->{account}{did},
    $name,
  );
  return {};
}

sub create_invite_codes ($self, $count = 1, $created_by = undef) {
  my @codes;
  my $now = time;
  for (1 .. $count) {
    my $code = join('-', map { substr(_token_string(6), 0, 5) } 1 .. 3);
    push @codes, $code;
    $self->dbh->do(
      q{INSERT OR IGNORE INTO invite_codes (code, created_by, created_at) VALUES (?, ?, ?)},
      undef,
      $code, $created_by, $now,
    );
  }
  return \@codes;
}

sub list_invite_codes ($self) {
  return $self->dbh->selectall_arrayref(
    q{SELECT code, created_by, disabled, created_at FROM invite_codes ORDER BY created_at DESC},
    { Slice => {} },
  );
}

sub create_record ($self, $access_token, $payload) {
  my $auth = $self->auth_from_bearer($access_token, 'access');
  $self->_assert_repo_owner($auth->{account}, $payload->{repo});

  my $rkey = $payload->{rkey} || next_tid();
  my $now  = time;
  my $uri  = "at://$auth->{account}{did}/$payload->{collection}/$rkey";
  my $cid  = $self->_cid_for_record($payload->{record});

  $self->_assert_swap_commit($auth->{account}{did}, $payload->{swapCommit});

  $self->dbh->do(
    q{
      INSERT INTO records (did, collection, rkey, uri, cid, record_json, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    },
    undef,
    $auth->{account}{did},
    $payload->{collection},
    $rkey,
    $uri,
    $cid,
    encode_json($payload->{record}),
    $now,
    $now,
  );

  my $repo = $self->_rebuild_repo($auth->{account}{did});
  return {
    uri   => $uri,
    cid   => $cid,
    commit => {
      cid => $repo->{commit_cid},
      rev => $repo->{rev},
    },
    validationStatus => 'unknown',
  };
}

sub put_record ($self, $access_token, $payload) {
  my $auth = $self->auth_from_bearer($access_token, 'access');
  $self->_assert_repo_owner($auth->{account}, $payload->{repo});
  $self->_assert_swap_commit($auth->{account}{did}, $payload->{swapCommit});

  my $existing = $self->get_record($auth->{account}{did}, $payload->{collection}, $payload->{rkey}, 1);
  if (defined $payload->{swapRecord} && $existing && ($existing->{cid} // '') ne $payload->{swapRecord}) {
    die {
      status  => 400,
      error   => 'InvalidSwap',
      message => 'swapRecord did not match current record CID',
    };
  }

  my $cid = $self->_cid_for_record($payload->{record});
  my $uri = "at://$auth->{account}{did}/$payload->{collection}/$payload->{rkey}";
  my $now = time;

  $self->dbh->do(
    q{
      INSERT INTO records (did, collection, rkey, uri, cid, record_json, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(did, collection, rkey)
      DO UPDATE SET cid = excluded.cid, record_json = excluded.record_json, updated_at = excluded.updated_at
    },
    undef,
    $auth->{account}{did},
    $payload->{collection},
    $payload->{rkey},
    $uri,
    $cid,
    encode_json($payload->{record}),
    $now,
    $now,
  );

  my $repo = $self->_rebuild_repo($auth->{account}{did});
  return {
    uri   => $uri,
    cid   => $cid,
    commit => {
      cid => $repo->{commit_cid},
      rev => $repo->{rev},
    },
    validationStatus => 'unknown',
  };
}

sub delete_record ($self, $access_token, $payload) {
  my $auth = $self->auth_from_bearer($access_token, 'access');
  $self->_assert_repo_owner($auth->{account}, $payload->{repo});
  $self->_assert_swap_commit($auth->{account}{did}, $payload->{swapCommit});

  if (defined $payload->{swapRecord}) {
    my $existing = $self->get_record($auth->{account}{did}, $payload->{collection}, $payload->{rkey}, 1);
    if ($existing && ($existing->{cid} // '') ne $payload->{swapRecord}) {
      die {
        status  => 400,
        error   => 'InvalidSwap',
        message => 'swapRecord did not match current record CID',
      };
    }
  }

  $self->dbh->do(
    q{DELETE FROM records WHERE did = ? AND collection = ? AND rkey = ?},
    undef,
    $auth->{account}{did},
    $payload->{collection},
    $payload->{rkey},
  );

  my $repo = $self->_rebuild_repo($auth->{account}{did});
  return {
    commit => {
      cid => $repo->{commit_cid},
      rev => $repo->{rev},
    },
  };
}

sub apply_writes ($self, $access_token, $payload) {
  my $auth = $self->auth_from_bearer($access_token, 'access');
  $self->_assert_repo_owner($auth->{account}, $payload->{repo});
  $self->_assert_swap_commit($auth->{account}{did}, $payload->{swapCommit});

  my @results;
  my $now = time;

  for my $write (@{ $payload->{writes} || [] }) {
    if (exists $write->{value} && !exists $write->{rkey}) {
      $write->{rkey} = next_tid();
    }

    if (exists $write->{value}) {
      my $cid = $self->_cid_for_record($write->{value});
      my $uri = "at://$auth->{account}{did}/$write->{collection}/$write->{rkey}";
      $self->dbh->do(
        q{
          INSERT INTO records (did, collection, rkey, uri, cid, record_json, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(did, collection, rkey)
          DO UPDATE SET cid = excluded.cid, record_json = excluded.record_json, updated_at = excluded.updated_at
        },
        undef,
        $auth->{account}{did}, $write->{collection}, $write->{rkey}, $uri, $cid, encode_json($write->{value}), $now, $now,
      );
      push @results, {
        uri => $uri,
        cid => $cid,
        validationStatus => 'unknown',
      };
    } else {
      $self->dbh->do(
        q{DELETE FROM records WHERE did = ? AND collection = ? AND rkey = ?},
        undef,
        $auth->{account}{did}, $write->{collection}, $write->{rkey},
      );
      push @results, {};
    }
  }

  my $repo = $self->_rebuild_repo($auth->{account}{did});
  return {
    commit => {
      cid => $repo->{commit_cid},
      rev => $repo->{rev},
    },
    results => \@results,
  };
}

sub get_record ($self, $repo, $collection, $rkey, $allow_internal = 0) {
  my $did = $allow_internal ? $repo : $self->_resolve_repo($repo)->{did};
  my $row = $self->dbh->selectrow_hashref(
    q{SELECT * FROM records WHERE did = ? AND collection = ? AND rkey = ?},
    undef,
    $did, $collection, $rkey,
  );
  return undef if $allow_internal && !$row;
  die {
    status  => 404,
    error   => 'RecordNotFound',
    message => "Record not found for $did/$collection/$rkey",
  } unless $row;

  return {
    uri   => $row->{uri},
    cid   => $row->{cid},
    value => decode_json($row->{record_json}),
  };
}

sub list_records ($self, $repo, $collection, $limit = 50, $cursor = undef, $reverse = 0) {
  my $did = $self->_resolve_repo($repo)->{did};
  my @bind = ($did, $collection);
  my $sql = q{SELECT * FROM records WHERE did = ? AND collection = ?};
  if (defined $cursor && length $cursor) {
    $sql .= $reverse ? q{ AND rkey < ?} : q{ AND rkey > ?};
    push @bind, $cursor;
  }
  $sql .= $reverse ? q{ ORDER BY rkey DESC} : q{ ORDER BY rkey ASC};
  $sql .= q{ LIMIT ?};
  push @bind, ($limit > 100 ? 100 : $limit);

  my $rows = $self->dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
  my $next_cursor = @$rows == ($limit > 100 ? 100 : $limit) ? $rows->[-1]{rkey} : undef;
  return {
    ($next_cursor ? (cursor => $next_cursor) : ()),
    records => [
      map +{
        uri   => $_->{uri},
        cid   => $_->{cid},
        value => decode_json($_->{record_json}),
      }, @$rows
    ],
  };
}

sub describe_repo ($self, $repo) {
  my $account = $self->_resolve_repo($repo);
  my $collections = $self->dbh->selectcol_arrayref(
    q{SELECT DISTINCT collection FROM records WHERE did = ? ORDER BY collection},
    undef,
    $account->{did},
  );
  return {
    handle      => $account->{handle},
    did         => $account->{did},
    didDoc      => $self->did_doc($account),
    collections => $collections,
    handleIsCorrect => true,
  };
}

sub upload_blob ($self, $access_token, $bytes, $mime_type = 'application/octet-stream') {
  my $auth = $self->auth_from_bearer($access_token, 'access');
  my $cid  = ATProto::PDS::Repo::CID->for_raw($bytes)->to_string;
  my $hash = sha256_hex($bytes);
  my $path = File::Spec->catfile($self->_blob_root, $cid);

  open(my $fh, '>:raw', $path) or die "open($path): $!";
  print {$fh} $bytes;
  close($fh);

  $self->dbh->do(
    q{
      INSERT INTO blobs (cid, did, mime_type, size, sha256, path, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(cid) DO NOTHING
    },
    undef,
    $cid, $auth->{account}{did}, $mime_type, length($bytes), $hash, $path, time,
  );

  return {
    blob => {
      '$type'   => 'blob',
      ref       => { '$link' => $cid },
      mimeType  => $mime_type,
      size      => length($bytes),
    },
  };
}

sub get_blob ($self, $did, $cid) {
  $self->account_by_did($did)
    or die { status => 404, error => 'RepoNotFound', message => "Repo not found: $did" };
  my $blob = $self->dbh->selectrow_hashref(
    q{SELECT * FROM blobs WHERE did = ? AND cid = ?},
    undef,
    $did, $cid,
  ) or die {
    status  => 404,
    error   => 'BlobNotFound',
    message => "Blob not found: $cid",
  };
  return $blob;
}

sub list_blobs ($self, $did, $limit = 500, $cursor = undef) {
  $self->account_by_did($did)
    or die { status => 404, error => 'RepoNotFound', message => "Repo not found: $did" };

  my @bind = ($did);
  my $sql = q{SELECT cid FROM blobs WHERE did = ?};
  if (defined $cursor && length $cursor) {
    $sql .= q{ AND cid > ?};
    push @bind, $cursor;
  }
  $sql .= q{ ORDER BY cid ASC LIMIT ?};
  push @bind, ($limit > 1000 ? 1000 : $limit);

  my $rows = $self->dbh->selectcol_arrayref($sql, undef, @bind);
  my $next_cursor = @$rows == ($limit > 1000 ? 1000 : $limit) ? $rows->[-1] : undef;
  return {
    ($next_cursor ? (cursor => $next_cursor) : ()),
    cids => $rows,
  };
}

sub list_missing_blobs ($self, $repo) {
  my $account = $self->_resolve_repo($repo);
  return {
    blobs => [],
    cursor => undef,
    did => $account->{did},
  };
}

sub current_repo ($self, $did) {
  return $self->dbh->selectrow_hashref(q{SELECT * FROM repo_roots WHERE did = ?}, undef, $did);
}

sub latest_commit ($self, $did) {
  my $repo = $self->current_repo($did)
    or die { status => 404, error => 'RepoNotFound', message => "Repo not found: $did" };
  return {
    cid => $repo->{commit_cid},
    rev => $repo->{rev},
  };
}

sub repo_status ($self, $did) {
  my $account = $self->account_by_did($did)
    or die { status => 404, error => 'RepoNotFound', message => "Repo not found: $did" };
  my $repo = $self->current_repo($did);

  return {
    did    => $did,
    active => $account->{active} ? true : false,
    ($account->{status} ? (status => $account->{status}) : ()),
    ($repo ? (rev => $repo->{rev}) : ()),
  };
}

sub list_repos ($self, $limit = 500, $cursor = undef) {
  my @bind;
  my $sql = q{
    SELECT rr.did, rr.commit_cid AS head, rr.rev, a.active, a.status
    FROM repo_roots rr
    JOIN accounts a ON a.did = rr.did
  };
  if (defined $cursor && length $cursor) {
    $sql .= q{ WHERE rr.did > ?};
    push @bind, $cursor;
  }
  $sql .= q{ ORDER BY rr.did ASC LIMIT ?};
  push @bind, ($limit > 1000 ? 1000 : $limit);

  my $rows = $self->dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
  my $next_cursor = @$rows == ($limit > 1000 ? 1000 : $limit) ? $rows->[-1]{did} : undef;
  return {
    ($next_cursor ? (cursor => $next_cursor) : ()),
    repos => [
      map +{
        did    => $_->{did},
        head   => $_->{head},
        rev    => $_->{rev},
        active => $_->{active} ? true : false,
        ($_->{status} ? (status => $_->{status}) : ()),
      }, @$rows
    ],
  };
}

sub list_repos_by_collection ($self, $collection, $limit = 500, $cursor = undef) {
  my @bind = ($collection);
  my $sql = q{SELECT DISTINCT did FROM records WHERE collection = ?};
  if (defined $cursor && length $cursor) {
    $sql .= q{ AND did > ?};
    push @bind, $cursor;
  }
  $sql .= q{ ORDER BY did ASC LIMIT ?};
  push @bind, ($limit > 2000 ? 2000 : $limit);

  my $rows = $self->dbh->selectcol_arrayref($sql, undef, @bind);
  my $next_cursor = @$rows == ($limit > 2000 ? 2000 : $limit) ? $rows->[-1] : undef;
  return {
    ($next_cursor ? (cursor => $next_cursor) : ()),
    repos => [ map +{ did => $_ }, @$rows ],
  };
}

sub get_repo_car ($self, $did) {
  my $repo = $self->current_repo($did)
    or die { status => 404, error => 'RepoNotFound', message => "Repo not found: $did" };
  my $blocks = $self->_blocks_for_commit($repo->{commit_cid});
  return write_car(ATProto::PDS::Repo::CID->from_string($repo->{commit_cid}), $blocks);
}

sub get_record_car ($self, $did, $collection, $rkey) {
  $self->get_record($did, $collection, $rkey, 1)
    or die { status => 404, error => 'RecordNotFound', message => 'Record not found' };
  return $self->get_repo_car($did);
}

sub get_blocks_car ($self, $did, $cid_strings) {
  $self->account_by_did($did)
    or die { status => 404, error => 'RepoNotFound', message => "Repo not found: $did" };
  my @blocks;
  for my $cid (@$cid_strings) {
    my $row = $self->dbh->selectrow_hashref(q{SELECT * FROM blocks WHERE cid = ?}, undef, $cid);
    next unless $row;
    push @blocks, {
      cid   => ATProto::PDS::Repo::CID->from_string($row->{cid}),
      bytes => $row->{bytes},
    };
  }
  my $repo = $self->current_repo($did);
  return write_car($repo ? ATProto::PDS::Repo::CID->from_string($repo->{commit_cid}) : undef, \@blocks);
}

sub create_report ($self, $access_token, $payload) {
  my $auth = $self->auth_from_bearer($access_token, 'access');
  $self->dbh->do(
    q{INSERT INTO moderation_reports (id, did, reason_type, reason, subject_json, created_at) VALUES (?, ?, ?, ?, ?, ?)},
    undef,
    _token_string(24),
    $auth->{account}{did},
    $payload->{reasonType},
    $payload->{reason},
    encode_json($payload->{subject} // {}),
    time,
  );
  return {};
}

sub admin_accounts ($self) {
  return $self->dbh->selectall_arrayref(q{SELECT * FROM accounts ORDER BY created_at DESC}, { Slice => {} });
}

sub admin_send_email ($self, $did, $subject, $content) {
  return {
    sent => true,
    did => $did,
    subject => $subject,
    content => $content,
  };
}

sub request_code ($self, $did, $purpose, $target = undef) {
  my $id = _token_string(24);
  my $code = substr(_token_string(12), 0, 8);
  $self->dbh->do(
    q{INSERT INTO pending_codes (id, did, purpose, target, code, created_at) VALUES (?, ?, ?, ?, ?, ?)},
    undef,
    $id, $did, $purpose, $target, $code, time,
  );
  return { id => $id, code => $code };
}

sub verify_code ($self, $did, $purpose, $code) {
  my $row = $self->dbh->selectrow_hashref(
    q{SELECT * FROM pending_codes WHERE did = ? AND purpose = ? AND code = ? AND used_at IS NULL ORDER BY created_at DESC LIMIT 1},
    undef,
    $did, $purpose, $code,
  ) or return undef;
  $self->dbh->do(q{UPDATE pending_codes SET used_at = ? WHERE id = ?}, undef, time, $row->{id});
  return $row;
}

sub set_account_email ($self, $did, $email, $confirmed = 0) {
  $self->dbh->do(
    q{UPDATE accounts SET email = ?, email_confirmed = ?, updated_at = ? WHERE did = ?},
    undef,
    $email, $confirmed ? 1 : 0, time, $did,
  );
}

sub set_account_password ($self, $did, $password) {
  my $salt = _token_string(16);
  $self->dbh->do(
    q{UPDATE accounts SET password_salt = ?, password_hash = ?, updated_at = ? WHERE did = ?},
    undef,
    $salt, $self->_hash_password($password, $salt), time, $did,
  );
}

sub set_account_active ($self, $did, $active, $status = undef) {
  $self->dbh->do(
    q{UPDATE accounts SET active = ?, status = ?, updated_at = ? WHERE did = ?},
    undef,
    $active ? 1 : 0, $status, time, $did,
  );
}

sub delete_account ($self, $did) {
  $self->dbh->do(q{DELETE FROM records WHERE did = ?}, undef, $did);
  $self->dbh->do(q{DELETE FROM repo_roots WHERE did = ?}, undef, $did);
  $self->dbh->do(q{DELETE FROM accounts WHERE did = ?}, undef, $did);
}

sub _rebuild_repo ($self, $did) {
  my $account = $self->account_by_did($did) or die "unknown account: $did";
  my $rows = $self->dbh->selectall_arrayref(
    q{SELECT collection, rkey, cid, record_json FROM records WHERE did = ? ORDER BY collection, rkey},
    { Slice => {} },
    $did,
  );

  my %entries;
  my @blocks;
  my %seen;
  for my $row (@$rows) {
    my $record = decode_json($row->{record_json});
    my $dag    = $self->_lex_to_dag($record);
    my $bytes  = encode_dag_cbor($dag);
    my $cid    = ATProto::PDS::Repo::CID->for_dag_cbor($bytes);
    $entries{"$row->{collection}/$row->{rkey}"} = $cid;
    push @blocks, { cid => $cid, bytes => $bytes } unless $seen{$cid->to_string}++;
    if ($row->{cid} ne $cid->to_string) {
      $self->dbh->do(
        q{UPDATE records SET cid = ?, updated_at = ? WHERE did = ? AND collection = ? AND rkey = ?},
        undef,
        $cid->to_string, time, $did, $row->{collection}, $row->{rkey},
      );
    }
  }

  my $mst = build_mst(\%entries);
  for my $block (@{ $mst->{blocks} }) {
    push @blocks, $block unless $seen{$block->{cid}->to_string}++;
  }

  my $prev = $self->current_repo($did);
  my $rev  = next_tid($prev ? $prev->{rev} : undef);
  my $commit_unsigned = {
    did     => $did,
    version => 3,
    rev     => $rev,
    prev    => undef,
    data    => $mst->{root},
  };
  my $unsigned_bytes = encode_dag_cbor($commit_unsigned);
  my $pk = Crypt::PK::Ed25519->new;
  $pk->import_key_raw($account->{signing_private}, 'private');
  my $sig = $pk->sign_message($unsigned_bytes);
  my $commit = {
    %$commit_unsigned,
    sig => ATProto::PDS::Repo::Bytes->new($sig),
  };
  my $commit_bytes = encode_dag_cbor($commit);
  my $commit_cid   = ATProto::PDS::Repo::CID->for_dag_cbor($commit_bytes);
  unshift @blocks, { cid => $commit_cid, bytes => $commit_bytes };

  my $now = time;
  $self->_txn(sub {
    for my $block (@blocks) {
      $self->dbh->do(
        q{INSERT OR IGNORE INTO blocks (cid, codec, bytes, created_at) VALUES (?, ?, ?, ?)},
        undef,
        $block->{cid}->to_string,
        $block->{cid}->codec,
        $block->{bytes},
        $now,
      );
    }

    $self->dbh->do(q{DELETE FROM commit_blocks WHERE commit_cid = ?}, undef, $commit_cid->to_string);
    for my $index (0 .. $#blocks) {
      $self->dbh->do(
        q{INSERT INTO commit_blocks (commit_cid, cid, ord) VALUES (?, ?, ?)},
        undef,
        $commit_cid->to_string,
        $blocks[$index]{cid}->to_string,
        $index,
      );
    }

    $self->dbh->do(
      q{INSERT OR REPLACE INTO repo_commits (cid, did, rev, prev_commit_cid, data_cid, created_at) VALUES (?, ?, ?, ?, ?, ?)},
      undef,
      $commit_cid->to_string,
      $did,
      $rev,
      ($prev ? $prev->{commit_cid} : undef),
      $mst->{root}->to_string,
      $now,
    );

    $self->dbh->do(
      q{INSERT OR REPLACE INTO repo_roots (did, commit_cid, data_cid, rev, prev_commit_cid, updated_at) VALUES (?, ?, ?, ?, ?, ?)},
      undef,
      $did,
      $commit_cid->to_string,
      $mst->{root}->to_string,
      $rev,
      ($prev ? $prev->{commit_cid} : undef),
      $now,
    );
  });

  return {
    did            => $did,
    commit_cid     => $commit_cid->to_string,
    data_cid       => $mst->{root}->to_string,
    rev            => $rev,
    prev_commit_cid => $prev ? $prev->{commit_cid} : undef,
  };
}

sub _blocks_for_commit ($self, $commit_cid) {
  my $rows = $self->dbh->selectall_arrayref(
    q{
      SELECT b.cid, b.bytes
      FROM commit_blocks cb
      JOIN blocks b ON b.cid = cb.cid
      WHERE cb.commit_cid = ?
      ORDER BY cb.ord ASC
    },
    { Slice => {} },
    $commit_cid,
  );

  return [
    map +{
      cid   => ATProto::PDS::Repo::CID->from_string($_->{cid}),
      bytes => $_->{bytes},
    }, @$rows
  ];
}

sub _find_app_password ($self, $did, $password) {
  my $rows = $self->dbh->selectall_arrayref(
    q{SELECT * FROM app_passwords WHERE did = ? AND revoked_at IS NULL},
    { Slice => {} },
    $did,
  );
  for my $row (@$rows) {
    return $row if $self->_verify_password($password, $row->{password_salt}, $row->{password_hash});
  }
  return undef;
}

sub _assert_repo_owner ($self, $account, $repo_identifier) {
  my $resolved = $self->_resolve_repo($repo_identifier);
  die {
    status  => 403,
    error   => 'AuthenticationRequired',
    message => 'Authenticated user does not own this repo',
  } unless $resolved->{did} eq $account->{did};
}

sub _resolve_repo ($self, $repo) {
  return $repo =~ /^did:/
    ? ($self->account_by_did($repo) || die { status => 404, error => 'RepoNotFound', message => "Repo not found: $repo" })
    : ($self->account_by_handle($repo) || die { status => 404, error => 'RepoNotFound', message => "Repo not found: $repo" });
}

sub _assert_swap_commit ($self, $did, $swap_commit) {
  return unless defined $swap_commit && length $swap_commit;
  my $repo = $self->current_repo($did);
  if (!$repo || $repo->{commit_cid} ne $swap_commit) {
    die {
      status  => 400,
      error   => 'InvalidSwap',
      message => 'swapCommit did not match current repo commit',
    };
  }
}

sub _cid_for_record ($self, $record) {
  return ATProto::PDS::Repo::CID->for_dag_cbor(encode_dag_cbor($self->_lex_to_dag($record)))->to_string;
}

sub _lex_to_dag ($self, $value) {
  return undef unless defined $value;

  if (ref($value) eq 'ARRAY') {
    return [ map { $self->_lex_to_dag($_) } @$value ];
  }

  if (ref($value) eq 'HASH') {
    if ((keys %$value) == 1 && exists $value->{'$link'}) {
      return ATProto::PDS::Repo::CID->from_string($value->{'$link'});
    }
    my %copy;
    for my $key (keys %$value) {
      $copy{$key} = $self->_lex_to_dag($value->{$key});
    }
    return \%copy;
  }

  return $value;
}

sub _plc_operation_for ($self, $did, $handle, $public_key) {
  my $multikey = 'z' . encode_base58btc("\xed\x01" . $public_key);
  return {
    did => $did,
    alsoKnownAs => [ 'at://' . $handle ],
    verificationMethods => {
      atproto => $multikey,
    },
    services => {
      atproto_pds => {
        type => 'AtprotoPersonalDataServer',
        endpoint => $self->{config}{base_url},
      },
    },
  };
}

sub _new_plc_did ($self) {
  my $alphabet = '234567abcdefghijklmnopqrstuvwxyz';
  my $bytes = random_bytes(24);
  my $suffix = join '', map { substr($alphabet, ord($_) % length($alphabet), 1) } split //, $bytes;
  return 'did:plc:' . substr($suffix, 0, 24);
}

sub _blob_root ($self) {
  return File::Spec->catdir($self->{config}{data_dir}, 'blobs');
}

sub _hash_password ($self, $password, $salt) {
  return sha256_hex(join(':', $salt, $password));
}

sub _verify_password ($self, $password, $salt, $hash) {
  return sha256_hex(join(':', $salt, $password)) eq $hash;
}

sub _txn ($self, $code) {
  my $dbh = $self->dbh;
  my $ok = eval {
    $dbh->begin_work;
    $code->();
    $dbh->commit;
    1;
  };
  if (!$ok) {
    my $error = $@;
    eval { $dbh->rollback };
    die $error;
  }
}

sub _iso8601 ($epoch) {
  my @parts = gmtime($epoch);
  return sprintf(
    '%04d-%02d-%02dT%02d:%02d:%02dZ',
    $parts[5] + 1900,
    $parts[4] + 1,
    $parts[3],
    $parts[2],
    $parts[1],
    $parts[0],
  );
}

sub _token_string ($length = 24) {
  my $alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  my $bytes = random_bytes($length);
  return join '', map { substr($alphabet, ord($_) % length($alphabet), 1) } split //, $bytes;
}

1;
