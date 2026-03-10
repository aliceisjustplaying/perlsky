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

plan skip_all => 'set PERLDS_RUN_REFERENCE_DIFF=1 to run the official reference PDS differential harness'
  unless $ENV{PERLDS_RUN_REFERENCE_DIFF};

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $script = File::Spec->catfile($root, 'script', 'differential-validate');

my $output = qx{$^X $script 2>&1};
my $code   = $? >> 8;

diag($output) if $code;
is($code, 0, 'reference differential harness exits successfully');

done_testing;
