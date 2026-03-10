package ATProto::PDS::IPLD::DAGCBOR;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use Encode qw(encode decode FB_CROAK);
use JSON::PP ();
use Scalar::Util qw(blessed looks_like_number);

use ATProto::PDS::IPLD::Bytes;
use ATProto::PDS::IPLD::CID qw(CODEC_DAG_CBOR cid_from_bytes);

our @EXPORT_OK = qw(encode_dag_cbor decode_dag_cbor cid_for_dag_cbor);

sub encode_dag_cbor ($value) {
  return _encode_item($value);
}

sub decode_dag_cbor ($bytes) {
  my ($value, $offset) = _decode_item($bytes, 0);
  die 'trailing data after DAG-CBOR item' unless $offset == length $bytes;
  return $value;
}

sub cid_for_dag_cbor ($value) {
  my $bytes = encode_dag_cbor($value);
  return cid_from_bytes(CODEC_DAG_CBOR, $bytes);
}

sub _encode_item ($value) {
  if (!defined $value) {
    return "\xf6";
  }

  if (blessed($value) && $value->isa('ATProto::PDS::IPLD::CID')) {
    return _encode_tag(42) . _encode_bytes($value->link_bytes);
  }

  if (blessed($value) && $value->isa('ATProto::PDS::IPLD::Bytes')) {
    return _encode_bytes($value->bytes);
  }

  if (blessed($value) && ref($value) eq 'JSON::PP::Boolean') {
    return $$value ? "\xf5" : "\xf4";
  }

  if (ref($value) eq 'ARRAY') {
    my $out = _encode_type_and_length(4, scalar @$value);
    $out .= _encode_item($_) for @$value;
    return $out;
  }

  if (ref($value) eq 'HASH') {
    my @pairs;
    for my $key (keys %$value) {
      die 'DAG-CBOR map keys must be strings' if ref $key;
      my $encoded_key = _encode_text($key);
      push @pairs, [$encoded_key, $key];
    }

    @pairs = sort {
      length($a->[0]) <=> length($b->[0]) || $a->[0] cmp $b->[0]
    } @pairs;

    my $out = _encode_type_and_length(5, scalar @pairs);
    for my $pair (@pairs) {
      $out .= $pair->[0];
      $out .= _encode_item($value->{ $pair->[1] });
    }
    return $out;
  }

  if (!ref($value) && _is_integer($value)) {
    return $value >= 0 ? _encode_type_and_length(0, $value) : _encode_type_and_length(1, -1 - $value);
  }

  if (!ref($value)) {
    return _encode_text($value);
  }

  die 'unsupported DAG-CBOR value';
}

