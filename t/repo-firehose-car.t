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
    jwt_secret            => 'repo-firehose-secret',
    admin_password        => 'admin-secret',
    data_dir              => File::Spec->catdir($tmp, 'data'),
    db_path               => File::Spec->catfile($tmp, 'perlsky.sqlite'),
  },
);

my $keys = $app->repo_manager->generate_signing_key;
my $account = $app->store->create_account(
  account_id           => 'acct-1',
  did                  => 'did:plc:repofirehosecartestacct',
  handle               => 'alice.example.test',
  private_key          => $keys->{private_key},
  public_key           => $keys->{public_key},
  public_key_multibase => $keys->{public_key_multibase},
  signing_key_did      => $keys->{signing_key_did},
);

my $init = $app->repo_manager->initialize_repo($account);
$account = $app->store->update_account(
  $account->{did},
  repo_commit_cid => $init->{cid},
  repo_root_cid   => $init->{root_cid},
  repo_rev        => $init->{rev},
);

my $first = $app->repo_manager->apply_writes($account, [{
  action     => 'create',
  collection => 'app.bsky.feed.post',
  rkey       => 'first',
  value      => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'first post',
    createdAt => '2026-03-11T00:00:00Z',
  },
}]);

my $first_cid = $first->{results}[0]{cid};
my $first_car = read_car($first->{car_bytes});
ok(
  scalar(grep { $_->{cid}->to_string eq $first_cid } @{ $first_car->{blocks} || [] }),
  'first firehose CAR includes the created record block',
);

my $second = $app->repo_manager->apply_writes($account, [{
  action     => 'create',
  collection => 'app.bsky.feed.post',
  rkey       => 'second',
  value      => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'second post',
    createdAt => '2026-03-11T00:00:01Z',
  },
}]);

my $second_cid = $second->{results}[0]{cid};
my $second_car = read_car($second->{car_bytes});
ok(
  scalar(grep { $_->{cid}->to_string eq $second_cid } @{ $second_car->{blocks} || [] }),
  'second firehose CAR includes the new record block',
);
ok(
  !scalar(grep { $_->{cid}->to_string eq $first_cid } @{ $second_car->{blocks} || [] }),
  'second firehose CAR does not resend the unchanged first record block',
);

my $snapshot_car = read_car($app->store->repo_car($account->{did}));
ok(
  scalar(grep { $_->{cid}->to_string eq $first_cid } @{ $snapshot_car->{blocks} || [] }),
  'repo snapshot CAR still includes the first record block',
);
ok(
  scalar(grep { $_->{cid}->to_string eq $second_cid } @{ $snapshot_car->{blocks} || [] }),
  'repo snapshot CAR still includes the second record block',
);

done_testing;
