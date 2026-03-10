package ATProto::PDS::Repo::CID;

use v5.34;
use warnings;

use Digest::SHA qw(sha256);
use Exporter 'import';
use Scalar::Util qw(blessed);

use ATProto::PDS::Util::BaseX qw(
  decode_base32
  decode_varint
  encode_base32
  encode_varint
);

our @EXPORT_OK = qw(
  CID_CODEC_DAG_CBOR
  CID_CODEC_RAW
);

use constant CID_CODEC_DAG_CBOR => 0x71;
use constant CID_CODEC_RAW      => 0x55;
use constant MULTIHASH_SHA256   => 0x12;

sub new {
  my ($class, %args) = @_;
  return bless {
    version   => $args{version} // 1,
    codec     => $args{codec},
    hash_code => $args{hash_code} // MULTIHASH_SHA256,
    digest    => $args{digest},
  }, $class;
}

sub from_digest {
  my ($class, $codec, $digest) = @_;
  return $class->new(codec => $codec, digest => $digest);
}

sub for_dag_cbor {
  my ($class, $bytes) = @_;
  return $class->from_digest(CID_CODEC_DAG_CBOR, sha256($bytes));
}

sub for_raw {
  my ($class, $bytes) = @_;
  return $class->from_digest(CID_CODEC_RAW, sha256($bytes));
}

sub from_string {
  my ($class, $text) = @_;
  die 'unsupported cid multibase' unless $text =~ /\Ab/i;
  return $class->from_bytes(decode_base32(substr(lc($text), 1)));
}

sub from_bytes {
  my ($class, $bytes) = @_;
  my ($cid, $consumed) = $class->from_bytes_with_length($bytes);
  die 'trailing bytes after cid' if $consumed != length($bytes);
  return $cid;
}

sub from_bytes_with_length {
  my ($class, $bytes) = @_;
  my ($version, $consumed_v) = decode_varint($bytes, 0);
  my ($codec,   $consumed_c) = decode_varint($bytes, $consumed_v);
  my ($hash,    $consumed_h) = decode_varint($bytes, $consumed_v + $consumed_c);
  my ($length,  $consumed_l) = decode_varint($bytes, $consumed_v + $consumed_c + $consumed_h);
  my $start = $consumed_v + $consumed_c + $consumed_h + $consumed_l;
  my $digest = substr($bytes, $start, $length);

  die 'truncated cid digest' if length($digest) != $length;

  return (
    $class->new(
      version   => $version,
      codec     => $codec,
      hash_code => $hash,
      digest    => $digest,
    ),
    $start + $length,
  );
}

sub bytes {
  my ($self) = @_;
  return
    encode_varint($self->{version})
    . encode_varint($self->{codec})
    . encode_varint($self->{hash_code})
    . encode_varint(length($self->{digest}))
    . $self->{digest};
}

sub to_string {
  my ($self) = @_;
  return 'b' . encode_base32($self->bytes);
}

sub equals {
  my ($self, $other) = @_;
  return 0 unless blessed($other) && $other->isa(__PACKAGE__);
  return $self->bytes eq $other->bytes;
}

sub codec     { return $_[0]->{codec} }
sub version   { return $_[0]->{version} }
sub digest    { return $_[0]->{digest} }
sub hash_code { return $_[0]->{hash_code} }

1;
