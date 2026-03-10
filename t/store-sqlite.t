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

my $db_path = File::Spec->catfile($tmp, 'perlds.sqlite');
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

$store->create_app_password(
  id            => 'app-1',
  did           => $account->{did},
  name          => 'phone',
  password_hash => 'sha256:def',
);
is($store->list_app_passwords_by_did($account->{did})->[0]{name}, 'phone', 'app password is stored');

$store->put_blob(
  cid          => 'bafkreigh2akiscaildc',
  did          => $account->{did},
  mime_type    => 'image/png',
  byte_size    => 1234,
  storage_path => 'blobs/bafk.png',
);
is($store->get_blob('bafkreigh2akiscaildc')->{byte_size}, 1234, 'blob metadata is stored');

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
