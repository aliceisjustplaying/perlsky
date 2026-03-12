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
use JSON::PP ();
use Mojo::URL;
use ATProto::PDS;
use ATProto::PDS::Repo::CAR qw(read_car);

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $tmp  = tempdir(CLEANUP => 1);

my $app = ATProto::PDS->new(
  project_root => $root,
  settings => {
    base_url              => 'http://127.0.0.1:7755',
    service_handle_domain => 'example.test',
    service_did_method    => 'did:web',
    jwt_secret            => 'surface-secret',
    admin_password        => 'admin-secret',
    data_dir              => File::Spec->catdir($tmp, 'data'),
    db_path               => File::Spec->catfile($tmp, 'perlsky.sqlite'),
  },
);

my $t = Test::Mojo->new($app);
my $admin_auth = 'Basic YWRtaW46YWRtaW4tc2VjcmV0';

for my $endpoint (@{ $app->endpoint_catalog }) {
  ok($app->api_registry->handler_for($endpoint->{id}), "$endpoint->{id} has a handler");
}

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.lexicon.resolveLexicon')->query(
  nsid => 'com.atproto.server.createSession',
))->status_is(200)
  ->json_is('/schema/id' => 'com.atproto.server.createSession')
  ->json_has('/cid')
  ->json_has('/uri');

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.temp.checkHandleAvailability')->query(
  handle => 'alice.example.test',
))->status_is(200)
  ->json_is('/handle' => 'alice.example.test')
  ->json_has('/result');

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'alice.example.test',
  email    => 'alice@example.test',
  password => 'hunter22',
})->status_is(200);

my $session = $t->tx->res->json;
my $did     = $session->{did};
my $access  = $session->{accessJwt};

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.temp.checkHandleAvailability')->query(
  handle => 'alice.example.test',
))->status_is(200)
  ->json_has('/result/suggestions/0/handle');

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => { Authorization => "Bearer $access" } => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'hello-world',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'hello surface',
    createdAt => '2026-03-10T00:00:00Z',
  },
})->status_is(200);

my $record = $t->tx->res->json;
my $record_uri = $record->{uri};
my $record_cid = $record->{cid};

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.listReposByCollection')->query(
  collection => 'app.bsky.feed.post',
))->status_is(200)
  ->json_is('/repos/0/did' => $did);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.getLatestCommit')->query(
  did => $did,
))->status_is(200);

my $latest = $t->tx->res->json;

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.getBlocks')->query(
  did  => $did,
  cids => $latest->{cid},
))->status_is(200)
  ->content_type_like(qr{application/vnd\.ipld\.car})
  ->content_like(qr/.+/s);
my $blocks_car = read_car($t->tx->res->body);
is_deeply($blocks_car->{roots}, [], 'sync.getBlocks returns a rootless CAR');
ok(
  scalar(grep { $_->{cid}->to_string eq $latest->{cid} } @{ $blocks_car->{blocks} || [] }),
  'sync.getBlocks returns the requested repo-scoped block',
);

$t->post_ok('/xrpc/com.atproto.repo.uploadBlob' => {
  Authorization => "Bearer $access",
  'Content-Type' => 'text/plain',
} => 'blob-bytes')->status_is(200);

my $blob = $t->tx->res->json->{blob};
my $blob_cid = $blob->{ref}{'$link'};

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.getBlob')->query(
  did => $did,
  cid => $blob_cid,
))->status_is(200)
  ->header_is('Cross-Origin-Resource-Policy' => 'cross-origin')
  ->header_is('X-Content-Type-Options' => 'nosniff')
  ->header_like('Content-Disposition' => qr/\Aattachment; filename="/)
  ->header_is('Content-Security-Policy' => "default-src 'none'; sandbox")
  ->content_type_is('text/plain')
  ->content_is('blob-bytes');

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'com.example.record',
  rkey       => 'missing-blob-ref',
  record     => {
    '$type' => 'com.example.record',
    note    => 'blob reference for missing-blob listing',
    image   => $blob,
  },
})->status_is(200);

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'bob.example.test',
  email    => 'bob@example.test',
  password => 'hunter22',
})->status_is(200);

my $second = $t->tx->res->json;
my $second_did = $second->{did};
my $second_access = $second->{accessJwt};

$t->post_ok('/xrpc/com.atproto.repo.uploadBlob' => {
  Authorization => "Bearer $second_access",
  'Content-Type' => 'text/plain',
} => 'blob-bytes')->status_is(200)
  ->json_is('/blob/ref/$link' => $blob_cid);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.listBlobs')->query(
  did => $did,
))->status_is(200)
  ->json_is('/cids/0' => $blob_cid);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.listBlobs')->query(
  did => $second_did,
))->status_is(200)
  ->json_is('/cids' => []);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.getBlocks')->query(
  did  => $second_did,
  cids => $latest->{cid},
))->status_is(400)
  ->json_is('/error' => 'InvalidRequest')
  ->json_like('/message' => qr/\Q$latest->{cid}\E/);

