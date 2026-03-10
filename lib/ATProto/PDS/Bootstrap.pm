package ATProto::PDS::Bootstrap;

use v5.34;
use warnings;

use Exporter 'import';
use Config ();
use FindBin ();
use File::Spec;
use lib ();

our @EXPORT_OK = qw(apply_local_lib project_root);

sub project_root {
  state $root = do {
    my $bin = $FindBin::RealBin || '.';
    File::Spec->rel2abs(File::Spec->catdir($bin, '..'));
  };
}

sub apply_local_lib {
  my $root = project_root();
  my @paths = (
    File::Spec->catdir($root, 'lib'),
    File::Spec->catdir($root, 'local', 'lib', 'perl5'),
    File::Spec->catdir($root, 'local', 'lib', 'perl5', $Config::Config{archname}),
  );

  lib->import(@paths);
  return \@paths;
}

1;
