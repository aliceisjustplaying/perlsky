package ATProto::PDS::Store::SQLite;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use DBI qw(:sql_types);
use Exporter 'import';
use File::Basename qw(dirname);
use File::Path qw(make_path);
use JSON::PP qw(decode_json encode_json);
use ATProto::PDS::Repo::CAR qw(read_car);
use ATProto::PDS::Repo::CID qw(CID_CODEC_DAG_CBOR CID_CODEC_RAW);
use ATProto::PDS::Repo::DagCbor qw(decode_dag_cbor);
use ATProto::PDS::Metrics::Store qw(observe_store_operation);
use ATProto::PDS::Store::SQLite::Events qw(
  append_event
  earliest_event_seq_after_time
  latest_event_seq
  list_events_after
  list_events_from
  next_event_after_seq
);
use ATProto::PDS::Store::SQLite::ActionTokens qw(
  consume_action_token
  create_action_token
  get_action_token
  latest_action_token
);
use ATProto::PDS::Store::SQLite::Invites qw(
  create_invite_code
  disable_invite_codes
  get_invite_code
  list_invite_code_uses
  list_invite_codes
  list_invite_codes_for_account
  record_invite_code_use
);
use ATProto::PDS::Store::SQLite::Labels qw(
  get_label
  list_labels
  put_label
);
use ATProto::PDS::Store::SQLite::Moderation qw(
  create_report
  get_report
  get_subject_status
  list_subject_statuses
  put_subject_status
);
use ATProto::PDS::Store::SQLite::Operations qw(
  get_host_notice
  get_repo_head
  list_host_notices
  log_outbound_email
  set_repo_head
  touch_host_notice
);
use ATProto::PDS::Store::SQLite::Preferences qw(
  get_notification_preferences
  list_preferences
  put_notification_preferences
  put_preferences
);
use ATProto::PDS::Store::SQLite::Reservations qw(
  claim_reserved_signing_key
  get_reserved_handle
  get_reserved_signing_key
  list_reserved_handles
  reserve_handle
  reserve_signing_key
);

our @EXPORT_OK = qw(default_migrations);

