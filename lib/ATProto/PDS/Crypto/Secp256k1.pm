package ATProto::PDS::Crypto::Secp256k1;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use Crypt::PK::ECC;
use Math::BigInt try => 'GMP';

use ATProto::PDS::Util::BaseX qw(encode_base58btc decode_base58btc);

our @EXPORT_OK = qw(
  did_key_from_public_key
  generate_keypair
  public_key_from_did_key
  public_key_multibase_from_public_key
  signing_did_from_private_key
  signing_did_to_public_key_multibase
  sign_compact_low_s
);

my $SECP256K1_DID_PREFIX = pack('C*', 0xe7, 0x01);
my $SECP256K1_ORDER = Math::BigInt->from_hex('0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141');
my $SECP256K1_HALF_ORDER = $SECP256K1_ORDER->copy->bdiv(2);

sub generate_keypair () {
  my $pk = Crypt::PK::ECC->new;
  $pk->generate_key('secp256k1');

  my $private_key = $pk->export_key_raw('private');
  my $public_key = $pk->export_key_raw('public');
  my $compressed = $pk->export_key_raw('public_compressed');

  return {
    private_key          => $private_key,
    public_key           => $public_key,
    public_key_compressed => $compressed,
    public_key_multibase => public_key_multibase_from_public_key($public_key),
    signing_key_did      => did_key_from_public_key($compressed),
  };
}

sub signing_did_from_private_key ($private_key) {
  my $pk = Crypt::PK::ECC->new;
  $pk->import_key_raw($private_key, 'secp256k1');
  return did_key_from_public_key($pk->export_key_raw('public_compressed'));
}

sub did_key_from_public_key ($public_key) {
  my $compressed = _compress_public_key($public_key);
  return 'did:key:z' . encode_base58btc($SECP256K1_DID_PREFIX . $compressed);
}

sub public_key_multibase_from_public_key ($public_key) {
  my $uncompressed = _uncompress_public_key($public_key);
  return 'z' . encode_base58btc($uncompressed);
}

sub public_key_from_did_key ($did_key) {
  my $copy = $did_key // q();
  $copy =~ s/\Adid:key://;
  $copy =~ s/\Az// or die "unsupported did:key encoding: $did_key";
  my $decoded = decode_base58btc($copy);
  die "unsupported did:key prefix: $did_key" unless substr($decoded, 0, 2) eq $SECP256K1_DID_PREFIX;
  my $compressed = substr($decoded, 2);
  return _uncompress_public_key($compressed);
}

sub signing_did_to_public_key_multibase ($did_key) {
  return public_key_multibase_from_public_key(public_key_from_did_key($did_key));
}

sub sign_compact_low_s ($private_key, $message) {
  my $pk = Crypt::PK::ECC->new;
  $pk->import_key_raw($private_key, 'secp256k1');
  my $sig = $pk->sign_message_rfc7518($message, 'SHA256');
  return _normalize_low_s($sig);
}

sub _compress_public_key ($public_key) {
  return $public_key if length($public_key // q()) == 33;
  my $pk = Crypt::PK::ECC->new;
  $pk->import_key_raw($public_key, 'secp256k1');
  return $pk->export_key_raw('public_compressed');
}

sub _uncompress_public_key ($public_key) {
  return $public_key if length($public_key // q()) == 65;
  my $pk = Crypt::PK::ECC->new;
  $pk->import_key_raw($public_key, 'secp256k1');
  return $pk->export_key_raw('public');
}

sub _normalize_low_s ($signature) {
  die 'expected a compact 64-byte secp256k1 signature'
    unless defined $signature && length($signature) == 64;

  my $r = Math::BigInt->from_hex('0x' . unpack('H*', substr($signature, 0, 32)));
  my $s = Math::BigInt->from_hex('0x' . unpack('H*', substr($signature, 32, 32)));
  if ($s->bcmp($SECP256K1_HALF_ORDER) > 0) {
    $s = $SECP256K1_ORDER->copy->bsub($s);
  }

  return _bigint_to_32_bytes($r) . _bigint_to_32_bytes($s);
}

sub _bigint_to_32_bytes ($value) {
  my $hex = $value->copy->as_hex;
  $hex =~ s/\A0x//;
  $hex = ('0' x (64 - length($hex))) . $hex;
  return pack('H*', $hex);
}

1;
