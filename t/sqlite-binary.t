use v5.34;
use warnings;

use Config ();
use File::Spec;
use File::Temp qw(tempfile);
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

use ATProto::PDS::Repo::CAR qw(read_car write_car);
use ATProto::PDS::Repo::CID;
use ATProto::PDS::Repo::DagCbor qw(encode_dag_cbor);
use ATProto::PDS::Store::SQLite;

sub _upgrade_copy {
  my ($bytes) = @_;
  my $copy = $bytes;
  utf8::upgrade($copy);
  return $copy;
}

sub _mangle_copy {
  my ($bytes) = @_;
  my $copy = _upgrade_copy($bytes);
  utf8::encode($copy);
  return $copy;
}

my ($fh, $path) = tempfile();
close $fh;

my $store = ATProto::PDS::Store::SQLite->new(path => $path)->bootstrap;

my $record = {
  '$type'     => 'app.bsky.feed.post',
  text        => 'sqlite binary roundtrip',
  createdAt   => '2026-03-11T02:00:00Z',
};
my $record_bytes = encode_dag_cbor($record);
my $record_cid   = ATProto::PDS::Repo::CID->for_dag_cbor($record_bytes);
my $car_bytes    = write_car($record_cid, [
  { cid => $record_cid, bytes => $record_bytes },
]);

my $salt        = pack('C*', map { 0x80 + $_ } 0 .. 15);
my $private_key = pack('C*', map { 0x80 + $_ } 0 .. 31);
my $public_key  = pack('C*', map { 0x80 + $_ } 0 .. 64);
my $label_sig   = pack('C*', map { 0x80 + $_ } 0 .. 63);

my $account = $store->create_account(
  did                  => 'did:plc:sqlitebinary',
  handle               => 'sqlitebinary.test',
  password_salt        => _upgrade_copy($salt),
  private_key          => _upgrade_copy($private_key),
  public_key           => _upgrade_copy($public_key),
  public_key_multibase => 'ztest',
  signing_key_did      => 'did:key:ztest',
);

ok(!utf8::is_utf8($account->{password_salt}), 'account salt is returned as raw bytes');
ok(!utf8::is_utf8($account->{private_key}), 'account private key is returned as raw bytes');
ok(!utf8::is_utf8($account->{public_key}), 'account public key is returned as raw bytes');
is($account->{password_salt}, $salt, 'account salt roundtrips');
is($account->{private_key}, $private_key, 'account private key roundtrips');
is($account->{public_key}, $public_key, 'account public key roundtrips');

$store->put_block(
  cid   => $record_cid->to_string,
  codec => $record_cid->codec,
  bytes => _upgrade_copy($record_bytes),
);
my $block = $store->get_block($record_cid->to_string);
ok(!utf8::is_utf8($block->{bytes}), 'block bytes are returned as raw bytes');
is($block->{bytes}, $record_bytes, 'block bytes roundtrip');

$store->put_record(
  did         => $account->{did},
  collection  => 'app.bsky.feed.post',
  rkey        => 'abc',
  cid         => $record_cid->to_string,
  value       => $record,
  record_bytes => _upgrade_copy($record_bytes),
);
my $stored_record = $store->get_record($account->{did}, 'app.bsky.feed.post', 'abc');
ok(!utf8::is_utf8($stored_record->{record_bytes}), 'record bytes are returned as raw bytes');
is($stored_record->{record_bytes}, $record_bytes, 'record bytes roundtrip');

$store->put_commit(
  did          => $account->{did},
  rev          => 'rev1',
  cid          => $record_cid->to_string,
  root_cid     => $record_cid->to_string,
  commit_bytes => _upgrade_copy($record_bytes),
  car_bytes    => _upgrade_copy($car_bytes),
);
my $commit = $store->get_latest_commit($account->{did});
ok(!utf8::is_utf8($commit->{commit_bytes}), 'commit bytes are returned as raw bytes');
ok(!utf8::is_utf8($commit->{car_bytes}), 'commit CAR is returned as raw bytes');
is($commit->{commit_bytes}, $record_bytes, 'commit bytes roundtrip');
is($commit->{car_bytes}, $car_bytes, 'commit CAR roundtrip');

$store->append_event(
  did        => $account->{did},
  type       => 'commit',
  rev        => 'rev1',
  commit_cid => $record_cid->to_string,
  payload    => { ops => [] },
  car_bytes  => _upgrade_copy($car_bytes),
);
my $event = $store->list_events_after(0)->[0];
ok(!utf8::is_utf8($event->{car_bytes}), 'event CAR is returned as raw bytes');
is($event->{car_bytes}, $car_bytes, 'event CAR roundtrip');
is(read_car($event->{car_bytes})->{roots}[0]->to_string, $record_cid->to_string, 'roundtripped event CAR remains parseable');