sub new ($class, %args) {
  die 'path is required' unless defined $args{path} && length $args{path};
  return bless {
    path => $args{path},
    dbh  => undef,
    metrics => $args{metrics},
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
  return observe_store_operation($self->{metrics}, 'txn', sub {
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
  });
}

sub create_account ($self, %args) {
  my $did        = $args{did}        // die 'did is required';
  my $account_id = $args{account_id} // $args{id} // _random_id();
  my $handle     = $args{handle}     // die 'handle is required';
  my $now        = $args{created_at} // time;
  my $email      = _normalize_email($args{email});

  _execute_sql(
    $self->dbh,
    q{
      INSERT INTO accounts (
        id, account_id, did, handle, email, password_hash, password_salt,
        created_at, updated_at, deactivated_at, deleted_at, email_confirmed_at,
        did_doc_json, private_key, public_key, public_key_multibase, signing_key_did,
        repo_commit_cid, repo_root_cid, repo_rev, invites_disabled, invite_note
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    },
    [
      $account_id,
      $account_id,
      $did,
      $handle,
      $email,
      $args{password_hash},
      $args{password_salt},
      $now,
      $now,
      $args{deactivated_at},
      $args{deleted_at},
      $args{email_confirmed_at},
      _maybe_json($args{did_doc}),
      $args{private_key},
      $args{public_key},
      $args{public_key_multibase},
      $args{signing_key_did},
      $args{repo_commit_cid},
      $args{repo_root_cid},
      $args{repo_rev},
      $args{invites_disabled} ? 1 : 0,
      $args{invite_note},
    ],
    _blob_bind_positions_for_names(
      [qw(
        id account_id did handle email password_hash password_salt
        created_at updated_at deactivated_at deleted_at email_confirmed_at
        did_doc_json private_key public_key public_key_multibase signing_key_did
        repo_commit_cid repo_root_cid repo_rev invites_disabled invite_note
      )],
      qw(password_salt private_key public_key),
    ),
  );

  return $self->get_account_by_did($did);
}

sub update_account ($self, $did, %changes) {
  my %allowed = map { $_ => 1 } qw(
    handle email password_hash password_salt updated_at deactivated_at deleted_at
    email_confirmed_at invites_disabled invite_note
    did_doc private_key public_key public_key_multibase signing_key_did
    repo_commit_cid repo_root_cid repo_rev
  );
  my (@sets, @bind);
  for my $key (sort keys %changes) {
    next unless $allowed{$key};
    my $column = $key eq 'did_doc' ? 'did_doc_json' : $key;
    push @sets, "$column = ?";
    push @bind, $key eq 'did_doc'
      ? _maybe_json($changes{$key})
      : $key eq 'email'
        ? _normalize_email($changes{$key})
        : $changes{$key};
  }
  return $self->get_account_by_did($did) unless @sets;

  push @sets, 'updated_at = ?';
  push @bind, ($changes{updated_at} // time), $did;
  _execute_sql(
    $self->dbh,
    'UPDATE accounts SET ' . join(', ', @sets) . ' WHERE did = ?',
    \@bind,
    _blob_bind_positions_for_names(
      [ map { /^(.+?) = \?$/ ? $1 : () } @sets ],
      qw(password_salt private_key public_key),
    ),
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

sub get_accounts_by_dids ($self, $dids) {
  return [] unless $dids && @$dids;
  my $placeholders = join(', ', ('?') x @$dids);
  return [
    map { $self->_row_to_account($_) }
    @{ $self->dbh->selectall_arrayref(
      "SELECT * FROM accounts WHERE did IN ($placeholders)",
      { Slice => {} },
      @$dids,
    ) }
  ];
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
  $email = _normalize_email($email);
  return $self->_row_to_account($self->dbh->selectrow_hashref(
    q{SELECT * FROM accounts WHERE email = ?},
    undef,
    $email,
  ));
}

sub _normalize_email ($email) {
  return undef unless defined $email;
  return lc $email;
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
        revoked_at, ip, user_agent, next_id, client_id, grant_id,
        dpop_jkt, client_auth_alg, client_auth_kid, client_auth_jkt
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    },
    undef,
    $id,
    $did,
    $args{token},
    $args{kind} // 'account',
    $args{scope} // 'atproto',
    $now,
    $args{expires_at},
    $args{revoked_at},
    $args{ip},
    $args{user_agent},
    $args{next_id},
    $args{client_id},
    $args{grant_id},
    $args{dpop_jkt},
    $args{client_auth_alg},
    $args{client_auth_kid},
    $args{client_auth_jkt},
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

sub rotate_session ($self, $id, %args) {
  return observe_store_operation($self->{metrics}, 'rotate_session', sub {
    my $now = $args{now} // time;
    my $session_ttl = $args{session_ttl} // (30 * 24 * 60 * 60);
    my $grace_ttl   = $args{grace_ttl}   // (2 * 60 * 60);

    return $self->txn(sub ($dbh) {
      my $session = $dbh->selectrow_hashref(
        q{SELECT * FROM sessions WHERE id = ?},
        undef,
        $id,
      );
      return undef unless $session;
      return undef if defined $session->{revoked_at};
      return undef if defined($session->{expires_at}) && $session->{expires_at} < $now;

      if (defined($session->{next_id}) && length($session->{next_id})) {
        my $next = $dbh->selectrow_hashref(
          q{SELECT * FROM sessions WHERE id = ?},
          undef,
          $session->{next_id},
        );
        return undef unless $next;
        return undef if defined $next->{revoked_at};
        return undef if defined($next->{expires_at}) && $next->{expires_at} < $now;
        return $next;
      }

      my $next_id = $args{next_id} // _random_id();
      my $grace_expires_at = $now + $grace_ttl;
      if (defined($session->{expires_at}) && $session->{expires_at} < $grace_expires_at) {
        $grace_expires_at = $session->{expires_at};
      }

      $dbh->do(
        q{UPDATE sessions SET expires_at = ?, next_id = ? WHERE id = ?},
        undef,
        $grace_expires_at,
        $next_id,
        $session->{id},
      );

      $dbh->do(
        q{
          INSERT INTO sessions (
            id, did, token, kind, scope, created_at, expires_at,
            revoked_at, ip, user_agent, next_id, client_id, grant_id,
            dpop_jkt, client_auth_alg, client_auth_kid, client_auth_jkt
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        },
        undef,
        $next_id,
        $session->{did},
        $session->{token},
        $session->{kind},
        $session->{scope},
        $now,
        $now + $session_ttl,
        undef,
        $session->{ip},
        $session->{user_agent},
        undef,
        $args{client_id} // $session->{client_id},
        $args{grant_id} // $session->{grant_id},
        $args{dpop_jkt} // $session->{dpop_jkt},
        $args{client_auth_alg} // $session->{client_auth_alg},
        $args{client_auth_kid} // $session->{client_auth_kid},
        $args{client_auth_jkt} // $session->{client_auth_jkt},
      );

      return $dbh->selectrow_hashref(
        q{SELECT * FROM sessions WHERE id = ?},
        undef,
        $next_id,
      );
    });
  });
}

sub create_oauth_request ($self, %args) {
  my $id = $args{id} // _random_id();
  $self->dbh->do(
    q{
      INSERT INTO oauth_requests (
        id, request_uri, client_id, client_name, client_uri, redirect_uri, scope, state,
        nonce, login_hint, prompt, code_challenge, code_challenge_method,
        client_auth_method, client_auth_alg, client_auth_kid, client_auth_jkt,
        client_assertion_jti, client_assertion_exp, dpop_jkt,
        did, grant_id, code, created_at, expires_at, code_expires_at, consumed_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    },
    undef,
    $id,
    $args{request_uri},
    $args{client_id},
    $args{client_name},
    $args{client_uri},
    $args{redirect_uri},
    $args{scope},
    $args{state},
    $args{nonce},
    $args{login_hint},
    $args{prompt},
    $args{code_challenge},
    $args{code_challenge_method},
    $args{client_auth_method},
    $args{client_auth_alg},
    $args{client_auth_kid},
    $args{client_auth_jkt},
    $args{client_assertion_jti},
    $args{client_assertion_exp},
    $args{dpop_jkt},
    $args{did},
    $args{grant_id},
    $args{code},
    $args{created_at} // time,
    $args{expires_at},
    $args{code_expires_at},
    $args{consumed_at},
  );
  return $self->get_oauth_request($id);
}

sub get_oauth_request ($self, $id) {
  return $self->dbh->selectrow_hashref(
    q{SELECT * FROM oauth_requests WHERE id = ?},
    undef,
    $id,
  );
}

sub get_oauth_request_by_request_uri ($self, $request_uri) {
  return $self->dbh->selectrow_hashref(
    q{SELECT * FROM oauth_requests WHERE request_uri = ?},
    undef,
    $request_uri,
  );
}

sub get_oauth_request_by_code ($self, $code) {
  return $self->dbh->selectrow_hashref(
    q{SELECT * FROM oauth_requests WHERE code = ?},
    undef,
    $code,
  );
}

sub authorize_oauth_request ($self, %args) {
  $self->dbh->do(
    q{
      UPDATE oauth_requests
      SET did = ?, grant_id = ?, code = ?, code_expires_at = ?
      WHERE id = ?
    },
    undef,
    $args{did},
    $args{grant_id},
    $args{code},
    $args{code_expires_at},
    $args{id},
  );
  return $self->get_oauth_request($args{id});
}

sub consume_oauth_request_code ($self, $id, %args) {
  $self->dbh->do(
    q{UPDATE oauth_requests SET consumed_at = ? WHERE id = ?},
    undef,
    $args{consumed_at} // time,
    $id,
  );
  return $self->get_oauth_request($id);
}

sub upsert_oauth_grant ($self, %args) {
  my $id = $args{id} // _random_id();
  my $now = $args{updated_at} // time;
  $self->dbh->do(
    q{
      INSERT INTO oauth_grants (
        id, did, client_id, scope, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(did, client_id) DO UPDATE SET
        scope = excluded.scope,
        updated_at = excluded.updated_at
    },
    undef,
    $id,
    $args{did},
    $args{client_id},
    $args{scope},
    $args{created_at} // $now,
    $now,
  );
  return $self->get_oauth_grant_by_subject($args{did}, $args{client_id});
}

sub get_oauth_grant ($self, $id) {
  return $self->dbh->selectrow_hashref(
    q{SELECT * FROM oauth_grants WHERE id = ?},
    undef,
    $id,
  );
}

sub get_oauth_grant_by_subject ($self, $did, $client_id) {
  return $self->dbh->selectrow_hashref(
    q{SELECT * FROM oauth_grants WHERE did = ? AND client_id = ?},
    undef,
    $did,
    $client_id,
  );
}

sub create_app_password ($self, %args) {
  my $did = $args{did} // die 'did is required';
  my $id  = $args{id}  // _random_id();
  my $now = $args{created_at} // time;

  $self->dbh->do(
    q{
      INSERT INTO app_passwords (
        id, did, name, password_hash, privileged, created_at, revoked_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
    },
    undef,
    $id,
    $did,
    $args{name} // 'app-password',
    $args{password_hash},
    $args{privileged} ? 1 : 0,
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

sub revoke_app_passwords_by_did ($self, $did, %args) {
  $self->dbh->do(
    q{UPDATE app_passwords SET revoked_at = ? WHERE did = ? AND revoked_at IS NULL},
    undef,
    $args{revoked_at} // time,
    $did,
  );
  return $self->list_app_passwords_by_did($did);
}

sub put_blob ($self, %args) {
  return observe_store_operation($self->{metrics}, 'put_blob', sub {
    my $cid = $args{cid} // die 'cid is required';
    my $did = $args{did} // die 'did is required';
    my $now = $args{created_at} // time;
    $self->dbh->do(
      q{
        INSERT INTO blobs (
          cid, did, mime_type, byte_size, storage_path, temporary,
          created_at, referenced_at, quarantined_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(cid) DO UPDATE SET
          did = COALESCE(blobs.did, excluded.did),
          mime_type = excluded.mime_type,
          byte_size = excluded.byte_size,
          storage_path = excluded.storage_path,
          temporary = excluded.temporary,
          referenced_at = COALESCE(excluded.referenced_at, blobs.referenced_at),
          quarantined_at = excluded.quarantined_at
      },
      undef,
      $cid,
      $did,
      $args{mime_type},
      $args{byte_size},
      $args{storage_path},
      $args{temporary} ? 1 : 0,
      $now,
      $args{referenced_at},
      $args{quarantined_at},
    );
    $self->dbh->do(
      q{
        INSERT INTO blob_owners (cid, did, created_at, referenced_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(cid, did) DO UPDATE SET
          referenced_at = COALESCE(excluded.referenced_at, blob_owners.referenced_at)
      },
      undef,
      $cid,
      $did,
      $now,
      $args{referenced_at},
    );
    return $self->get_blob($cid);
  });
}

sub get_blob ($self, $cid) {
  return observe_store_operation($self->{metrics}, 'get_blob', sub {
    return $self->dbh->selectrow_hashref(
      q{SELECT * FROM blobs WHERE cid = ?},
      undef,
      $cid,
    );
  });
}

sub update_blob ($self, $cid, %args) {
  my @sets;
  my @bind;
  for my $column (qw(did mime_type byte_size storage_path temporary referenced_at quarantined_at)) {
    next unless exists $args{$column};
    push @sets, "$column = ?";
    push @bind, $column eq 'temporary' ? ($args{$column} ? 1 : 0) : $args{$column};
  }
  return $self->get_blob($cid) unless @sets;
  push @bind, $cid;
  $self->dbh->do(
    'UPDATE blobs SET ' . join(', ', @sets) . ' WHERE cid = ?',
    undef,
    @bind,
  );
  return $self->get_blob($cid);
}

sub blob_owned_by_did ($self, $cid, $did) {
  return 0 unless defined $cid && length $cid && defined $did && length $did;
  return !!($self->dbh->selectrow_array(
    q{SELECT 1 FROM blob_owners WHERE cid = ? AND did = ?},
    undef,
    $cid,
    $did,
  ) // 0);
}

sub mark_blobs_referenced ($self, $did, @cids) {
  if (!defined($did) || ref($did) || (!length($did) && @cids)) {
    unshift @cids, $did if defined $did;
    undef $did;
  }
  return 0 unless @cids;
  my $now = time;
  my %seen;
  for my $cid (grep { defined && length && !$seen{$_}++ } @cids) {
    $self->dbh->do(
      q{UPDATE blobs SET referenced_at = ?, temporary = 0 WHERE cid = ?},
      undef,
      $now,
      $cid,
    );
    if (defined $did && length $did) {
      $self->dbh->do(
        q{
          INSERT INTO blob_owners (cid, did, created_at, referenced_at)
          VALUES (?, ?, ?, ?)
          ON CONFLICT(cid, did) DO UPDATE SET
            referenced_at = excluded.referenced_at
        },
        undef,
        $cid,
        $did,
        $now,
        $now,
      );
    }
  }
  return scalar keys %seen;
}

sub list_blobs_by_did ($self, $did, %args) {
  my $limit = $args{limit} // 500;
  my $cursor = $args{cursor};
  my @bind = ($did);
  my $sql = q{
    SELECT b.*
    FROM blobs b
    JOIN blob_owners bo ON bo.cid = b.cid
    WHERE bo.did = ?
  };
  if (defined $cursor && length $cursor) {
    $sql .= q{ AND b.cid > ?};
    push @bind, $cursor;
  }
  $sql .= q{ ORDER BY b.cid LIMIT ?};
  push @bind, $limit + 1;
  my $rows = $self->dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
  return _paginate($rows, $limit, 'cid');
}

sub count_blobs_by_did ($self, $did) {
  return $self->dbh->selectrow_array(
    q{SELECT COUNT(*) FROM blob_owners WHERE did = ?},
    undef,
    $did,
  ) // 0;
}

sub put_record ($self, %args) {
  my $did        = $args{did}        // die 'did is required';
  my $collection = $args{collection} // die 'collection is required';
  my $rkey       = $args{rkey}       // die 'rkey is required';
  my $cid        = $args{cid}        // die 'cid is required';
  my $now        = $args{updated_at} // time;

  _execute_sql(
    $self->dbh,
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
    [
      $did,
      $collection,
      $rkey,
      $cid,
      encode_json($args{value}),
      $args{record_bytes},
      $args{created_at} // $now,
      $now,
    ],
    _blob_bind_positions_for_names([qw(
      did collection rkey cid value_json record_bytes created_at updated_at
    )], qw(record_bytes)),
  );

  return $self->get_record($did, $collection, $rkey);
}

sub replace_records_for_did ($self, $did, $records) {
  my $dbh = $self->dbh;
  $dbh->do(q{DELETE FROM records WHERE did = ?}, undef, $did);
  for my $record (@$records) {
    _execute_sql(
      $dbh,
      q{
        INSERT INTO records (
          did, collection, rkey, cid, value_json, record_bytes, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      },
      [
        $did,
        $record->{collection},
        $record->{rkey},
        $record->{cid},
        encode_json($record->{value}),
        $record->{record_bytes},
        $record->{created_at} // time,
        $record->{updated_at} // time,
      ],
      _blob_bind_positions_for_names([qw(
        did collection rkey cid value_json record_bytes created_at updated_at
      )], qw(record_bytes)),
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

sub get_record ($self, $did, $collection, $rkey, $cid = undef) {
  my @bind = ($did, $collection, $rkey);
  my $sql = q{
    SELECT * FROM records
    WHERE did = ? AND collection = ? AND rkey = ?
  };
  if (defined $cid && length $cid) {
    $sql .= q{ AND cid = ?};
    push @bind, $cid;
  }
  my $row = $self->dbh->selectrow_hashref(
    $sql,
    undef,
    @bind,
  );
  return _row_to_record($row);
}

sub list_records ($self, $did, $collection, %args) {
  return observe_store_operation($self->{metrics}, 'list_records', sub {
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
  });
}

sub all_records_for_did ($self, $did) {
  my $rows = $self->dbh->selectall_arrayref(
    q{SELECT * FROM records WHERE did = ? ORDER BY collection, rkey},
    { Slice => {} },
    $did,
  );
  return [ map { _row_to_record($_) } @$rows ];
}

sub list_records_by_collections ($self, $collections) {
  return observe_store_operation($self->{metrics}, 'list_records_by_collections', sub {
    my @collections = grep { defined($_) && length($_) } @{ $collections // [] };
    return [] unless @collections;

    my $placeholders = join(', ', ('?') x @collections);
    my $rows = $self->dbh->selectall_arrayref(
      "SELECT * FROM records WHERE collection IN ($placeholders) ORDER BY did, collection, rkey",
      { Slice => {} },
      @collections,
    );
    return [ map { _row_to_record($_) } @$rows ];
  });
}

sub list_collections_for_did ($self, $did) {
  my $rows = $self->dbh->selectall_arrayref(
    q{SELECT DISTINCT collection FROM records WHERE did = ? ORDER BY collection},
    { Slice => {} },
    $did,
  );
  return [ map { $_->{collection} } @$rows ];
}

sub count_records_by_did ($self, $did) {
  return $self->dbh->selectrow_array(
    q{SELECT COUNT(*) FROM records WHERE did = ?},
    undef,
    $did,
  ) // 0;
}

sub count_records_by_collection ($self, $did, $collection) {
  return $self->dbh->selectrow_array(
    q{SELECT COUNT(*) FROM records WHERE did = ? AND collection = ?},
    undef,
    $did,
    $collection,
  ) // 0;
}

sub put_block ($self, %args) {
  my $cid = $args{cid} // die 'cid is required';
  my $now = $args{created_at} // time;
  _execute_sql(
    $self->dbh,
    q{
      INSERT INTO blocks (cid, codec, bytes, created_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(cid) DO UPDATE SET
        codec = excluded.codec,
        bytes = excluded.bytes
    },
    [
      $cid,
      $args{codec},
      $args{bytes},
      $now,
    ],
    _blob_bind_positions_for_names([qw(cid codec bytes created_at)], qw(bytes)),
  );
  return $self->get_block($cid);
}

sub get_block ($self, $cid) {
  return _row_from_blob_columns($self->dbh->selectrow_hashref(
    q{SELECT * FROM blocks WHERE cid = ?},
    undef,
    $cid,
  ), qw(bytes));
}

sub get_blocks ($self, $cids) {
  return [] unless @$cids;
  my $placeholders = join(', ', ('?') x @$cids);
  my $rows = $self->dbh->selectall_arrayref(
    "SELECT * FROM blocks WHERE cid IN ($placeholders)",
    { Slice => {} },
    @$cids,
  );
  return [ map { _row_from_blob_columns($_, qw(bytes)) } @$rows ];
}

sub put_commit ($self, %args) {
  my $did = $args{did} // die 'did is required';
  my $now = $args{created_at} // time;
  _execute_sql(
    $self->dbh,
    q{
      INSERT INTO commits (
        did, rev, cid, root_cid, prev_cid, commit_bytes, car_bytes, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    },
    [
      $did,
      $args{rev},
      $args{cid},
      $args{root_cid},
      $args{prev_cid},
      $args{commit_bytes},
      $args{car_bytes},
      $now,
    ],
    _blob_bind_positions_for_names(
      [qw(did rev cid root_cid prev_cid commit_bytes car_bytes created_at)],
      qw(commit_bytes car_bytes),
    ),
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
  return _row_from_blob_columns($self->dbh->selectrow_hashref(
    q{SELECT * FROM commits WHERE did = ? AND rev = ?},
    undef,
    $did,
    $rev,
  ), qw(commit_bytes car_bytes));
}

sub get_latest_commit ($self, $did) {
  return _row_from_blob_columns($self->dbh->selectrow_hashref(
    q{SELECT * FROM commits WHERE did = ? ORDER BY created_at DESC, rev DESC LIMIT 1},
    undef,
    $did,
  ), qw(commit_bytes car_bytes));
}

sub repo_car ($self, $did) {
  return observe_store_operation($self->{metrics}, 'repo_car', sub {
    my $row = $self->get_latest_commit($did);
    return $row ? $row->{car_bytes} : undef;
  });
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

sub list_repos_by_collection ($self, $collection, %args) {
  my $limit = $args{limit} // 500;
  $limit = 2000 if $limit > 2000;
  my $cursor = $args{cursor};
  my @bind = ($collection);
  my $sql = q{
    SELECT DISTINCT did
    FROM records
    WHERE collection = ?
  };
  if (defined $cursor && length $cursor) {
    $sql .= q{ AND did > ?};
    push @bind, $cursor;
  }
  $sql .= q{ ORDER BY did LIMIT ?};
  push @bind, $limit + 1;
  my $rows = $self->dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
  return _paginate($rows, $limit, 'did');
}

sub search_accounts ($self, %args) {
  my $limit  = $args{limit} // 50;
  $limit = 100 if $limit > 100;
  my $cursor = $args{cursor};
  my $email  = $args{email};
  my @bind;
  my @where;
  if (defined $email && length $email) {
    push @where, q{email LIKE ?};
    push @bind, '%' . $email . '%';
  }
  if (defined $cursor && length $cursor) {
    push @where, q{did > ?};
    push @bind, $cursor;
  }
  my $sql = q{SELECT * FROM accounts};
  $sql .= q{ WHERE } . join(q{ AND }, @where) if @where;
  $sql .= q{ ORDER BY did LIMIT ?};
  push @bind, $limit + 1;
  my $rows = $self->dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
  my $page = _paginate($rows, $limit, 'did');
  $page->{items} = [ map { $self->_row_to_account($_) } @{ $page->{items} } ];
  return $page;
}

sub repair_binary_columns ($self) {
  my %counts = (
    accounts              => 0,
    reserved_signing_keys => 0,
    blocks                => 0,
    records               => 0,
    commits               => 0,
    events                => 0,
    labels                => 0,
  );

  $self->txn(sub ($dbh) {
    $counts{accounts} = _repair_blob_rows(
      $dbh,
      select_sql => q{SELECT did, password_salt, private_key, public_key FROM accounts},
      update_sql => q{UPDATE accounts SET password_salt = ?, private_key = ?, public_key = ? WHERE did = ?},
      columns    => [qw(password_salt private_key public_key)],
      validate   => sub ($row, $candidate, $column) {
        return 1 unless defined $candidate;
        return length($candidate) == 16 if $column eq 'password_salt';
        return length($candidate) == 32 if $column eq 'private_key';
        return length($candidate) == 65 if $column eq 'public_key';
        return 0;
      },
      params_for => sub ($row, $fixed) {
        return @$fixed{qw(password_salt private_key public_key)}, $row->{did};
      },
    );

    $counts{reserved_signing_keys} = _repair_blob_rows(
      $dbh,
      select_sql => q{SELECT did, private_key, public_key FROM reserved_signing_keys},
      update_sql => q{UPDATE reserved_signing_keys SET private_key = ?, public_key = ? WHERE did = ?},
      columns    => [qw(private_key public_key)],
      validate   => sub ($row, $candidate, $column) {
        return 1 unless defined $candidate;
        return length($candidate) == 32 if $column eq 'private_key';
        return length($candidate) == 65 if $column eq 'public_key';
        return 0;
      },
      params_for => sub ($row, $fixed) {
        return @$fixed{qw(private_key public_key)}, $row->{did};
      },
    );

    $counts{blocks} = _repair_blob_rows(
      $dbh,
      select_sql => q{SELECT cid, codec, bytes FROM blocks},
      update_sql => q{UPDATE blocks SET bytes = ? WHERE cid = ?},
      columns    => [qw(bytes)],
      validate   => sub ($row, $candidate, $column = undef) {
        return _valid_block_bytes($row->{cid}, $row->{codec}, $candidate);
      },
      params_for => sub ($row, $fixed) {
        return $fixed->{bytes}, $row->{cid};
      },
    );

    $counts{records} = _repair_blob_rows(
      $dbh,
      select_sql => q{SELECT did, collection, rkey, cid, record_bytes FROM records},
      update_sql => q{UPDATE records SET record_bytes = ? WHERE did = ? AND collection = ? AND rkey = ?},
      columns    => [qw(record_bytes)],
      validate   => sub ($row, $candidate, $column = undef) {
        return _valid_dag_cbor_cid($row->{cid}, $candidate);
      },
      params_for => sub ($row, $fixed) {
        return $fixed->{record_bytes}, @$row{qw(did collection rkey)};
      },
    );

    $counts{commits} = _repair_blob_rows(
      $dbh,
      select_sql => q{SELECT did, rev, cid, commit_bytes, car_bytes FROM commits},
      update_sql => q{UPDATE commits SET commit_bytes = ?, car_bytes = ? WHERE did = ? AND rev = ?},
      columns    => [qw(commit_bytes car_bytes)],
      validate   => sub ($row, $candidate, $column) {
        return _valid_dag_cbor_cid($row->{cid}, $candidate) if $column eq 'commit_bytes';
        return _valid_car_for_commit($row->{cid}, $candidate);
      },
      params_for => sub ($row, $fixed) {
        return @$fixed{qw(commit_bytes car_bytes)}, @$row{qw(did rev)};
      },
    );

    $counts{events} = _repair_blob_rows(
      $dbh,
      select_sql => q{SELECT seq, type, commit_cid, car_bytes FROM events WHERE car_bytes IS NOT NULL},
      update_sql => q{UPDATE events SET car_bytes = ? WHERE seq = ?},
      columns    => [qw(car_bytes)],
      validate   => sub ($row, $candidate, $column = undef) {
        return _valid_event_car($row, $candidate);
      },
      params_for => sub ($row, $fixed) {
        return $fixed->{car_bytes}, $row->{seq};
      },
    );

    $counts{labels} = _repair_blob_rows(
      $dbh,
      select_sql => q{SELECT id, sig FROM labels WHERE sig IS NOT NULL},
      update_sql => q{UPDATE labels SET sig = ? WHERE id = ?},
      columns    => [qw(sig)],
      validate   => sub ($row, $candidate, $column = undef) {
        return 1 unless defined $candidate;
        return length($candidate) == 64;
      },
      params_for => sub ($row, $fixed) {
        return $fixed->{sig}, $row->{id};
      },
    );
  });

  return \%counts;
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
          CREATE TABLE IF NOT EXISTS blob_owners (
            cid TEXT NOT NULL,
            did TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            referenced_at INTEGER,
            PRIMARY KEY (cid, did),
            FOREIGN KEY (cid) REFERENCES blobs(cid),
            FOREIGN KEY (did) REFERENCES accounts(did)
          )
        },
        q{CREATE INDEX IF NOT EXISTS blob_owners_by_did ON blob_owners (did, created_at DESC)},
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
        q{CREATE INDEX IF NOT EXISTS records_by_collection_did_rkey ON records(collection, did, rkey)},
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
    {
      version => 3,
      statements => [
        q{ALTER TABLE accounts ADD COLUMN email_confirmed_at INTEGER},
        q{ALTER TABLE accounts ADD COLUMN invites_disabled INTEGER NOT NULL DEFAULT 0},
        q{ALTER TABLE accounts ADD COLUMN invite_note TEXT},
        q{
          CREATE TABLE IF NOT EXISTS action_tokens (
            token TEXT PRIMARY KEY,
            did TEXT,
            email TEXT,
            purpose TEXT NOT NULL,
            payload_json TEXT,
            created_at INTEGER NOT NULL,
            expires_at INTEGER,
            consumed_at INTEGER
          )
        },
        q{CREATE INDEX IF NOT EXISTS action_tokens_lookup_idx ON action_tokens (purpose, did, email, created_at DESC)},
        q{
          CREATE TABLE IF NOT EXISTS reserved_signing_keys (
            did TEXT PRIMARY KEY,
            private_key BLOB NOT NULL,
            public_key BLOB NOT NULL,
            public_key_multibase TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            claimed_at INTEGER
          )
        },
        q{
          CREATE TABLE IF NOT EXISTS reserved_handles (
            handle TEXT PRIMARY KEY,
            note TEXT,
            created_at INTEGER NOT NULL
          )
        },
        q{
          CREATE TABLE IF NOT EXISTS invite_codes (
            code TEXT PRIMARY KEY,
            for_account TEXT,
            created_by TEXT,
            use_count INTEGER NOT NULL DEFAULT 1,
            disabled INTEGER NOT NULL DEFAULT 0,
            note TEXT,
            created_at INTEGER NOT NULL
          )
        },
        q{CREATE INDEX IF NOT EXISTS invite_codes_for_account_idx ON invite_codes (for_account, created_at DESC)},
        q{
          CREATE TABLE IF NOT EXISTS invite_code_uses (
            code TEXT NOT NULL,
            used_by TEXT NOT NULL,
            used_at INTEGER NOT NULL,
            PRIMARY KEY (code, used_by)
          )
        },
        q{
          CREATE TABLE IF NOT EXISTS moderation_reports (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            reason_type TEXT NOT NULL,
            reason TEXT,
            subject_json TEXT NOT NULL,
            reported_by TEXT NOT NULL,
            mod_tool_json TEXT,
            created_at INTEGER NOT NULL
          )
        },
        q{
          CREATE TABLE IF NOT EXISTS subject_statuses (
            subject_key TEXT PRIMARY KEY,
            subject_json TEXT NOT NULL,
            takedown_json TEXT,
            deactivated_json TEXT,
            updated_at INTEGER NOT NULL
          )
        },
        q{
          CREATE TABLE IF NOT EXISTS outbound_emails (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            recipient_did TEXT,
            recipient_email TEXT,
            sender_did TEXT,
            subject TEXT,
            content TEXT NOT NULL,
            comment TEXT,
            sent INTEGER NOT NULL DEFAULT 1,
            created_at INTEGER NOT NULL
          )
        },
        q{
          CREATE TABLE IF NOT EXISTS crawl_hosts (
            hostname TEXT PRIMARY KEY,
            requested_at INTEGER,
            notified_at INTEGER,
            last_seq INTEGER,
            status_json TEXT
          )
        },
      ],
    },
    {
      version => 4,
      statements => [
        q{ALTER TABLE accounts ADD COLUMN signing_key_did TEXT},
        q{ALTER TABLE reserved_signing_keys ADD COLUMN signing_key_did TEXT},
      ],
    },
    {
      version => 5,
      statements => [
        q{
          CREATE TABLE IF NOT EXISTS labels (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            subject_key TEXT NOT NULL,
            src TEXT NOT NULL,
            uri TEXT NOT NULL,
            cid TEXT,
            val TEXT NOT NULL,
            exp INTEGER,
            sig BLOB,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            UNIQUE(subject_key, src, val)
          )
        },
        q{CREATE INDEX IF NOT EXISTS labels_lookup_idx ON labels (src, uri, id)},
      ],
    },
    {
      version => 6,
      statements => [
        q{
          CREATE TABLE IF NOT EXISTS preferences (
            did TEXT NOT NULL,
            namespace TEXT NOT NULL,
            pref_type TEXT NOT NULL,
            pref_json TEXT NOT NULL,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (did, namespace, pref_type)
          )
        },
        q{CREATE INDEX IF NOT EXISTS preferences_lookup_idx ON preferences (did, namespace, pref_type)},
      ],
    },
    {
      version => 7,
      statements => [
        q{
          CREATE TABLE IF NOT EXISTS blob_owners (
            cid TEXT NOT NULL,
            did TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            referenced_at INTEGER,
            PRIMARY KEY (cid, did),
            FOREIGN KEY (cid) REFERENCES blobs(cid),
            FOREIGN KEY (did) REFERENCES accounts(did)
          )
        },
        q{CREATE INDEX IF NOT EXISTS blob_owners_by_did ON blob_owners (did, created_at DESC)},
        q{
          INSERT OR IGNORE INTO blob_owners (cid, did, created_at, referenced_at)
          SELECT cid, did, created_at, referenced_at
          FROM blobs
          WHERE did IS NOT NULL
        },
      ],
    },
    {
      version => 8,
      statements => [
        q{ALTER TABLE sessions ADD COLUMN next_id TEXT},
        q{ALTER TABLE app_passwords ADD COLUMN privileged INTEGER NOT NULL DEFAULT 0},
      ],
    },
    {
      version => 9,
      statements => [
        q{ALTER TABLE labels ADD COLUMN neg INTEGER NOT NULL DEFAULT 0},
      ],
    },
    {
      version => 10,
      statements => [
        q{ALTER TABLE sessions ADD COLUMN client_id TEXT},
        q{ALTER TABLE sessions ADD COLUMN grant_id TEXT},
        q{ALTER TABLE sessions ADD COLUMN dpop_jkt TEXT},
        q{ALTER TABLE sessions ADD COLUMN client_auth_alg TEXT},
        q{ALTER TABLE sessions ADD COLUMN client_auth_kid TEXT},
        q{ALTER TABLE sessions ADD COLUMN client_auth_jkt TEXT},
        q{
          CREATE TABLE IF NOT EXISTS oauth_requests (
            id TEXT PRIMARY KEY,
            request_uri TEXT NOT NULL UNIQUE,
            client_id TEXT NOT NULL,
            client_name TEXT,
            client_uri TEXT,
            redirect_uri TEXT NOT NULL,
            scope TEXT NOT NULL,
            state TEXT,
            nonce TEXT,
            login_hint TEXT,
            prompt TEXT,
            code_challenge TEXT NOT NULL,
            code_challenge_method TEXT NOT NULL,
            client_auth_method TEXT NOT NULL,
            client_auth_alg TEXT,
            client_auth_kid TEXT,
            client_auth_jkt TEXT,
            client_assertion_jti TEXT,
            client_assertion_exp INTEGER,
            dpop_jkt TEXT,
            did TEXT,
            grant_id TEXT,
            code TEXT UNIQUE,
            created_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,
            code_expires_at INTEGER,
            consumed_at INTEGER
          )
        },
        q{CREATE INDEX IF NOT EXISTS oauth_requests_by_request_uri ON oauth_requests (request_uri)},
        q{CREATE INDEX IF NOT EXISTS oauth_requests_by_code ON oauth_requests (code)},
        q{
          CREATE TABLE IF NOT EXISTS oauth_grants (
            id TEXT PRIMARY KEY,
            did TEXT NOT NULL,
            client_id TEXT NOT NULL,
            scope TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            UNIQUE (did, client_id)
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
  _row_from_blob_columns($row, qw(password_salt private_key public_key));
  if (defined $row->{did_doc_json} && length $row->{did_doc_json}) {
    $row->{did_doc} = decode_json($row->{did_doc_json});
  }
  delete $row->{did_doc_json};
  $row->{account_id} //= $row->{id};
  return $row;
}

sub _row_from_json_columns ($row, @columns) {
  return undef unless $row;
  for my $column (@columns) {
    next unless defined $row->{$column} && length $row->{$column};
    (my $target = $column) =~ s/_json$//;
    $row->{$target} = decode_json($row->{$column});
    delete $row->{$column};
  }
  return $row;
}

sub _row_to_record ($row) {
  return undef unless $row;
  _row_from_blob_columns($row, qw(record_bytes));
  $row->{value} = decode_json($row->{value_json}) if defined $row->{value_json};
  delete $row->{value_json};
  return $row;
}

sub _execute_sql ($dbh, $sql, $params = undef, $blob_positions = undef) {
  my $sth = $dbh->prepare_cached($sql, undef, 3);
  my %blob = map { $_ => 1 } keys %{ $blob_positions // {} };
  my $values = $params // [];
  for my $index (0 .. $#$values) {
    my $position = $index + 1;
    if ($blob{$position}) {
      $sth->bind_param($position, _normalize_blob_scalar($values->[$index]), SQL_BLOB);
      next;
    }
    $sth->bind_param($position, $values->[$index]);
  }
  $sth->execute;
  return $sth;
}

sub _blob_bind_positions_for_names ($bind_names, @blob_names) {
  my %is_blob = map { $_ => 1 } @blob_names;
  my %positions;
  for my $index (0 .. $#$bind_names) {
    next unless $is_blob{$bind_names->[$index]};
    $positions{$index + 1} = 1;
  }
  return \%positions;
}

sub _row_from_blob_columns ($row, @columns) {
  return undef unless $row;
  for my $column (@columns) {
    next unless exists $row->{$column};
    $row->{$column} = _normalize_blob_scalar($row->{$column});
  }
  return $row;
}

sub _normalize_blob_scalar ($value) {
  return undef unless defined $value;
  my $copy = $value;
  utf8::downgrade($copy, 1);
  return $copy;
}

sub _demangle_utf8_blob ($value) {
  return undef unless defined $value;
  my $copy = _normalize_blob_scalar($value);
  return $copy unless length $copy;
  my $decoded = $copy;
  return undef unless utf8::decode($decoded);
  utf8::downgrade($decoded, 1);
  return $decoded;
}

sub _repair_blob_rows ($dbh, %args) {
  my $rows = $dbh->selectall_arrayref($args{select_sql}, { Slice => {} });
  my %blob_positions = map { $_ + 1 => 1 } 0 .. @{ $args{columns} } - 1;
  my $count = 0;

  ROW:
  for my $row (@$rows) {
    my %fixed = %$row;
    my $changed = 0;
    for my $column (@{ $args{columns} }) {
      my $current = _normalize_blob_scalar($row->{$column});
      $fixed{$column} = $current;
      next if $args{validate}->($row, $current, $column);
      my $candidate = _demangle_utf8_blob($row->{$column});
      next ROW unless defined $candidate && $args{validate}->($row, $candidate, $column);
      $fixed{$column} = $candidate;
      $changed = 1;
    }
    next unless $changed;
    _execute_sql(
      $dbh,
      $args{update_sql},
      [ $args{params_for}->($row, \%fixed) ],
      \%blob_positions,
    );
    $count++;
  }

  return $count;
}

sub _valid_block_bytes ($cid, $codec, $bytes) {
  return 0 unless defined $cid && defined $bytes;
  return 0 if utf8::is_utf8($bytes);
  my $actual = eval {
    local $SIG{__WARN__} = sub { };
    if (($codec // 0) == CID_CODEC_RAW) {
      return ATProto::PDS::Repo::CID->for_raw($bytes)->to_string;
    }
    decode_dag_cbor($bytes) if ($codec // 0) == CID_CODEC_DAG_CBOR;
    return ATProto::PDS::Repo::CID->for_dag_cbor($bytes)->to_string;
  };
  return 0 if $@;
  return ($actual // q()) eq $cid;
}

sub _valid_dag_cbor_cid ($cid, $bytes) {
  return 0 unless defined $cid && defined $bytes;
  return 0 if utf8::is_utf8($bytes);
  my $actual = eval {
    local $SIG{__WARN__} = sub { };
    decode_dag_cbor($bytes);
    return ATProto::PDS::Repo::CID->for_dag_cbor($bytes)->to_string;
  };
  return 0 if $@;
  return ($actual // q()) eq $cid;
}

sub _valid_car_for_commit ($commit_cid, $bytes) {
  return 0 unless defined $bytes;
  my $car = eval { read_car($bytes) };
  return 0 if $@ || !$car;
  return 1 unless defined $commit_cid && length $commit_cid;
  return 0 unless @{ $car->{roots} || [] };
  return ($car->{roots}[0]->to_string // q()) eq $commit_cid;
}

sub _valid_event_car ($row, $bytes) {
  return 0 unless defined $bytes;
  return _valid_car_for_commit($row->{commit_cid}, $bytes);
}

sub _paginate ($rows, $limit, $cursor_key) {
  my @items = @$rows;
  my $cursor;
  if (@items > $limit) {
    my $last = pop @items;
    $cursor = ref($cursor_key) eq 'CODE'
      ? $cursor_key->($last)
      : $last->{$cursor_key};
  }
  return {
    items  => \@items,
    cursor => $cursor,
  };
}

sub _usage_cursor ($use_count, $code) {
  return join("\t", $use_count // 0, $code // q());
}

sub _parse_usage_cursor ($cursor) {
  die 'invalid usage cursor' unless defined $cursor;
  my ($use_count, $code) = split(/\t/, $cursor, 2);
  die 'invalid usage cursor'
    unless defined $use_count && $use_count =~ /\A\d+\z/ && defined $code;
  return (0 + $use_count, $code);
}

sub _maybe_json ($value) {
  return undef unless defined $value;
  return ref($value) ? encode_json($value) : $value;
}

sub _uri_pattern_where ($patterns) {
  return unless $patterns && @$patterns;
  my (@clauses, @bind);
  for my $pattern (@$patterns) {
    if ($pattern =~ /\A(.+)\*\z/) {
      push @clauses, q{uri LIKE ? ESCAPE '\'};
      push @bind, _escape_like_pattern($1) . '%';
      next;
    }
    push @clauses, q{uri = ?};
    push @bind, $pattern;
  }
  return unless @clauses;
  return '(' . join(' OR ', @clauses) . ')', @bind;
}

sub _escape_like_pattern ($pattern) {
  $pattern =~ s/([%_\\])/\\$1/g;
  return $pattern;
}

sub _random_id {
  state $fh = do {
    open(my $random_fh, '<:raw', '/dev/urandom') or die "open(/dev/urandom): $!";
    $random_fh;
  };
  my $bytes = q();
  my $read = read($fh, $bytes, 12);
  die 'failed to read random bytes' unless defined $read && $read == 12;
  return unpack('H*', $bytes);
}

1;
