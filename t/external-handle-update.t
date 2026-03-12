use v5.34;
use warnings;

use Config ();
use File::Path qw(remove_tree);
use File::Spec;
use FindBin qw($Bin);
use Test::More;

BEGIN {
  require lib;
  my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
  lib->import(
    File::Spec->catdir($root, 'lib'),
    File::Spec->catdir($root, 'local', 'lib', 'perl5'),
    File::Spec->catdir($root, 'local', 'lib', 'perl5', $Config::Config{archname}),
  );
}

use Test::Mojo;
use ATProto::PDS;

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $tmp  = File::Spec->catdir($root, 'data', 'tmp-tests', 'external-handle-update');
remove_tree($tmp) if -d $tmp;

my $t = Test::Mojo->new(ATProto::PDS->new(
  project_root => $root,
  settings     => {
    base_url              => 'http://127.0.0.1:7755',
    service_did_method    => 'did:web',
    service_handle_domain => 'localhost',
    jwt_secret            => 'external-handle-secret',
    data_dir              => $tmp,
    db_path               => File::Spec->catfile($tmp, 'perlsky.sqlite'),
  },
));

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'alice',
  email    => 'alice@example.com',
  password => 'password123',
})->status_is(200)
  ->json_is('/handle' => 'alice.localhost');

my $session = $t->tx->res->json;
my $did     = $session->{did};
my $access  = $session->{accessJwt};

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'bob',
  email    => 'bob@example.com',
  password => 'password123',
})->status_is(200)
  ->json_is('/handle' => 'bob.localhost');

$t->post_ok('/xrpc/com.atproto.identity.updateHandle' => {
  Authorization => "Bearer $access",
} => json => {
  handle => 'bob.localhost',
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest')
  ->json_is('/message' => 'Handle already taken: bob.localhost');

{
  no warnings 'redefine';
  local *ATProto::PDS::Identity::_resolve_handle_dns = sub {
    my ($handle) = @_;
    return $did if $handle eq 'alice.external';
    return 'did:web:127.0.0.1%3A7755:users:someone-else' if $handle eq 'bob.external';
    return undef;
  };
  local *ATProto::PDS::Identity::_resolve_handle_well_known = sub {
    my ($handle) = @_;
    return undef;
  };

  $t->post_ok('/xrpc/com.atproto.identity.updateHandle' => {
    Authorization => "Bearer $access",
  } => json => {
    handle => 'alice.external',
  })->status_is(200)
    ->json_is({});

  $t->get_ok('/xrpc/com.atproto.identity.resolveHandle?handle=alice.external')
    ->status_is(200)
    ->json_is('/did' => $did);

  $t->post_ok('/xrpc/com.atproto.server.createSession' => json => {
    identifier => 'alice.external',
    password   => 'password123',
  })->status_is(200)
    ->json_is('/did' => $did)
    ->json_is('/handle' => 'alice.external');

  $t->post_ok('/xrpc/com.atproto.identity.updateHandle' => {
    Authorization => "Bearer $access",
  } => json => {
    handle => 'bob.external',
  })->status_is(400)
    ->json_is('/error' => 'InvalidRequest')
    ->json_is('/message' => 'External handle did not resolve to DID');

  $t->post_ok('/xrpc/com.atproto.identity.updateHandle' => {
    Authorization => "Bearer $access",
  } => json => {
    handle => 'missing.external',
  })->status_is(400)
    ->json_is('/error' => 'InvalidRequest')
    ->json_is('/message' => 'External handle did not resolve to DID');
}

done_testing;
