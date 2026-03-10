package ATProto::PDS::Config;

use v5.34;
use warnings;

use Exporter 'import';
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use JSON::PP qw(decode_json);

our @EXPORT_OK = qw(load_config);

sub load_config {
  my ($path) = @_;
  open(my $fh, '<', $path) or die "open($path): $!";
  local $/;
  my $config = decode_json(<$fh>);
  close($fh);

  my $root = dirname(File::Spec->rel2abs($path));
  for my $key (qw(data_dir db_path)) {
    next unless defined $config->{$key};
    next if File::Spec->file_name_is_absolute($config->{$key});
    $config->{$key} = File::Spec->rel2abs($config->{$key}, $root);
  }

  make_path($config->{data_dir}) if $config->{data_dir};

  return $config;
}

1;
