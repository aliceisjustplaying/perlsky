package ATProto::PDS::Sentry;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Digest::SHA qw(sha1_hex);
use Mojo::JSON qw(false);
use Mojo::URL;
use Mojo::UserAgent;
use POSIX qw(strftime);

sub new ($class, %args) {
  my $parsed = _parse_dsn($args{dsn});
  return bless {
    dsn         => $args{dsn},
    parsed_dsn  => $parsed,
    environment => $args{environment} // 'production',
    release     => $args{release},
    server_name => $args{server_name},
    logger      => $args{logger},
    service     => $args{service} // 'perlsky',
    timeout     => $args{timeout} // 2,
    ua          => undef,
  }, $class;
}

sub enabled ($self) {
  return $self->{parsed_dsn} ? 1 : 0;
}

sub capture_exception ($self, %args) {
  return 0 unless $self->enabled;

  my $message = $args{message} // 'Unhandled exception';
  my $event = {
    event_id    => substr(sha1_hex(join q{|}, time, $$, rand(), $message), 0, 32),
    timestamp   => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime),
    platform    => 'perl',
    level       => $args{level} // 'error',
    logger      => $self->{service},
    environment => $self->{environment},
    ($self->{release}     ? (release     => $self->{release})     : ()),
    ($self->{server_name} ? (server_name => $self->{server_name}) : ()),
    tags => {
      service       => $self->{service},
      nsid          => $args{nsid} // 'unknown',
      endpoint_type => $args{endpoint_type} // 'unknown',
      status        => ($args{status} // 500),
      (defined $args{method} ? (method => $args{method}) : ()),
    },
    exception => {
      values => [
        {
          type  => $args{type} // 'UnhandledXRPCException',
          value => $message,
        },
      ],
    },
  };

  if (my $c = $args{context}) {
    my $req = $c->req;
    $event->{request} = {
      method => $req->method,
      url    => $req->url->to_abs->to_string,
      headers => {
        map { $_ => scalar $req->headers->header($_) }
        grep { lc($_) ne 'authorization' && lc($_) ne 'cookie' }
        $req->headers->names->@*
      },
    };
  }

  if (my $did = $args{did}) {
    $event->{user} = { id => $did };
  }

  my $tx = eval {
    $self->_ua->post(
      $self->{parsed_dsn}{store_url} => {
        'Content-Type' => 'application/json',
        'X-Sentry-Auth' => $self->_auth_header,
      } => json => $event
    );
  };
  return 0 unless $tx;
  my $code = eval { $tx->result->code } // 0;
  return ($code >= 200 && $code < 300) ? 1 : 0;
}

sub _ua ($self) {
  return $self->{ua} if $self->{ua};
  my $ua = Mojo::UserAgent->new(max_redirects => 0);
  $ua->request_timeout($self->{timeout});
  $ua->inactivity_timeout($self->{timeout});
  $ua->connect_timeout($self->{timeout});
  return $self->{ua} = $ua;
}

sub _auth_header ($self) {
  my $parsed = $self->{parsed_dsn};
  my @parts = (
    'Sentry sentry_version=7',
    'sentry_client=' . $self->{service} . '/1.0',
    'sentry_key=' . $parsed->{public_key},
  );
  push @parts, 'sentry_secret=' . $parsed->{secret_key}
    if defined $parsed->{secret_key} && length $parsed->{secret_key};
  return join(', ', @parts);
}

sub _parse_dsn ($dsn) {
  return undef unless defined $dsn && length $dsn;
  my $url = Mojo::URL->new($dsn);
  my $project_id = pop @{ $url->path->parts };
  die "invalid sentry_dsn: missing project id\n" unless defined $project_id && length $project_id;
  my @prefix = @{ $url->path->parts };
  my $store = $url->clone;
  $store->userinfo(undef);
  $store->path('/' . join('/', grep { length } @prefix, 'api', $project_id, 'store') . '/');
  $store->query({
    sentry_key     => $url->username,
    sentry_version => 7,
    ((defined($url->password) && length($url->password)) ? (sentry_secret => $url->password) : ()),
  });
  return {
    public_key => $url->username,
    secret_key => $url->password,
    project_id => $project_id,
    store_url  => $store->to_string,
  };
}

1;
