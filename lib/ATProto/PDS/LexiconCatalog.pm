package ATProto::PDS::LexiconCatalog;

use v5.34;
use warnings;

use Exporter 'import';
use File::Spec;
use JSON::PP qw(decode_json);

our @EXPORT_OK = qw(load_catalog endpoint_catalog);

sub load_catalog {
  my ($root) = @_;
  my $base = File::Spec->catdir($root, 'share', 'lexicons', 'com', 'atproto');
  my @namespaces = qw(server identity repo sync admin moderation label lexicon temp);
  my @catalog;

  for my $namespace (@namespaces) {
    my $dir = File::Spec->catdir($base, $namespace);
    next unless -d $dir;

    opendir(my $dh, $dir) or die "opendir($dir): $!";
    for my $entry (sort grep { /\.json\z/ } readdir($dh)) {
      my $path = File::Spec->catfile($dir, $entry);
      open(my $fh, '<', $path) or die "open($path): $!";
      local $/;
      my $json = decode_json(<$fh>);
      close($fh);

      my $main = $json->{defs}{main};
      next unless ref($main) eq 'HASH';
      next unless ($main->{type} // '') =~ /\A(?:query|procedure|subscription)\z/;

      push @catalog, {
        id        => $json->{id},
        namespace => $namespace,
        type      => $main->{type},
        path      => "/xrpc/$json->{id}",
        lexicon   => $path,
      };
    }
    closedir($dh);
  }

  return \@catalog;
}

sub endpoint_catalog {
  my ($root) = @_;
  state %cache;
  return $cache{$root} ||= load_catalog($root);
}

1;
