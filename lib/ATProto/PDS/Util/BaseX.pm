package ATProto::PDS::Util::BaseX;

use v5.34;
use warnings;

use Exporter 'import';
use Math::BigInt try => 'GMP';
use MIME::Base64 qw(encode_base64 decode_base64);

our @EXPORT_OK = qw(
  encode_base32
  decode_base32
  encode_base58btc
  decode_base58btc
  base64url_encode
  base64url_decode
  encode_varint
  decode_varint
);

my $BASE32_ALPHABET = 'abcdefghijklmnopqrstuvwxyz234567';
my %BASE32_INDEX    = map { substr($BASE32_ALPHABET, $_, 1) => $_ } 0 .. length($BASE32_ALPHABET) - 1;

my $BASE58_ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
my %BASE58_INDEX    = map { substr($BASE58_ALPHABET, $_, 1) => $_ } 0 .. length($BASE58_ALPHABET) - 1;

sub encode_base32 {
  my ($bytes) = @_;
  return '' unless defined $bytes && length $bytes;

  my $bits = unpack('B*', $bytes);
  my $pad  = (5 - (length($bits) % 5)) % 5;
  $bits .= '0' x $pad;

  my $out = '';
  for (my $i = 0; $i < length($bits); $i += 5) {
    my $chunk = substr($bits, $i, 5);
    $out .= substr($BASE32_ALPHABET, oct("0b$chunk"), 1);
  }

  return $out;
}

sub decode_base32 {
  my ($text) = @_;
  return '' unless defined $text && length $text;

  $text = lc $text;
  my $bits = '';
  for my $char (split //, $text) {
    die "invalid base32 character: $char" unless exists $BASE32_INDEX{$char};
    $bits .= sprintf('%05b', $BASE32_INDEX{$char});
  }

  my $remainder = length($bits) % 8;
  substr($bits, -$remainder, $remainder, '') if $remainder;
  return pack('B*', $bits);
}

sub encode_base58btc {
  my ($bytes) = @_;
  return '' unless defined $bytes;
  return q() unless length $bytes;

  my $zeroes = _leading_zero_bytes($bytes);
  my $value  = Math::BigInt->from_hex('0x' . unpack('H*', $bytes));
  my $out    = q();

  while ($value->bcmp(0) > 0) {
    my ($quotient, $remainder) = $value->copy->bdiv(58);
    $out = substr($BASE58_ALPHABET, $remainder->numify, 1) . $out;
    $value = $quotient;
  }

  return ('1' x $zeroes) . $out;
}

sub decode_base58btc {
  my ($text) = @_;
  return '' unless defined $text && length $text;

  my ($leading) = $text =~ /\A(1*)/;
  my $value = Math::BigInt->new(0);
  for my $char (split //, $text) {
    die "invalid base58 character: $char" unless exists $BASE58_INDEX{$char};
    $value->bmul(58)->badd($BASE58_INDEX{$char});
  }

  my $hex = $value->as_hex;
  $hex =~ s/\A0x//;
  $hex = '0' . $hex if length($hex) % 2;
  my $bytes = $value->is_zero ? q() : pack('H*', $hex);
  return ("\0" x length($leading)) . $bytes;
}

sub base64url_encode {
  my ($bytes) = @_;
  my $encoded = encode_base64($bytes, '');
  $encoded =~ tr{+/}{-_};
  $encoded =~ s/=+\z//;
  return $encoded;
}

sub base64url_decode {
  my ($text) = @_;
  my $copy = $text;
  $copy =~ tr{-_}{+/};
  my $pad = (4 - (length($copy) % 4)) % 4;
  $copy .= '=' x $pad;
  return decode_base64($copy);
}

sub encode_varint {
  my ($value) = @_;
  my $out = '';
  do {
    my $byte = $value & 0x7f;
    $value >>= 7;
    $byte |= 0x80 if $value;
    $out .= pack('C', $byte);
  } while ($value);
  return $out;
}

sub decode_varint {
  my ($bytes, $offset) = @_;
  $offset //= 0;

  my $result = 0;
  my $shift  = 0;
  my $index  = $offset;

  while ($index < length($bytes)) {
    my $byte = ord(substr($bytes, $index, 1));
    $result |= (($byte & 0x7f) << $shift);
    $index++;
    return ($result, $index - $offset) if ($byte & 0x80) == 0;
    $shift += 7;
  }

  die 'truncated varint';
}

sub _leading_zero_bytes {
  my ($bytes) = @_;
  my $count = 0;
  for my $byte (unpack('C*', $bytes)) {
    last if $byte != 0;
    $count++;
  }
  return $count;
}

1;
