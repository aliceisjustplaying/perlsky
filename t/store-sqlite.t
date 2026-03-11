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
  email         => 'alice@example.com',
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
is($store->get_account_by_email('alice@example.com')->{did}, $account->{did}, 'lookup by email works');

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

$store->revoke_session('sess-1', revoked_at => 123);
is($store->get_session('sess-1')->{revoked_at}, 123, 'sessions can be revoked');

$store->revoke_app_password('app-1', revoked_at => 456);
is($store->get_app_password('app-1')->{revoked_at}, 456, 'app passwords can be revoked');

$store->close;

done_testing;
