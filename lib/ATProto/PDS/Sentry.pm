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
  my $frames = _stacktrace_frames($message);
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
          (@$frames ? (stacktrace => { frames => $frames }) : ()),
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

sub _stacktrace_frames ($message) {
  my @frames = _message_stack_frames($message)->@*;
  my %seen = map { _frame_key($_) => 1 } @frames;

  for my $frame (_caller_stack_frames()->@*) {
    my $key = _frame_key($frame);
    next if $seen{$key}++;
    push @frames, $frame;
  }

  return \@frames;
}

sub _message_stack_frames ($message) {
  return [] unless defined $message && length $message;

  my @frames;
  my @lines = split /\n/, $message;
  if (@lines && $lines[0] =~ / at (.+) line (\d+)\.?$/) {
    push @frames, {
      filename => $1,
      function => '<exception>',
      module   => undef,
      lineno   => 0 + $2,
      in_app   => _in_app_filename($1),
    };
  }

  for my $line (@lines[1 .. $#lines]) {
    next unless $line =~ /^\s*(.+?) called at (.+) line (\d+)\.?$/;
    push @frames, {
      filename => $2,
      function => $1,
      module   => _module_from_function($1),
      lineno   => 0 + $3,
      in_app   => _in_app_filename($2),
    };
  }

  return \@frames;
}

sub _caller_stack_frames () {
  my @frames;
  my $level = 1;
  while (my @caller = caller($level++)) {
    my ($package, $filename, $line, $subroutine) = @caller[0 .. 3];
    next if defined $subroutine && $subroutine =~ /\AATProto::PDS::Sentry::(?:capture_exception|_stacktrace_frames|_message_stack_frames|_caller_stack_frames|_frame_key|_module_from_function|_in_app_filename)\z/;
    push @frames, {
      filename => $filename,
      function => $subroutine // '<main>',
      module   => $package,
      lineno   => 0 + $line,
      in_app   => _in_app_filename($filename),
    };
  }
  return [ reverse @frames ];
}

sub _frame_key ($frame) {
  return join "\x1F",
    map { defined $_ ? $_ : q() }
    @{$frame}{qw(filename function lineno)};
}

sub _module_from_function ($function) {
  return undef unless defined $function && length $function;
  return $1 if $function =~ /\A(.+)::[^:]+\z/;
  return undef;
}

sub _in_app_filename ($filename) {
  return 0 unless defined $filename && length $filename;
  return 0 if $filename =~ /^\(eval/;
  return 0 if $filename =~ m{(?:^|/)(?:core_perl|site_perl|vendor_perl)(?:/|$)};
  return 0 if $filename =~ m{(?:^|/)local/lib/perl5(?:/|$)};
  return 0 if $filename =~ m{^/usr/};
  return 1;
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
  $store->query(undef);
  return {
    public_key => $url->username,
    secret_key => $url->password,
    project_id => $project_id,
    store_url  => $store->to_string,
  };
}

1;
