package ATProto::PDS::IPLD::Multihash;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use Crypt::Digest::SHA256 qw(sha256);

use ATProto::PDS::IPLD::Varint qw(encode_uvarint decode_uvarint);

our @EXPORT_OK = qw(sha256_multihash decode_multihash);

use constant SHA256_CODE => 0x12;

sub sha256_multihash ($bytes) {
  my $digest = sha256($bytes);
  return encode_uvarint(SHA256_CODE) . encode_uvarint(length($digest)) . $digest;
}

sub decode_multihash ($bytes, $offset = 0) {
  my ($code, $after_code)   = decode_uvarint($bytes, $offset);
  my ($length, $after_len)  = decode_uvarint($bytes, $after_code);
  my $digest = substr($bytes, $after_len, $length);
  die 'truncated multihash digest' unless length($digest) == $length;

  return (
    {
      code   => $code,
      length => $length,
      digest => $digest,
      bytes  => substr($bytes, $offset, $after_len - $offset + $length),
    },
    $after_len + $length,
  );
}

1;