$t->post_ok('/xrpc/com.atproto.repo.uploadBlob' => {
  Authorization => "Bearer $access",
  'Content-Type' => 'text/plain',
} => 'blob-two')->status_is(200);

my $blob_two_cid = $t->tx->res->json->{blob}{ref}{'$link'};
my @sorted_blob_cids = sort ($blob_cid);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.listBlobs')->query(
  did   => $did,
  limit => 1,
))->status_is(200)
  ->json_is('/cids/0' => $sorted_blob_cids[0])
  ->json_is('/cursor' => $sorted_blob_cids[0]);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.listBlobs')->query(
  did    => $did,
  limit  => 1,
  cursor => $sorted_blob_cids[0],
))->status_is(200)
  ->json_is('/cids' => []);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.getBlob')->query(
  did => $second_did,
  cid => $blob_cid,
))->status_is(200)
  ->header_is('Cross-Origin-Resource-Policy' => 'cross-origin')
  ->header_is('X-Content-Type-Options' => 'nosniff')
  ->header_like('Content-Disposition' => qr/\Aattachment; filename="/)
  ->header_is('Content-Security-Policy' => "default-src 'none'; sandbox")
  ->content_type_is('text/plain')
  ->content_is('blob-bytes');

$t->post_ok('/xrpc/com.atproto.repo.uploadBlob' => {
  Authorization => "Bearer $access",
  'Content-Type' => 'text/plain',
} => 'nested-blob-bytes')->status_is(200);

my $nested_blob = $t->tx->res->json->{blob};
my $nested_blob_cid = $nested_blob->{ref}{'$link'};

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'com.example.record',
  rkey       => 'nested-missing-blob-ref',
  record     => {
    '$type'      => 'com.example.record',
    note         => 'nested blob reference for missing-blob listing',
    attachments  => [{
      kind  => 'image',
      image => $nested_blob,
    }],
  },
})->status_is(200);

my $nested_record_uri = $t->tx->res->json->{uri};
my @since_sorted_blob_cids = sort ($blob_cid, $nested_blob_cid);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.sync.listBlobs')->query(
  did   => $did,
  since => $latest->{rev},
))->status_is(200)
  ->json_is('/cids/0' => $since_sorted_blob_cids[0])
  ->json_is('/cids/1' => $since_sorted_blob_cids[1]);

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
  ->json_is('/expectedBlobs' => 1)
  ->json_is('/importedBlobs' => 1);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.admin.getAccountInfo')->query(
  did => $did,
) => {
  Authorization => $admin_auth,
})->status_is(200)
  ->json_is('/handle' => 'alice.example.test');

$t->post_ok('/xrpc/com.atproto.admin.updateSubjectStatus' => {
  Authorization => $admin_auth,
} => json => {
  subject  => { uri => $record_uri, cid => $record_cid },
  takedown => { applied => JSON::PP::true },
})->status_is(200);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.label.queryLabels')->query(
  uriPatterns => $record_uri,
))->status_is(200);
ok(
  _find_label($t->tx->res->json->{labels}, val => '!hide', uri => $record_uri),
  'queryLabels includes the record takedown label',
);

for my $cid ($blob_cid, $nested_blob_cid) {
  $app->store->dbh->do(
    q{DELETE FROM blob_owners WHERE cid = ?},
    undef,
    $cid,
  );
  $app->store->dbh->do(
    q{DELETE FROM blobs WHERE cid = ?},
    undef,
    $cid,
  );
}

my %expected_missing = (
  $blob_cid        => "at://$did/com.example.record/missing-blob-ref",
  $nested_blob_cid => $nested_record_uri,
);
my @missing_cids = sort keys %expected_missing;

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.repo.listMissingBlobs')->query(
  limit => 1,
), {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/blobs/0/cid' => $missing_cids[0])
  ->json_is('/blobs/0/recordUri' => $expected_missing{$missing_cids[0]})
  ->json_is('/cursor' => $missing_cids[0]);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.repo.listMissingBlobs')->query(
  limit  => 1,
  cursor => $missing_cids[0],
), {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/blobs/0/cid' => $missing_cids[1])
  ->json_is('/blobs/0/recordUri' => $expected_missing{$missing_cids[1]})
  ->json_is('/cursor' => $missing_cids[1]);

done_testing;

sub _find_label {
  my ($labels, %expected) = @_;
  return 0 unless ref($labels) eq 'ARRAY';
  for my $label (@$labels) {
    next unless ref($label) eq 'HASH';
    my $matches = 1;
    for my $key (keys %expected) {
      next if defined($label->{$key}) && "$label->{$key}" eq "$expected{$key}";
      $matches = 0;
      last;
    }
    return 1 if $matches;
  }
  return 0;
}
