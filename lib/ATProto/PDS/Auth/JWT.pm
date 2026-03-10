package ATProto::PDS::Auth::JWT;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use Digest::SHA qw(hmac_sha256);
use JSON::PP qw(decode_json encode_json);
use MIME::Base64 qw(decode_base64 encode_base64);

our @EXPORT_OK = qw(decode_jwt encode_jwt);

sub encode_jwt ($claims, $secret, $header = undef) {
  die 'claims must be a hashref' unless ref($claims) eq 'HASH';
  die 'secret is required' unless defined $secret && length $secret;

  my $jwt_header = {
    alg => 'HS256',
    typ => 'JWT',
    %{ $header // {} },
  };

  my $header_b64  = _b64url_encode(encode_json($jwt_header));
  my $claims_b64  = _b64url_encode(encode_json($claims));
  my $signing_str = join('.', $header_b64, $claims_b64);
  my $sig         = _b64url_encode(hmac_sha256($signing_str, $secret));

  return join('.', $signing_str, $sig);
}

sub decode_jwt ($token, $secret, %opts) {
  die 'token is required' unless defined $token && length $token;
  die 'secret is required' unless defined $secret && length $secret;

  my ($header_b64, $claims_b64, $sig_b64) = split(/\./, $token, 3);
  die 'token must contain three sections' unless defined $sig_b64;

  my $signing_str = join('.', $header_b64, $claims_b64);
  my $expected    = _b64url_encode(hmac_sha256($signing_str, $secret));
  die 'invalid signature' unless _timing_safe_eq($expected, $sig_b64);

  my $header = decode_json(_b64url_decode($header_b64));
  my $claims = decode_json(_b64url_decode($claims_b64));

  die 'unsupported jwt alg' unless ($header->{alg} // '') eq 'HS256';
  my $now = $opts{now} // time;

  die 'token not yet valid' if defined $claims->{nbf} && $claims->{nbf} > $now;
  die 'token expired'       if defined $claims->{exp} && $claims->{exp} <= $now;

  if (defined $opts{audience}) {
    my $aud = $claims->{aud};
    if (ref($aud) eq 'ARRAY') {
      die 'unexpected audience' unless grep { defined($_) && $_ eq $opts{audience} } @$aud;
    } else {
      die 'unexpected audience' unless defined($aud) && $aud eq $opts{audience};
    }
  }

  return {
    header => $header,
    claims => $claims,
  };
}

sub _b64url_encode ($bytes) {
  my $b64 = encode_base64($bytes, q());
  $b64 =~ tr{+/}{-_};
  $b64 =~ s/=+\z//;
  return $b64;
}

sub _b64url_decode ($text) {
  my $b64 = $text;
  $b64 =~ tr{-_}{+/};
  my $pad = length($b64) % 4;
  $b64 .= '=' x (4 - $pad) if $pad;
  return decode_base64($b64);
}

sub _timing_safe_eq ($left, $right) {
  return 0 unless defined $left && defined $right;
  return 0 unless length($left) == length($right);

  my $diff = 0;
  for my $index (0 .. length($left) - 1) {
    $diff |= ord(substr($left,  $index, 1)) ^ ord(substr($right, $index, 1));
  }

  return $diff == 0 ? 1 : 0;
}

1;
