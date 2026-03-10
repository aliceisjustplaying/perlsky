#!/usr/bin/env perl
use v5.34;
use warnings;

use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;

my $source_root = '.vendor/atproto/lexicons/com/atproto';
my $dest_root   = 'share/lexicons/com/atproto';
my @namespaces  = qw(server identity repo sync admin moderation lexicon temp label);

for my $namespace (@namespaces) {
  my $source_dir = File::Spec->catdir($source_root, $namespace);
  next unless -d $source_dir;

  my $dest_dir = File::Spec->catdir($dest_root, $namespace);
  make_path($dest_dir);

  opendir(my $dh, $source_dir) or die "opendir($source_dir): $!";
  while (my $entry = readdir($dh)) {
    next if $entry =~ /^\./;
    next unless $entry =~ /\.json\z/;

    my $from = File::Spec->catfile($source_dir, $entry);
    my $to   = File::Spec->catfile($dest_dir,   $entry);
    copy($from, $to) or die "copy($from, $to): $!";
    say $to;
  }
  closedir($dh);
}
