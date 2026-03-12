use v5.34;
use warnings;

use Config ();
use File::Spec;
use File::Temp qw(tempdir);
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
my $tmp  = tempdir(CLEANUP => 1);

my $app = ATProto::PDS->new(
  project_root => $root,
  settings => {
    base_url                   => 'http://127.0.0.1:7755',
    service_handle_domain      => 'example.test',
    service_did_method         => 'did:web',
    jwt_secret                 => 'self-service-invite-secret',
    admin_password             => 'admin-secret',
    self_service_invite_codes  => 1,
    testing_auto_confirm_email => 1,
    data_dir                   => $tmp,
    db_path                    => File::Spec->catfile($tmp, 'perlsky.sqlite'),
  },
);

my $t = Test::Mojo->new($app);

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'alice.example.test',
  email    => 'alice@example.test',
  password => 'hunter22',
})->status_is(200);

my $created = $t->tx->res->json;
my $access  = $created->{accessJwt};

$t->post_ok('/xrpc/com.atproto.server.createInviteCode' => {
  Authorization => "Bearer $access",
} => json => {
  useCount => 2,
})->status_is(200)
  ->json_has('/code');

my $invite_code = $t->tx->res->json->{code};

$t->post_ok('/xrpc/com.atproto.server.createInviteCode' => {
  Authorization => "Bearer $access",
} => json => {
  forAccount => 'did:web:example.test:users:someone-else',
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest');

$t->get_ok('/xrpc/com.atproto.server.getAccountInviteCodes' => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/codes/0/code', $invite_code);

done_testing;
