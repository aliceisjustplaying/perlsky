use v5.34;
use warnings;

use Config ();
use FindBin qw($Bin);
use File::Spec;
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

use ATProto::PDS::LexiconCatalog qw(endpoint_catalog);

my $root    = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $catalog = endpoint_catalog($root);

ok(@$catalog >= 70, 'loaded the upstream endpoint inventory');

my %by_id = map { $_->{id} => $_ } @$catalog;

ok($by_id{'com.atproto.server.createAccount'}, 'createAccount exists');
ok($by_id{'com.atproto.repo.applyWrites'}, 'applyWrites exists');
ok($by_id{'com.atproto.sync.subscribeRepos'}, 'subscribeRepos exists');
is($by_id{'com.atproto.sync.subscribeRepos'}{type}, 'subscription', 'subscription type preserved');

done_testing;
