package ATProto::PDS::IPLD::Base58;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use Math::BigInt try => 'GMP';

our @EXPORT_OK = qw(encode_base58btc decode_base58btc);

my $ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
my %DECODE   = map { substr($ALPHABET, $_, 1) => $_ } 0 .. length($ALPHABET) - 1;

sub encode_base58btc ($bytes) {
  return '' unless length $bytes;

  my $num = Math::BigInt->from_hex('0x' . unpack('H*', $bytes));
  my $out = '';

  while ($num > 0) {
    my ($q, $r) = $num->copy->bdiv(58);
    $out = substr($ALPHABET, $r->numify, 1) . $out;
    $num = $q;
  }

  my $leading = 0;
  $leading++ while $leading < length($bytes) && substr($bytes, $leading, 1) eq "\x00";
  return ('1' x $leading) . ($out || '');
}

sub decode_base58btc ($text) {
  return '' unless length $text;

  my $num = Math::BigInt->new(0);
  for my $char (split //, $text) {
    die "invalid base58btc character: $char" unless exists $DECODE{$char};
    $num->bmul(58);
    $num->badd($DECODE{$char});
  }

  my $hex = $num->as_hex;
  $hex =~ s/^0x//;
  $hex = "0$hex" if length($hex) % 2;
  my $bytes = $hex eq '00' && $num == 0 ? '' : pack('H*', $hex);

  my $leading = 0;
  $leading++ while $leading < length($text) && substr($text, $leading, 1) eq '1';
  return ("\x00" x $leading) . $bytes;
}

1;
