package ATProto::PDS::IPLD::CID;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use Scalar::Util qw(blessed);

use ATProto::PDS::IPLD::Base32 qw(encode_base32 decode_base32);
use ATProto::PDS::IPLD::Base58 qw(encode_base58btc decode_base58btc);
use ATProto::PDS::IPLD::Multihash qw(sha256_multihash decode_multihash);
use ATProto::PDS::IPLD::Varint qw(encode_uvarint decode_uvarint);

our @EXPORT_OK = qw(CODEC_DAG_CBOR CODEC_RAW cid_from_bytes cid_from_data);

use constant CODEC_DAG_CBOR => 0x71;
use constant CODEC_RAW      => 0x55;

sub new ($class, %args) {
  die 'CIDv1 only' unless ($args{version} // 1) == 1;
  die 'missing multihash bytes' unless defined $args{multihash};

  return bless {
    version   => 1,
    codec     => $args{codec},
    multihash => $args{multihash},
  }, $class;
}

sub parse ($class, $text) {
  my $bytes;
  if ($text =~ /\Ab([a-z2-7]+)\z/i) {
    $bytes = decode_base32($1);
  } elsif ($text =~ /\Az([1-9A-HJ-NP-Za-km-z]+)\z/) {
    $bytes = decode_base58btc($1);
  } else {
    die "unsupported CID multibase: $text";
  }

  return $class->from_bytes($bytes);
}

sub from_bytes ($class, $bytes) {
  my ($version, $after_version) = decode_uvarint($bytes, 0);
  die 'CIDv1 only' unless $version == 1;
  my ($codec, $after_codec) = decode_uvarint($bytes, $after_version);
  my ($multihash, $end)     = decode_multihash($bytes, $after_codec);
  die 'trailing bytes after CID' unless $end == length $bytes;

  return $class->new(
    codec     => $codec,
    multihash => $multihash->{bytes},
  );
}

sub from_data ($class, $codec, $bytes) {
  return $class->new(
    codec     => $codec,
    multihash => sha256_multihash($bytes),
  );
}

sub cid_from_bytes ($codec, $bytes) {
  return __PACKAGE__->from_data($codec, $bytes);
}

sub cid_from_data ($codec, $bytes) {
  return __PACKAGE__->from_data($codec, $bytes);
}

sub version ($self) {
  return $self->{version};
}

sub codec ($self) {
  return $self->{codec};
}

sub multihash ($self) {
  return $self->{multihash};
}

sub digest ($self) {
  my ($parts) = decode_multihash($self->{multihash}, 0);
  return $parts->{digest};
}

sub hash_code ($self) {
  my ($parts) = decode_multihash($self->{multihash}, 0);
  return $parts->{code};
}

sub to_bytes ($self) {
  return encode_uvarint($self->{version}) . encode_uvarint($self->{codec}) . $self->{multihash};
}

sub to_string ($self, $base = 'base32') {
  my $bytes = $self->to_bytes;
  return 'b' . encode_base32($bytes) if $base eq 'base32';
  return 'z' . encode_base58btc($bytes) if $base eq 'base58btc';
  die "unsupported CID base: $base";
}

sub link_bytes ($self) {
  return "\x00" . $self->to_bytes;
}

sub equals ($self, $other) {
  return blessed($other) && $other->isa(__PACKAGE__) && $self->to_bytes eq $other->to_bytes;
}

use overload
  '""' => sub ($self, @) { $self->to_string },
  'eq' => sub ($left, $right, $swap) {
    my ($a, $b) = $swap ? ($right, $left) : ($left, $right);
    return blessed($b) && $b->isa(__PACKAGE__) ? $a->equals($b) : "$a" eq "$b";
  },
  fallback => 1;

1;
