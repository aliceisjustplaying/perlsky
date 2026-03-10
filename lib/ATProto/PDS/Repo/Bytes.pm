package ATProto::PDS::Repo::Bytes;

use v5.34;
use warnings;

sub new {
  my ($class, $bytes) = @_;
  return bless \$bytes, $class;
}

sub bytes {
  my ($self) = @_;
  return $$self;
}

1;
