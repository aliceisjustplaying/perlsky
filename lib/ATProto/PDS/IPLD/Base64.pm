package ATProto::PDS::IPLD::Base64;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use MIME::Base64 qw(encode_base64 decode_base64);

our @EXPORT_OK = qw(encode_base64url decode_base64url);

sub encode_base64url ($bytes) {
  my $text = encode_base64($bytes, '');
  $text =~ tr{+/}{-_};
  $text =~ s/=+\z//;
  return $text;
}

sub decode_base64url ($text) {
  my $copy = $text;
  $copy =~ tr{-_}{+/};
  my $pad = length($copy) % 4;
  $copy .= '=' x (4 - $pad) if $pad;
  return decode_base64($copy);
}

1;
