package ATProto::PDS::Util::TID;

use v5.34;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(
  is_valid_tid
  next_tid
  repair_tid
);

my $S32_CHAR = '234567abcdefghijklmnopqrstuvwxyz';
my %S32_INDEX = map { substr($S32_CHAR, $_, 1) => $_ } 0 .. length($S32_CHAR) - 1;

my $last_timestamp = 0;
my $timestamp_count = 0;
my $clockid;

sub next_tid {
  my ($prev) = @_;
  my $normalized_prev = repair_tid($prev) // $prev;

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

  if (defined $normalized_prev && $tid le $normalized_prev) {
    return _from_time(_s32decode(substr($normalized_prev, 0, 11)) + 1, $clockid);
  }

  return $tid;
}

sub is_valid_tid {
  my ($tid) = @_;
  return 0 unless defined $tid && length($tid) == 13;
  return $tid =~ m{\A[234567abcdefghij][234567abcdefghijklmnopqrstuvwxyz]{12}\z} ? 1 : 0;
}

sub repair_tid {
  my ($tid) = @_;
  return undef unless defined $tid && length($tid) == 13;
  return $tid if is_valid_tid($tid);

  # Older perlsky builds incorrectly zero-padded the 2-char clock id, producing
  # otherwise-valid TIDs ending in `0x`. Repair that losslessly to `2x`.
  if ($tid =~ m{\A([234567abcdefghij][234567abcdefghijklmnopqrstuvwxyz]{10})0([234567abcdefghijklmnopqrstuvwxyz])\z}) {
    my $repaired = $1 . '2' . $2;
    return $repaired if is_valid_tid($repaired);
  }

  return undef;
}

sub _from_time {
  my ($timestamp, $clock) = @_;
  my $clock_s32 = _s32encode($clock);
  $clock_s32 = ('2' x (2 - length($clock_s32))) . $clock_s32 if length($clock_s32) < 2;
  return _s32encode($timestamp) . $clock_s32;
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
