use v5.34;
use warnings;

use Config ();
use FindBin qw($Bin);
use File::Spec;
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

plan skip_all => 'set PERLSKY_RUN_BROWSER_SMOKE=1 to run the browser smoke harness'
  unless $ENV{PERLSKY_RUN_BROWSER_SMOKE};

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $pair_file = $ENV{PERLSKY_BROWSER_PAIR_FILE}
  || File::Spec->catfile($root, '.cache', 'browser-smoke', 'reusable-pair.json');

my $has_explicit_pair = ($ENV{PERLSKY_BROWSER_HANDLE} && $ENV{PERLSKY_BROWSER_PASSWORD})
  || (-f $pair_file);

plan skip_all => "browser smoke pair not available; bootstrap one or set PERLSKY_BROWSER_* credentials"
  unless $has_explicit_pair;

my $script = File::Spec->catfile($root, 'script', 'perlsky-browser-smoke');
my $artifacts = File::Spec->catdir($root, 'data', 'browser-smoke', 'test-suite');
my $code = system(
  $^X,
  $script,
  'run-dual',
  '--artifacts-dir',
  $artifacts,
  '--strict-errors',
) >> 8;

is($code, 0, 'browser smoke harness exits successfully');

done_testing;
