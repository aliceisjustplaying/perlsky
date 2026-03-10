package ATProto::PDS::API::Registry;

use v5.34;
use warnings;

sub new {
  my ($class, %args) = @_;
  return bless {
    handlers => $args{handlers} || {},
  }, $class;
}

sub register {
  my ($self, $nsid, $code) = @_;
  $self->{handlers}{$nsid} = $code;
  return $self;
}

sub handler_for {
  my ($self, $nsid) = @_;
  return $self->{handlers}{$nsid};
}

1;
