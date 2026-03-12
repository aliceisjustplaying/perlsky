use v5.34;
use warnings;

use Config ();
use File::Path qw(remove_tree);
use File::Spec;
use FindBin qw($Bin);
use Test2::V0;

BEGIN {
  require lib;
  my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
  lib->import(
    File::Spec->catdir($root, 'lib'),
    File::Spec->catdir($root, 'local', 'lib', 'perl5'),
    File::Spec->catdir($root, 'local', 'lib', 'perl5', $Config::Config{archname}),
  );
}

use ATProto::PDS::Store::SQLite;

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $tmp  = File::Spec->catdir($root, 'data', 'tmp-tests', 'store-sqlite');
remove_tree($tmp) if -d $tmp;

my $db_path = File::Spec->catfile($tmp, 'perlsky.sqlite');
my $store   = ATProto::PDS::Store::SQLite->new(path => $db_path)->bootstrap;

ok(-f $db_path, 'bootstrap creates the sqlite database');

my $account = $store->create_account(
  id            => 'acct-1',
  did           => 'did:web:pds.example.com:users:alice',
  handle        => 'alice.example.com',
  email         => 'Alice@Example.com',
  password_hash => 'sha256:abc',
  did_doc       => { id => 'did:web:pds.example.com:users:alice' },
);

my $second_account = $store->create_account(
  id            => 'acct-2',
  did           => 'did:web:pds.example.com:users:bob',
  handle        => 'bob.example.com',
  email         => 'bob@example.com',
  password_hash => 'sha256:def',
  did_doc       => { id => 'did:web:pds.example.com:users:bob' },
);

is($account->{handle}, 'alice.example.com', 'account round-trips');
is($account->{email}, 'alice@example.com', 'account email is normalized to lowercase');
is($store->get_account_by_email('ALICE@example.com')->{did}, $account->{did}, 'lookup by email is case-insensitive');

$store->create_session(
  id         => 'sess-1',
  did        => $account->{did},
  token      => 'refresh-token',
  expires_at => 1_900_000_000,
  ip         => '127.0.0.1',
);
is($store->get_session('sess-1')->{did}, $account->{did}, 'session is stored');
ok(@{ $store->list_sessions_by_did($account->{did}) } == 1, 'sessions list by did');

my $rotated = $store->rotate_session('sess-1', now => 1_700_000_000);
is($rotated->{did}, $account->{did}, 'session rotation keeps the owner did');
is($store->get_session('sess-1')->{next_id}, $rotated->{id}, 'session rotation stores the successor id');
is($store->rotate_session('sess-1', now => 1_700_000_001)->{id}, $rotated->{id}, 'session rotation reuses the successor during grace');

$store->create_app_password(
  id            => 'app-1',
  did           => $account->{did},
  name          => 'phone',
  password_hash => 'sha256:def',
  privileged    => 1,
);
is($store->list_app_passwords_by_did($account->{did})->[0]{name}, 'phone', 'app password is stored');
is($store->list_app_passwords_by_did($account->{did})->[0]{privileged}, 1, 'app password privilege flag is stored');

$store->put_blob(
  cid          => 'bafkreigh2akiscaildc',
  did          => $account->{did},
  mime_type    => 'image/png',
  byte_size    => 1234,
  storage_path => 'blobs/bafk.png',
);
is($store->get_blob('bafkreigh2akiscaildc')->{byte_size}, 1234, 'blob metadata is stored');
ok($store->blob_owned_by_did('bafkreigh2akiscaildc', $account->{did}), 'primary owner is tracked');

$store->put_blob(
  cid          => 'bafkreigh2akiscaildc',
  did          => $second_account->{did},
  mime_type    => 'image/png',
  byte_size    => 1234,
  storage_path => 'blobs/bafk.png',
);
ok($store->blob_owned_by_did('bafkreigh2akiscaildc', $second_account->{did}), 'second owner is tracked for shared blob');
is($store->count_blobs_by_did($account->{did}), 1, 'first account still counts shared blob');
is($store->count_blobs_by_did($second_account->{did}), 1, 'second account counts shared blob');
is($store->list_blobs_by_did($account->{did})->{items}[0]{cid}, 'bafkreigh2akiscaildc', 'shared blob lists for first owner');
is($store->list_blobs_by_did($second_account->{did})->{items}[0]{cid}, 'bafkreigh2akiscaildc', 'shared blob lists for second owner');

