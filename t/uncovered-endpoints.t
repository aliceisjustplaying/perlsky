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
    jwt_secret                 => 'uncovered-endpoints-secret',
    admin_password             => 'admin-secret',
    self_service_invite_codes  => 1,
    testing_auto_confirm_email => 1,
    data_dir                   => $tmp,
    db_path                    => File::Spec->catfile($tmp, 'perlsky.sqlite'),
  },
);

my $t = Test::Mojo->new($app);
my $admin_auth = 'Basic ' . encode_base64('admin:admin-secret', q());

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'alice.example.test',
  email    => 'alice@example.test',
  password => 'hunter22',
})->status_is(200);

my $created = $t->tx->res->json;
my $did     = $created->{did};
my $access  = $created->{accessJwt};

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'describe-repo',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'describe repo',
    createdAt => '2026-03-12T00:00:00Z',
  },
})->status_is(200)
  ->json_is('/uri' => "at://$did/app.bsky.feed.post/describe-repo");

$t->get_ok("/xrpc/com.atproto.repo.describeRepo?repo=$did")
  ->status_is(200)
  ->json_is('/did' => $did)
  ->json_is('/handle' => 'alice.example.test')
  ->json_is('/handleIsCorrect' => JSON::PP::true);

ok(
  scalar(grep { $_ eq 'app.bsky.feed.post' } @{ $t->tx->res->json->{collections} || [] }),
  'describeRepo lists created collections',
);

my $account = $app->store->get_account_by_did($did);
my $broken_doc = {
  %{ $account->{did_doc} || {} },
  alsoKnownAs => ['at://wrong.example.test'],
};
$app->store->update_account($did, did_doc => $broken_doc);

$t->get_ok("/xrpc/com.atproto.repo.describeRepo?repo=$did")
  ->status_is(200)
  ->json_is('/handleIsCorrect' => JSON::PP::false)
  ->json_is('/didDoc/alsoKnownAs/0' => 'at://wrong.example.test');

$t->post_ok('/xrpc/com.atproto.sync.notifyOfUpdate' => json => {
  hostname => 'crawler.example.test',
})->status_is(200)
  ->content_is(q());

$t->get_ok('/xrpc/com.atproto.sync.getHostStatus' => form => {
  hostname => 'crawler.example.test',
})->status_is(200)
  ->json_is('/hostname' => 'crawler.example.test')
  ->json_is('/status' => 'active');

done_testing;
