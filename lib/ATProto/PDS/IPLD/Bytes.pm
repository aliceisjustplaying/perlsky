package ATProto::PDS::IPLD::Bytes;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use overload '""' => sub ($self, @) { $self->{bytes} }, fallback => 1;

sub new ($class, $bytes) {
  return bless { bytes => $bytes // '' }, $class;
}

sub bytes ($self) {
  return $self->{bytes};
}

1;
