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
  account_did_doc_valid_for_service
  did_to_path
  is_valid_handle
  normalize_handle
  resolve_handle_to_did
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

{
  no warnings 'redefine';
  local *ATProto::PDS::Identity::_resolve_handle_dns = sub {
    my ($handle) = @_;
    return 'did:plc:dns-preferred' if $handle eq 'alice.example.com';
    return undef;
  };
  local *ATProto::PDS::Identity::_resolve_handle_well_known = sub {
    my ($handle) = @_;
    return 'did:plc:well-known-fallback' if $handle eq 'alice.example.com';
    return undef;
  };

  is(
    resolve_handle_to_did({ base_url => 'https://pds.example.com' }, '@Alice.Example.com'),
    'did:plc:dns-preferred',
    'handle resolution normalizes input and prefers DNS over well-known',
  );
}

{
  no warnings 'redefine';
  local *ATProto::PDS::Identity::_resolve_handle_dns = sub { return undef; };
  local *ATProto::PDS::Identity::_resolve_handle_well_known = sub {
    my ($handle) = @_;
    return 'did:web:example.com:users:alice' if $handle eq 'alice.example.com';
    return undef;
  };

  is(
    resolve_handle_to_did({ base_url => 'https://pds.example.com' }, 'alice.example.com'),
    'did:web:example.com:users:alice',
    'handle resolution falls back to well-known when DNS has no answer',
  );
}

is(
  resolve_handle_to_did({ base_url => 'https://pds.example.com' }, 'not a handle'),
  undef,
  'handle resolution rejects invalid handles before any network lookup',
);

ok(
  account_did_doc_valid_for_service(
    { base_url => 'https://pds.example.com' },
    {
      did                 => 'did:web:pds.example.com:users:alice01',
      public_key_multibase => 'zExampleMultibaseKey',
      did_doc             => {
        id         => 'did:web:pds.example.com:users:alice01',
        service    => [{
          id              => '#atproto_pds',
          type            => 'AtprotoPersonalDataServer',
          serviceEndpoint => 'https://pds.example.com',
        }],
        verificationMethod => [{
          id                 => '#atproto',
          controller         => 'did:web:pds.example.com:users:alice01',
          publicKeyMultibase => 'zExampleMultibaseKey',
        }],
        assertionMethod => ['#atproto'],
      },
    },
  ),
  'service DID-doc validation accepts relative service and verification ids',
);

done_testing;
