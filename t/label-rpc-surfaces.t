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
    jwt_secret            => 'label-surface-secret',
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

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'label-target',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'label target',
    createdAt => '2026-03-12T00:00:00Z',
  },
})->status_is(200);

my $record = $t->tx->res->json;
my $record_uri = $record->{uri};
my $record_cid = $record->{cid};

$t->post_ok('/xrpc/com.atproto.admin.updateSubjectStatus' => {
  Authorization => $admin_auth,
} => json => {
  subject  => { did => $did },
  takedown => { applied => JSON::PP::true, ref => 'unit-test' },
})->status_is(200);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.label.queryLabels')->query(
  uriPatterns => "at://$did*",
))->status_is(200);
ok(
  _find_label($t->tx->res->json->{labels}, val => '!hide'),
  'queryLabels includes the account takedown label',
);

$t->get_ok('/xrpc/com.atproto.temp.fetchLabels?limit=10')
  ->status_is(200);
ok(
  _find_label($t->tx->res->json->{labels}, val => '!hide'),
  'fetchLabels includes the account takedown label',
);

$t->post_ok('/xrpc/com.atproto.admin.updateSubjectStatus' => {
  Authorization => $admin_auth,
} => json => {
  subject  => { did => $did },
  takedown => { applied => JSON::PP::false, ref => 'unit-test' },
})->status_is(200);

$t->get_ok(Mojo::URL->new('/xrpc/com.atproto.label.queryLabels')->query(
  uriPatterns => "at://$did*",
))->status_is(200);
ok(
  _find_label($t->tx->res->json->{labels}, val => '!hide', neg => JSON::PP::true),
  'queryLabels includes the negated account takedown label',
);

$t->get_ok('/xrpc/com.atproto.temp.fetchLabels?limit=10')
  ->status_is(200);
ok(
  _find_label($t->tx->res->json->{labels}, val => '!hide', neg => JSON::PP::true),
  'fetchLabels includes the negated account takedown label',
);

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
