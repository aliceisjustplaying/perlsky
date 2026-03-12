package ATProto::PDS::Auth::JWT;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use Digest::SHA qw(hmac_sha256);
use JSON::PP qw(decode_json encode_json);
use ATProto::PDS::Auth::Password qw(random_hex timing_safe_eq);
use ATProto::PDS::Crypto::Secp256k1 qw(sign_compact_low_s);
use ATProto::PDS::Util::BaseX qw(base64url_decode base64url_encode);

our @EXPORT_OK = qw(decode_jwt encode_jwt encode_service_jwt);

sub encode_jwt ($claims, $secret, $header = undef) {
  die 'claims must be a hashref' unless ref($claims) eq 'HASH';
  die 'secret is required' unless defined $secret && length $secret;

  my $jwt_header = {
    alg => 'HS256',
    typ => 'JWT',
    %{ $header // {} },
  };

  my $header_b64  = base64url_encode(encode_json($jwt_header));
  my $claims_b64  = base64url_encode(encode_json($claims));
  my $signing_str = join('.', $header_b64, $claims_b64);
  my $sig         = base64url_encode(hmac_sha256($signing_str, $secret));

  return join('.', $signing_str, $sig);
}

sub decode_jwt ($token, $secret, %opts) {
  die 'token is required' unless defined $token && length $token;
  die 'secret is required' unless defined $secret && length $secret;

  my ($header_b64, $claims_b64, $sig_b64) = split(/\./, $token, 3);
  die 'token must contain three sections' unless defined $sig_b64;

  my $signing_str = join('.', $header_b64, $claims_b64);
  my $expected    = base64url_encode(hmac_sha256($signing_str, $secret));
  die 'invalid signature' unless timing_safe_eq($expected, $sig_b64);

  my $header = decode_json(base64url_decode($header_b64));
  my $claims = decode_json(base64url_decode($claims_b64));

  die 'unsupported jwt alg' unless ($header->{alg} // '') eq 'HS256';
  my $now = $opts{now} // time;

  die 'token not yet valid' if defined $claims->{nbf} && $claims->{nbf} > $now;
  die 'token expired'       if !$opts{allow_expired} && defined $claims->{exp} && $claims->{exp} <= $now;

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

sub encode_service_jwt ($claims, $private_key, $header = undef) {
  die 'claims must be a hashref' unless ref($claims) eq 'HASH';
  die 'private key is required' unless defined $private_key && length $private_key;

  my %jwt_claims = %$claims;
  my $now = time;
  $jwt_claims{iat} //= $now;
  $jwt_claims{exp} //= $jwt_claims{iat} + 60;
  $jwt_claims{jti} //= random_hex(16);
  delete @jwt_claims{grep { !defined $jwt_claims{$_} } keys %jwt_claims};

  my $jwt_header = {
    alg => 'ES256K',
    typ => 'JWT',
    %{ $header // {} },
  };

  my $header_b64  = base64url_encode(encode_json($jwt_header));
  my $claims_b64  = base64url_encode(encode_json(\%jwt_claims));
  my $signing_str = join('.', $header_b64, $claims_b64);
  my $sig         = base64url_encode(sign_compact_low_s($private_key, $signing_str));

  return join('.', $signing_str, $sig);
}

1;
