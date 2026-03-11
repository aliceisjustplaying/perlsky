package ATProto::PDS::Repo::DagCbor;

use v5.34;
use warnings;

use CBOR::XS ();
use Exporter 'import';
use Encode qw(encode_utf8 decode_utf8);
use Scalar::Util qw(blessed looks_like_number);

use ATProto::PDS::Repo::Bytes;
use ATProto::PDS::Repo::CID;

our @EXPORT_OK = qw(encode_dag_cbor decode_dag_cbor);

sub encode_dag_cbor {
  my ($value) = @_;
  return _encode_value($value);
}

sub decode_dag_cbor {
  my ($bytes) = @_;
  die 'DAG-CBOR bytes required' unless defined $bytes;
  my $octets = $bytes;
  if (utf8::is_utf8($octets)) {
    utf8::downgrade($octets, 1) or utf8::encode($octets);
  }
  {
    no warnings 'uninitialized';
    return _dag_cbor_decoder()->decode($octets);
  }
}

sub _dag_cbor_decoder {
  state $decoder = CBOR::XS->new->filter(sub {
    my ($tag, $value) = @_;
    if ($tag == 42 && !ref($value)) {
      return _decode_cid_tag_payload($value);
    }
    return;
  });
  return $decoder;
}

sub _decode_cid_tag_payload {
  my ($value) = @_;
  die 'invalid CID tag payload'
    unless defined($value) && length($value) && substr($value, 0, 1) eq "\x00";
  return ATProto::PDS::Repo::CID->from_bytes(substr($value, 1));
}

sub _encode_value {
  my ($value) = @_;

  return _encode_head(7, 22) unless defined $value;

  if (blessed($value) && $value->isa('JSON::PP::Boolean')) {
    return _encode_head(7, $$value ? 21 : 20);
  }

  if (blessed($value) && $value->isa('ATProto::PDS::Repo::CID')) {
    return _encode_head(6, 42) . _encode_bytes("\x00" . $value->bytes);
  }

  if (blessed($value) && $value->isa('ATProto::PDS::Repo::Bytes')) {
    return _encode_bytes($value->bytes);
  }

  if (ref($value) eq 'ARRAY') {
    return _encode_array($value);
  }

  if (ref($value) eq 'HASH') {
    return _encode_map($value);
  }

  if (!ref($value) && looks_like_number($value)) {
    if (int($value) == $value) {
      return _encode_integer($value);
    }
    return pack('C', 0xfb) . pack('d>', 0 + $value);
  }

  if (!ref($value)) {
    return _encode_text($value);
  }

  die 'unsupported DAG-CBOR value';
}

sub _encode_array {
  my ($array) = @_;
  return _encode_head(4, scalar @$array) . join('', map { _encode_value($_) } @$array);
}

sub _encode_map {
  my ($hash) = @_;
  my @keys = sort {
    my $ab = encode_utf8($a);
    my $bb = encode_utf8($b);
    length($ab) <=> length($bb) || $ab cmp $bb
  } keys %$hash;

  my $out = _encode_head(5, scalar @keys);
  for my $key (@keys) {
    $out .= _encode_text($key);
    $out .= _encode_value($hash->{$key});
  }
  return $out;
}

sub _encode_integer {
  my ($value) = @_;
  return $value >= 0
    ? _encode_head(0, $value)
    : _encode_head(1, (-1 - $value));
}

sub _encode_text {
  my ($text) = @_;
  my $bytes = encode_utf8($text);
  return _encode_head(3, length($bytes)) . $bytes;
}

sub _encode_bytes {
  my ($bytes) = @_;
  return _encode_head(2, length($bytes)) . $bytes;
}

sub _encode_head {
  my ($major, $value) = @_;
  if ($value < 24) {
    return pack('C', ($major << 5) | $value);
  }
  if ($value < 256) {
    return pack('CC', ($major << 5) | 24, $value);
  }
  if ($value < 65_536) {
    return pack('Cn', ($major << 5) | 25, $value);
  }
  if ($value < 4_294_967_296) {
    return pack('CN', ($major << 5) | 26, $value);
  }
  return pack('CQ>', ($major << 5) | 27, $value);
}

1;
