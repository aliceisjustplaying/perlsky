package ATProto::PDS::Auth::Password;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use Digest::SHA qw(sha256 sha256_hex);

our @EXPORT_OK = qw(hash_password random_bytes random_hex timing_safe_eq verify_password);

sub random_bytes ($length = 16) {
  open(my $fh, '<:raw', '/dev/urandom') or die "open(/dev/urandom): $!";
  my $bytes = q();
  my $read = read($fh, $bytes, $length);
  close($fh);
  die 'failed to read random bytes' unless defined $read && $read == $length;
  return $bytes;
}

sub random_hex ($length = 16) {
  return unpack('H*', random_bytes($length));
}

sub hash_password ($password, $salt = undef, %opts) {
  die 'password is required' unless defined $password && length $password;
  $salt //= random_bytes(16);
  my $rounds = $opts{rounds} // 50_000;
  my $digest = $salt . $password;
  for (1 .. $rounds) {
    $digest = sha256($digest . $salt . $password);
  }
  return {
    salt  => $salt,
    hash  => unpack('H*', $digest),
    rounds => $rounds,
  };
}

sub verify_password ($password, $salt, $expected_hash, %opts) {
  my $actual = hash_password($password, $salt, %opts);
  return timing_safe_eq($actual->{hash}, $expected_hash);
}

sub timing_safe_eq ($left, $right) {
  return 0 unless defined $left && defined $right;
  return 0 unless length($left) == length($right);
  my $diff = 0;
  for my $i (0 .. length($left) - 1) {
    $diff |= ord(substr($left, $i, 1)) ^ ord(substr($right, $i, 1));
  }
  return $diff == 0 ? 1 : 0;
}

1;