my ($repair_fh, $repair_path) = tempfile();
close $repair_fh;
my $repair_store = ATProto::PDS::Store::SQLite->new(path => $repair_path)->bootstrap;
my $repair_account = $repair_store->create_account(
  did                  => 'did:plc:repairbinary',
  handle               => 'repairbinary.test',
  password_salt        => $salt,
  private_key          => $private_key,
  public_key           => $public_key,
  public_key_multibase => 'zrepair',
  signing_key_did      => 'did:key:zrepair',
);

my $dbh = $repair_store->dbh;
my $mangled_salt        = _mangle_copy($salt);
my $mangled_private_key = _mangle_copy($private_key);
my $mangled_public_key  = _mangle_copy($public_key);
my $mangled_record      = _mangle_copy($record_bytes);
my $mangled_car         = _mangle_copy($car_bytes);

$dbh->do(
  q{UPDATE accounts SET password_salt = ?, private_key = ?, public_key = ? WHERE did = ?},
  undef,
  $mangled_salt,
  $mangled_private_key,
  $mangled_public_key,
  $repair_account->{did},
);
$dbh->do(
  q{INSERT INTO blocks (cid, codec, bytes, created_at) VALUES (?, ?, ?, ?)},
  undef,
  $record_cid->to_string,
  $record_cid->codec,
  $mangled_record,
  time,
);
$dbh->do(
  q{INSERT INTO records (did, collection, rkey, cid, value_json, record_bytes, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)},
  undef,
  $repair_account->{did},
  'app.bsky.feed.post',
  'repair',
  $record_cid->to_string,
  '{"text":"repair"}',
  $mangled_record,
  time,
  time,
);
$dbh->do(
  q{INSERT INTO commits (did, rev, cid, root_cid, prev_cid, commit_bytes, car_bytes, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)},
  undef,
  $repair_account->{did},
  'rev2',
  $record_cid->to_string,
  $record_cid->to_string,
  undef,
  $mangled_record,
  $mangled_car,
  time,
);
$dbh->do(
  q{INSERT INTO events (did, type, rev, commit_cid, payload_json, car_bytes, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)},
  undef,
  $repair_account->{did},
  'commit',
  'rev2',
  $record_cid->to_string,
  '{"ops":[]}',
  $mangled_car,
  time,
);
$dbh->do(
  q{INSERT INTO labels (subject_key, src, uri, cid, val, exp, sig, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)},
  undef,
  'at://did:plc:repairbinary/app.bsky.feed.post/repair',
  'did:plc:repairbinary',
  'at://did:plc:repairbinary/app.bsky.feed.post/repair',
  $record_cid->to_string,
  '!hide',
  undef,
  _mangle_copy($label_sig),
  time,
  time,
);

my $counts = $repair_store->repair_binary_columns;
cmp_ok($counts->{accounts}, '>=', 1, 'repair updated account blobs');
cmp_ok($counts->{blocks}, '>=', 1, 'repair updated block blobs');
cmp_ok($counts->{records}, '>=', 1, 'repair updated record blobs');
cmp_ok($counts->{commits}, '>=', 1, 'repair updated commit blobs');
cmp_ok($counts->{events}, '>=', 1, 'repair updated event blobs');
cmp_ok($counts->{labels}, '>=', 1, 'repair updated label signatures');

my $repaired_account = $repair_store->get_account_by_did($repair_account->{did});
is($repaired_account->{password_salt}, $salt, 'repair restored account salt');
is($repaired_account->{private_key}, $private_key, 'repair restored account private key');
is($repaired_account->{public_key}, $public_key, 'repair restored account public key');
is($repair_store->get_block($record_cid->to_string)->{bytes}, $record_bytes, 'repair restored block bytes');
is($repair_store->get_record($repair_account->{did}, 'app.bsky.feed.post', 'repair')->{record_bytes}, $record_bytes, 'repair restored record bytes');
is($repair_store->get_latest_commit($repair_account->{did})->{car_bytes}, $car_bytes, 'repair restored commit CAR');
is($repair_store->list_events_after(0)->[0]{car_bytes}, $car_bytes, 'repair restored event CAR');
is($repair_store->get_label(subject_key => 'at://did:plc:repairbinary/app.bsky.feed.post/repair', src => 'did:plc:repairbinary', val => '!hide')->{sig}, $label_sig, 'repair restored label signature bytes');

done_testing;
