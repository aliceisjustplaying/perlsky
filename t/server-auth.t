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
my $tmp  = File::Spec->catdir($root, 'data', 'tmp-tests', 'server-auth');
remove_tree($tmp) if -d $tmp;

my $config = {
  base_url              => 'http://127.0.0.1:7755',
  service_did_method    => 'did:web',
  service_handle_domain => 'localhost',
  jwt_secret            => 'test-secret',
  data_dir              => $tmp,
  db_path               => File::Spec->catfile($tmp, 'perlsky.sqlite'),
};

my $t = Test::Mojo->new(ATProto::PDS->new(
  project_root => $root,
  settings     => $config,
));

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'alice',
  email    => 'alice@example.com',
  password => 'password123',
})->status_is(200)
  ->json_is('/handle' => 'alice.localhost')
  ->json_like('/did' => qr/\Adid:web:/)
  ->json_has('/accessJwt')
  ->json_has('/refreshJwt');

my $created = $t->tx->res->json;
my $access  = $created->{accessJwt};
my $refresh = $created->{refreshJwt};
my $did     = $created->{did};
my ($account_id) = $did =~ /:users:([^:]+)\z/;

$t->get_ok('/xrpc/com.atproto.server.getSession' => { Authorization => "Bearer $access" })
  ->status_is(200)
  ->json_is('/handle' => 'alice.localhost')
  ->json_is('/email' => 'alice@example.com');

$t->get_ok("/xrpc/com.atproto.identity.resolveHandle?handle=alice.localhost")
  ->status_is(200)
  ->json_is('/did' => $did);

$t->get_ok("/users/$account_id/did.json")
  ->status_is(200)
  ->json_is('/id' => $did)
  ->json_is('/alsoKnownAs/0' => 'at://alice.localhost');

$t->post_ok('/xrpc/com.atproto.server.createAppPassword' => { Authorization => "Bearer $access" } => json => {
  name => 'phone',
})->status_is(200)
  ->json_is('/name' => 'phone')
  ->json_has('/password');

my $app_password = $t->tx->res->json->{password};

$t->get_ok('/xrpc/com.atproto.server.listAppPasswords' => { Authorization => "Bearer $access" })
  ->status_is(200)
  ->json_is('/passwords/0/name' => 'phone');

$t->post_ok('/xrpc/com.atproto.server.revokeAppPassword' => { Authorization => "Bearer $access" } => json => {
  name => 'phone',
})->status_is(200);

$t->get_ok('/xrpc/com.atproto.server.listAppPasswords' => { Authorization => "Bearer $access" })
  ->status_is(200)
  ->json_is('/passwords' => []);

$t->post_ok('/xrpc/com.atproto.server.refreshSession' => { Authorization => "Bearer $refresh" } => json => {})
  ->status_is(200)
  ->json_has('/accessJwt')
  ->json_has('/refreshJwt');

my $refreshed = $t->tx->res->json;

$t->post_ok('/xrpc/com.atproto.server.deleteSession' => { Authorization => "Bearer $refreshed->{refreshJwt}" } => json => {})
  ->status_is(200);

$t->post_ok('/xrpc/com.atproto.server.createSession' => json => {
  identifier => 'alice.localhost',
  password   => 'password123',
})->status_is(200)
  ->json_is('/did' => $did);

done_testing;
