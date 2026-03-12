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

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $tmp  = tempdir(CLEANUP => 1);

my $app = ATProto::PDS->new(
  project_root => $root,
  settings     => {
    base_url                   => 'http://127.0.0.1:7755',
    service_handle_domain      => 'example.test',
    service_did_method         => 'did:web',
    jwt_secret                 => 'crawler-status-secret',
    admin_password             => 'admin-secret',
    testing_auto_confirm_email => 1,
    data_dir                   => $tmp,
    db_path                    => File::Spec->catfile($tmp, 'perlsky.sqlite'),
  },
);

my $t = Test::Mojo->new($app);
my $admin_auth = 'Basic ' . encode_base64('admin:admin-secret', q());

$t->post_ok('/xrpc/com.atproto.sync.notifyOfUpdate' => json => {
  hostname => 'crawler.example.test',
})->status_is(200)
  ->content_is(q());

$t->get_ok('/xrpc/com.atproto.sync.getHostStatus' => form => {
  hostname => 'crawler.example.test',
})->status_is(200)
  ->json_is('/hostname' => 'crawler.example.test')
  ->json_is('/status' => 'active');

$t->get_ok('/xrpc/com.atproto.sync.getHostStatus' => {
  Authorization => $admin_auth,
} => form => {
  hostname => 'crawler.example.test',
})->status_is(200)
  ->json_is('/hostname' => 'crawler.example.test')
  ->json_is('/status' => 'active');

done_testing;
