package ATProto::PDS::Util::TID;

use v5.34;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(next_tid);

my $S32_CHAR = '234567abcdefghijklmnopqrstuvwxyz';
my %S32_INDEX = map { substr($S32_CHAR, $_, 1) => $_ } 0 .. length($S32_CHAR) - 1;

my $last_timestamp = 0;
my $timestamp_count = 0;
my $clockid;

sub next_tid {
  my ($prev) = @_;

  my $time = int(Time::HiRes::time() * 1000);
  $time = $last_timestamp if $time < $last_timestamp;

  if ($time == $last_timestamp) {
    $timestamp_count++;
  } else {
    $timestamp_count = 0;
  }
  $last_timestamp = $time;

  $clockid //= int(rand(32));
  my $tid = _from_time($time * 1000 + $timestamp_count, $clockid);

  if (defined $prev && $tid le $prev) {
    return _from_time(_s32decode(substr($prev, 0, 11)) + 1, $clockid);
  }

  return $tid;
}

sub _from_time {
  my ($timestamp, $clock) = @_;
  return _s32encode($timestamp) . sprintf('%02s', _s32encode($clock)) =~ s/ /2/gr;
}

sub _s32encode {
  my ($value) = @_;
  return '2' if $value == 0;

  my $out = '';
  while ($value) {
    my $char = $value % 32;
    $value = int($value / 32);
    $out = substr($S32_CHAR, $char, 1) . $out;
  }
  return $out;
}

sub _s32decode {
  my ($text) = @_;
  my $value = 0;
  for my $char (split //, $text) {
    $value = ($value * 32) + $S32_INDEX{$char};
  }
  return $value;
}

BEGIN {
  require Time::HiRes;
}

1;
