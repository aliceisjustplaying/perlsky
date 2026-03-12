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

use Mojo::URL;
use Test::Mojo;
use ATProto::PDS;

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $tmp  = tempdir(CLEANUP => 1);

my $app = ATProto::PDS->new(
  project_root => $root,
  settings     => {
    base_url              => 'http://127.0.0.1:7755',
    service_handle_domain => 'example.test',
    service_did_method    => 'did:web',
    jwt_secret            => 'local-service-surfaces-secret',
    admin_password        => 'admin-secret',
    data_dir              => $tmp,
    db_path               => File::Spec->catfile($tmp, 'perlsky.sqlite'),
  },
);

my $t = Test::Mojo->new($app);
my $admin_auth = 'Basic ' . encode_base64('admin:admin-secret', q());

$t->post_ok('/xrpc/com.atproto.temp.addReservedHandle' => {
  Authorization => $admin_auth,
} => json => {
  handle => 'reserved.example.test',
})->status_is(200);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.temp.checkHandleAvailability')->query(
  handle => 'reserved.example.test',
))->status_is(200)
  ->json_is('/available', JSON::PP::false);

$t->post_ok('/xrpc/com.atproto.sync.requestCrawl' => json => {
  hostname => 'relay.example.test',
})->status_is(200)
  ->content_is(q());

$t->get_ok('/xrpc/com.atproto.sync.listHosts')
  ->status_is(200)
  ->json_is('/hosts/0/hostname', 'relay.example.test');

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.getHostStatus')->query(
  hostname => 'relay.example.test',
))->status_is(200)
  ->json_is('/hostname', 'relay.example.test');

done_testing;
