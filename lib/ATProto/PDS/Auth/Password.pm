package ATProto::PDS::Auth::Password;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use Digest::SHA qw(sha256_hex);

our @EXPORT_OK = qw(hash_password verify_password);

sub hash_password ($password) {
  die 'password is required' unless defined $password && length $password;
  my $salt = _random_hex(16);
  return join(':', 'sha256', $salt, sha256_hex($salt . $password));
}

sub verify_password ($password, $stored) {
  return 0 unless defined $password && defined $stored;
  my ($scheme, $salt, $digest) = split(/:/, $stored, 3);
  return 0 unless defined $scheme && $scheme eq 'sha256';
  return sha256_hex($salt . $password) eq $digest ? 1 : 0;
}

sub _random_hex ($bytes) {
  open(my $fh, '<:raw', '/dev/urandom') or die "open(/dev/urandom): $!";
  my $buf = q();
  my $read = read($fh, $buf, $bytes);
  CORE::close($fh);
  die 'failed to read random bytes' unless defined $read && $read == $bytes;
  return unpack('H*', $buf);
}

1;