sub _decode_item ($bytes, $offset) {
  die 'unexpected end of DAG-CBOR input' if $offset >= length $bytes;

  my $lead = unpack('C', substr($bytes, $offset, 1));
  my $major = $lead >> 5;
  my $info  = $lead & 0x1f;
  $offset++;

  die 'indefinite-length CBOR is not supported' if $info == 31;

  if ($major == 0) {
    my ($value, $next) = _decode_length($bytes, $offset, $info);
    return ($value, $next);
  }
  if ($major == 1) {
    my ($value, $next) = _decode_length($bytes, $offset, $info);
    return (-1 - $value, $next);
  }
  if ($major == 2) {
    my ($length, $next) = _decode_length($bytes, $offset, $info);
    my $data = substr($bytes, $next, $length);
    die 'truncated byte string' unless length($data) == $length;
    return (ATProto::PDS::IPLD::Bytes->new($data), $next + $length);
  }
  if ($major == 3) {
    my ($length, $next) = _decode_length($bytes, $offset, $info);
    my $data = substr($bytes, $next, $length);
    die 'truncated text string' unless length($data) == $length;
    return (decode('UTF-8', $data, FB_CROAK), $next + $length);
  }
  if ($major == 4) {
    my ($length, $next) = _decode_length($bytes, $offset, $info);
    my @items;
    my $pos = $next;
    for (1 .. $length) {
      my ($item, $after) = _decode_item($bytes, $pos);
      push @items, $item;
      $pos = $after;
    }
    return (\@items, $pos);
  }
  if ($major == 5) {
    my ($length, $next) = _decode_length($bytes, $offset, $info);
    my %hash;
    my $pos = $next;
    for (1 .. $length) {
      my ($key, $after_key) = _decode_item($bytes, $pos);
      die 'DAG-CBOR map keys must decode as text strings' if ref $key;
      die "duplicate DAG-CBOR map key: $key" if exists $hash{$key};
      my ($value, $after_value) = _decode_item($bytes, $after_key);
      $hash{$key} = $value;
      $pos = $after_value;
    }
    return (\%hash, $pos);
  }
  if ($major == 6) {
    my ($tag, $next) = _decode_length($bytes, $offset, $info);
    die "unsupported CBOR tag: $tag" unless $tag == 42;
    my ($value, $after) = _decode_item($bytes, $next);
    die 'CID tag 42 must wrap a byte string' unless blessed($value) && $value->isa('ATProto::PDS::IPLD::Bytes');
    my $bytes_value = $value->bytes;
    die 'invalid CID tag payload' unless length($bytes_value) && substr($bytes_value, 0, 1) eq "\x00";
    return (ATProto::PDS::IPLD::CID->from_bytes(substr($bytes_value, 1)), $after);
  }
  if ($major == 7) {
    return (JSON::PP::false, $offset) if $info == 20;
    return (JSON::PP::true,  $offset) if $info == 21;
    return (undef,           $offset) if $info == 22;
    die 'floating point values are not supported by AT DAG-CBOR';
  }

  die 'unsupported CBOR major type';
}

sub _encode_tag ($tag) {
  return _encode_type_and_length(6, $tag);
}

sub _encode_bytes ($bytes) {
  return _encode_type_and_length(2, length($bytes)) . $bytes;
}

sub _encode_text ($text) {
  my $bytes = encode('UTF-8', $text, FB_CROAK);
  return _encode_type_and_length(3, length($bytes)) . $bytes;
}

sub _encode_type_and_length ($major, $value) {
  die 'negative CBOR length' if $value < 0;

  if ($value < 24) {
    return pack('C', ($major << 5) | $value);
  }
  if ($value < 256) {
    return pack('CC', ($major << 5) | 24, $value);
  }
  if ($value < 65536) {
    return pack('Cn', ($major << 5) | 25, $value);
  }
  if ($value < 4294967296) {
    return pack('CN', ($major << 5) | 26, $value);
  }

  return pack('CQ>', ($major << 5) | 27, $value);
}

sub _decode_length ($bytes, $offset, $info) {
  return ($info, $offset) if $info < 24;

  if ($info == 24) {
    die 'truncated CBOR uint8' if $offset + 1 > length $bytes;
    return (unpack('C', substr($bytes, $offset, 1)), $offset + 1);
  }
  if ($info == 25) {
    die 'truncated CBOR uint16' if $offset + 2 > length $bytes;
    return (unpack('n', substr($bytes, $offset, 2)), $offset + 2);
  }
  if ($info == 26) {
    die 'truncated CBOR uint32' if $offset + 4 > length $bytes;
    return (unpack('N', substr($bytes, $offset, 4)), $offset + 4);
  }
  if ($info == 27) {
    die 'truncated CBOR uint64' if $offset + 8 > length $bytes;
    return (unpack('Q>', substr($bytes, $offset, 8)), $offset + 8);
  }

  die 'unsupported CBOR additional info';
}

sub _is_integer ($value) {
  return 0 unless defined $value;
  return 1 if $value =~ /\A-?(?:0|[1-9][0-9]*)\z/;
  return 0 unless looks_like_number($value);
  return int($value) == $value;
}

1;