$store->set_repo_head(
  did        => $account->{did},
  commit_cid => 'bafycommit',
  rev        => '3k6h2w3px2',
  root_cid   => 'bafyroot',
);
is($store->get_repo_head($account->{did})->{rev}, '3k6h2w3px2', 'repo head metadata is stored');
my $repo_head_row = $store->dbh->selectrow_hashref(
  q{SELECT commit_cid, rev, root_cid FROM repo_heads WHERE did = ?},
  undef,
  $account->{did},
);
ok(!defined $repo_head_row->{commit_cid} && !defined $repo_head_row->{rev} && !defined $repo_head_row->{root_cid},
  'repo_heads no longer stores duplicate commit metadata');

$store->dbh->do(q{DELETE FROM repo_heads WHERE did = ?}, undef, $account->{did});
is(
  $store->get_repo_head($account->{did})->{commit_cid},
  'bafycommit',
  'repo head falls back to account metadata when repo_heads row is missing',
);

$store->put_record(
  did        => $account->{did},
  collection => 'app.bsky.feed.post',
  rkey       => 'post-1',
  cid        => 'bafypost1',
  record_bytes => q(),
  value      => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'hello',
    createdAt => '2026-03-11T19:00:00Z',
  },
);
$store->put_record(
  did        => $account->{did},
  collection => 'app.bsky.actor.profile',
  rkey       => 'self',
  cid        => 'bafyprofile1',
  record_bytes => q(),
  value      => { displayName => 'Alice' },
);
$store->put_record(
  did        => $second_account->{did},
  collection => 'app.bsky.feed.like',
  rkey       => 'like-1',
  cid        => 'bafylike1',
  record_bytes => q(),
  value      => {
    '$type'   => 'app.bsky.feed.like',
    subject   => { uri => 'at://did:web:pds.example.com:users:alice/app.bsky.feed.post/post-1' },
    createdAt => '2026-03-11T19:01:00Z',
  },
);

my $feed_records = $store->list_records_by_collections([
  'app.bsky.feed.post',
  'app.bsky.feed.like',
]);
is(
  [ map { $_->{collection} } @$feed_records ],
  ['app.bsky.feed.post', 'app.bsky.feed.like'],
  'collection-scoped record listings only return the requested feed collections',
);
is(
  [ map { $_->{did} } @$feed_records ],
  [$account->{did}, $second_account->{did}],
  'collection-scoped record listings preserve did ordering for batched account lookup',
);

$store->revoke_session('sess-1', revoked_at => 123);
is($store->get_session('sess-1')->{revoked_at}, 123, 'sessions can be revoked');

$store->revoke_app_password('app-1', revoked_at => 456);
is($store->get_app_password('app-1')->{revoked_at}, 456, 'app passwords can be revoked');

my $positive_label = $store->put_label(
  subject_key => 'repo:did:web:pds.example.com:users:alice',
  src         => 'did:web:pds.example.com',
  uri         => 'at://did:web:pds.example.com:users:alice',
  val         => '!hide',
  created_at  => 100,
);
ok(!$positive_label->{neg}, 'new labels default to positive state');

my $negated_label = $store->put_label(
  subject_key => 'repo:did:web:pds.example.com:users:alice',
  src         => 'did:web:pds.example.com',
  uri         => 'at://did:web:pds.example.com:users:alice',
  val         => '!hide',
  neg         => 1,
  created_at  => 200,
);
is($negated_label->{neg}, 1, 'label negation state is stored');
cmp_ok($negated_label->{id}, '>', $positive_label->{id}, 'negating a label refreshes its pagination id');
is($negated_label->{created_at}, 200, 'negating a label refreshes its label timestamp');
is(
  $store->list_labels(uri_patterns => ['at://did:web:pds.example.com:users:alice'])->{items}[0]{neg},
  1,
  'label listings preserve negation rows',
);

$store->close;

done_testing;
