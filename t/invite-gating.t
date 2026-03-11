use v5.34;
use warnings;

use Config ();
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use MIME::Base64 qw(encode_base64);
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
use ATProto::PDS::Store::SQLite;
use ATProto::PDS::Identity qw(service_did);

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $tmp  = tempdir(CLEANUP => 1);
my $db   = File::Spec->catfile($tmp, 'perlsky.sqlite');

my $app = ATProto::PDS->new(
  project_root => $root,
  settings     => {
    base_url              => 'http://127.0.0.1:7755',
    hostname              => 'pds.example.test',
    service_handle_domain => 'pds.example.test',
    service_did_method    => 'did:web',
    invite_code_required  => 1,
    jwt_secret            => 'invite-secret',
    admin_password        => 'admin-secret',
    data_dir              => File::Spec->catdir($tmp, 'data'),
    db_path               => $db,
  },
);

my $t = Test::Mojo->new($app);

$t->get_ok('/xrpc/com.atproto.server.describeServer')
  ->status_is(200)
  ->json_is('/inviteCodeRequired', JSON::PP::true);

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'alice',
  email    => 'alice@example.test',
  password => 'hunter22',
})->status_is(400)
  ->json_is('/error', 'InvalidInviteCode');

my $store = ATProto::PDS::Store::SQLite->new(path => $db)->bootstrap;
my $code = 'perlsky-invite1';
$store->create_invite_code(
  code        => $code,
  for_account => service_did($app->settings),
  created_by  => service_did($app->settings),
  use_count   => 1,
);

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle     => 'alice',
  email      => 'alice@example.test',
  password   => 'hunter22',
  inviteCode => $code,
})->status_is(200)
  ->json_is('/handle', 'alice.pds.example.test');

my $access = $t->tx->res->json->{accessJwt};

$t->post_ok('/xrpc/com.atproto.server.createInviteCode' => {
  Authorization => "Bearer $access",
} => json => {
  useCount => 1,
})->status_is(403)
  ->json_is('/error', 'InvalidAdminToken');

my $admin_auth = 'Basic ' . encode_base64('admin:admin-secret', q());

$t->post_ok('/xrpc/com.atproto.server.createInviteCode' => {
  Authorization => $admin_auth,
} => json => {
  useCount => 1,
})->status_is(200)
  ->json_has('/code');

done_testing;
