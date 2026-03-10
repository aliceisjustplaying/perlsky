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

plan skip_all => 'set PERLSKY_RUN_REFERENCE_DIFF=1 to run the official PLC differential harness'
  unless $ENV{PERLSKY_RUN_REFERENCE_DIFF};

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $script = File::Spec->catfile($root, 'script', 'differential-validate');

local $ENV{PERLSKY_DIFF_ACCOUNT_DID_METHOD} = 'did:plc';
my $output = qx{$^X $script 2>&1};
my $code   = $? >> 8;

diag($output) if $code;
is($code, 0, 'reference PLC differential harness exits successfully');

done_testing;
