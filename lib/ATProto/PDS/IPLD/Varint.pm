package ATProto::PDS::IPLD::Varint;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';

our @EXPORT_OK = qw(encode_uvarint decode_uvarint);

sub encode_uvarint ($value) {
  die 'varint must be non-negative' if !defined($value) || $value < 0;

  my $out = '';
  while (1) {
    my $byte = $value & 0x7f;
    $value >>= 7;
    if ($value) {
      $out .= pack('C', $byte | 0x80);
    } else {
      $out .= pack('C', $byte);
      last;
    }
  }

  return $out;
}

sub decode_uvarint ($bytes, $offset = 0) {
  my $shift = 0;
  my $value = 0;
  my $pos   = $offset;

  while ($pos < length $bytes) {
    my $byte = unpack('C', substr($bytes, $pos, 1));
    $value |= ($byte & 0x7f) << $shift;
    $pos++;
    return ($value, $pos) if ($byte & 0x80) == 0;
    $shift += 7;
    die 'varint overflow' if $shift > 63;
  }

  die 'unterminated varint';
}

1;
