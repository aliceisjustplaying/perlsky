package ATProto::PDS::IPLD::Base32;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';

our @EXPORT_OK = qw(encode_base32 decode_base32);

my $ALPHABET = 'abcdefghijklmnopqrstuvwxyz234567';
my %DECODE   = map { substr($ALPHABET, $_, 1) => $_ } 0 .. length($ALPHABET) - 1;

sub encode_base32 ($bytes) {
  return '' unless length $bytes;

  my $bits   = 0;
  my $buffer = 0;
  my $out    = '';

  for my $byte (unpack('C*', $bytes)) {
    $buffer = ($buffer << 8) | $byte;
    $bits  += 8;
    while ($bits >= 5) {
      $bits -= 5;
      $out  .= substr($ALPHABET, ($buffer >> $bits) & 0x1f, 1);
    }
  }

  if ($bits > 0) {
    $out .= substr($ALPHABET, ($buffer << (5 - $bits)) & 0x1f, 1);
  }

  return $out;
}

sub decode_base32 ($text) {
  return '' unless length $text;

  my $bits   = 0;
  my $buffer = 0;
  my @bytes;

  for my $char (split //, lc $text) {
    die "invalid base32 character: $char" unless exists $DECODE{$char};
    $buffer = ($buffer << 5) | $DECODE{$char};
    $bits  += 5;
    while ($bits >= 8) {
      $bits -= 8;
      push @bytes, ($buffer >> $bits) & 0xff;
    }
  }

  die 'invalid base32 tail bits' if $bits && (($buffer & ((1 << $bits) - 1)) != 0);

  return pack('C*', @bytes);
}

1;
