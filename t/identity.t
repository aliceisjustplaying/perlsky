use v5.34;
use warnings;

use Config ();
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

use ATProto::PDS::Identity qw(
  account_did
  did_to_path
  is_valid_handle
  normalize_handle
  service_did
  service_host
);

is(service_host('http://127.0.0.1:7755'), '127.0.0.1:7755', 'non-default ports are preserved');
is(service_did('http://127.0.0.1:7755'), 'did:web:127.0.0.1%3A7755', 'service did encodes the port');
is(account_did('https://pds.example.com', 'alice01'), 'did:web:pds.example.com:users:alice01', 'account did nests under service did');
is(did_to_path('did:web:pds.example.com:users:alice01'), '/users/alice01/did.json', 'account did maps back to a did.json path');

ok(is_valid_handle('alice.example.com'), 'handles validate');
ok(!is_valid_handle('alice', 'example.com'), 'bare handles do not validate');
ok(is_valid_handle('alice.example.com', 'example.com'), 'allowed domains are enforced');
is(normalize_handle('@Alice', 'example.com'), 'alice.example.com', 'handles are normalized');

done_testing;
