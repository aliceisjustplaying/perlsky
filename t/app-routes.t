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

use Test::Mojo;
use ATProto::PDS;
use ATProto::PDS::Config qw(load_config);

my $root   = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $config = load_config(File::Spec->catfile($root, 'etc', 'perlds.example.json'));
my $t      = Test::Mojo->new(
  ATProto::PDS->new(
    project_root => $root,
    settings     => $config,
  ),
);

$t->get_ok('/_health')
  ->status_is(200)
  ->json_is('/service' => 'perlds')
  ->json_has('/ok');

$t->get_ok('/xrpc/com.atproto.server.describeServer')
  ->status_is(200)
  ->json_is('/availableUserDomains/0' => 'localhost')
  ->json_like('/did' => qr/\Adid:web:/);

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => json => {})
  ->status_is(501)
  ->json_is('/error' => 'NotImplemented')
  ->json_is('/nsid'  => 'com.atproto.repo.createRecord');

$t->websocket_ok('/xrpc/com.atproto.sync.subscribeRepos')
  ->finish_ok;

done_testing;
