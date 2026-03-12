use v5.34;
use warnings;

use Config ();
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use JSON::PP ();
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
use Mojo::URL;
use ATProto::PDS;

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $tmp  = tempdir(CLEANUP => 1);

my $app = ATProto::PDS->new(
  project_root => $root,
  settings => {
    base_url              => 'http://127.0.0.1:7755',
    service_handle_domain => 'example.test',
    service_did_method    => 'did:web',
    jwt_secret            => 'account-status-secret',
    admin_password        => 'admin-secret',
    data_dir              => File::Spec->catdir($tmp, 'data'),
    db_path               => File::Spec->catfile($tmp, 'perlsky.sqlite'),
  },
);

my $t = Test::Mojo->new($app);
my $admin_auth = 'Basic YWRtaW46YWRtaW4tc2VjcmV0';

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'alice.example.test',
  email    => 'alice@example.test',
  password => 'hunter22',
})->status_is(200);

my $session = $t->tx->res->json;
my $did     = $session->{did};
my $access  = $session->{accessJwt};

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'bob.example.test',
  email    => 'bob@example.test',
  password => 'hunter22',
})->status_is(200);

my $second = $t->tx->res->json;
my $second_access = $second->{accessJwt};

$t->get_ok('/xrpc/com.atproto.server.checkAccountStatus' => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_has('/activated')
  ->json_is('/validDid' => JSON::PP::true)
  ->json_has('/repoCommit')
  ->json_has('/repoRev')
  ->json_has('/repoBlocks')
  ->json_has('/indexedRecords')
  ->json_has('/expectedBlobs')
  ->json_has('/importedBlobs');

my $account = $app->store->get_account_by_did($did);
my $original_did_doc = $account->{did_doc};

my %bad_endpoint_doc = %{$original_did_doc};
$bad_endpoint_doc{service} = [
  map {
    my %copy = %{$_};
    $copy{serviceEndpoint} = 'https://elsewhere.example'
      if ($copy{id} // q()) eq "$did#atproto_pds";
    \%copy;
  } @{ $original_did_doc->{service} || [] }
];
$app->store->update_account($did, did_doc => \%bad_endpoint_doc);

$t->get_ok('/xrpc/com.atproto.server.checkAccountStatus' => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/validDid' => JSON::PP::false);

my %bad_key_doc = %{$original_did_doc};
$bad_key_doc{verificationMethod} = [
  map {
    my %copy = %{$_};
    $copy{publicKeyMultibase} = 'zQmInvalidSigningKey'
      if ($copy{id} // q()) eq "$did#atproto";
    \%copy;
  } @{ $original_did_doc->{verificationMethod} || [] }
];
$app->store->update_account($did, did_doc => \%bad_key_doc);

$t->get_ok('/xrpc/com.atproto.server.checkAccountStatus' => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/validDid' => JSON::PP::false);

$app->store->update_account($did, did_doc => $original_did_doc);

$t->get_ok('/xrpc/com.atproto.server.checkAccountStatus' => {
  Authorization => "Bearer $second_access",
})->status_is(200)
  ->json_is('/expectedBlobs' => 0)
  ->json_is('/importedBlobs' => 0);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.admin.getAccountInfo')->query(
  did => $did,
) => {
  Authorization => $admin_auth,
})->status_is(200)
  ->json_is('/handle' => 'alice.example.test');

done_testing;
