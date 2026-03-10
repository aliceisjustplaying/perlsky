package ATProto::PDS::Crawlers;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Mojo::IOLoop;
use Mojo::URL;
use Mojo::UserAgent;
use Time::HiRes qw(time);

sub new ($class, %args) {
  return bless {
    hostname      => $args{hostname}      // 'localhost',
    crawlers      => $args{crawlers}      // [],
    store         => $args{store},
    metrics       => $args{metrics},
    min_interval  => $args{min_interval}  // (20 * 60),
    last_notified => $args{last_notified} // 0,
    in_flight     => 0,
  }, $class;
}

sub has_crawlers ($self) {
  return scalar @{ $self->{crawlers} || [] };
}

sub notify_of_update ($self, %args) {
  return 0 unless $self->has_crawlers;

  my $now = $args{now} // time;
  return 0 if $self->{in_flight};
  return 0 if !$args{force} && ($now - ($self->{last_notified} // 0) < ($self->{min_interval} // 0));

  my $hostname = $self->{hostname};
  my @services = @{ $self->{crawlers} || [] };
  my $seq      = $args{last_seq};
  $seq = eval { $self->{store}->latest_event_seq } if !defined($seq) && $self->{store};

  $self->{in_flight}     = 1;
  $self->{last_notified} = $now;

  for my $service (@services) {
    $self->_touch_status($service,
      requested_at => $now,
      last_seq     => $seq,
      status       => {
        status => 'pending',
        service => $service,
      },
    );
  }

  my $subprocess = Mojo::IOLoop->subprocess;
  $subprocess->run(
    sub ($subprocess) {
      return _request_crawl_batch($hostname, \@services);
    },
    sub ($subprocess, $err, $results) {
      $self->{in_flight} = 0;
      if ($err) {
        for my $service (@services) {
          $self->_touch_status($service,
            last_seq => $seq,
            status   => {
              status    => 'error',
              service   => $service,
              lastError => "$err",
            },
          );
        }
        return;
      }

      for my $result (@{ $results || [] }) {
        if ($self->{metrics}) {
          my $result_label = $result->{ok} ? 'ok' : 'error';
          $self->{metrics}->increment_counter('perlds_crawler_requests_total', 1, {
            service => $result->{service},
            result  => $result_label,
          });
          $self->{metrics}->observe_histogram(
            'perlds_crawler_request_duration_seconds',
            $result->{duration_seconds} // 0,
            {
              service => $result->{service},
              result  => $result_label,
            },
          );
        }
        $self->_touch_status($result->{service},
          notified_at => time,
          last_seq    => $seq,
          status      => {
            status        => $result->{ok} ? 'active' : 'error',
            service       => $result->{service},
            responseCode  => $result->{code},
            ($result->{error} ? (lastError => $result->{error}) : ()),
          },
        );
      }
    },
  );

  return 1;
}

sub _touch_status ($self, $service, %args) {
  return unless $self->{store};
  my $host = _service_host($service);
  $self->{store}->touch_host_notice(
    hostname => $host,
    %args,
  );
}

sub _request_crawl_batch ($hostname, $services) {
  my $ua = Mojo::UserAgent->new(max_redirects => 0);
  $ua->request_timeout(10);
  $ua->inactivity_timeout(10);

  my @results;
  for my $service (@$services) {
    my $started = time;
    my $result = {
      service => $service,
      ok      => 0,
    };
    my $tx = eval {
      $ua->post(
        Mojo::URL->new($service)->path('/xrpc/com.atproto.sync.requestCrawl')->to_string => {
          'Content-Type' => 'application/json',
        } => json => {
          hostname => $hostname,
        }
      );
    };

    if (!$tx || $@) {
      $result->{error} = $@ ? "$@" : 'request failed';
      push @results, $result;
      next;
    }

    my $res = $tx->result;
    $result->{duration_seconds} = time - $started;
    $result->{code} = $res->code;
    if ($res->is_success) {
      $result->{ok} = 1;
    } else {
      my $message = $res->json->{message} // $res->message // 'request failed';
      $result->{error} = $message;
    }
    push @results, $result;
  }

  return \@results;
}

sub _service_host ($service) {
  my $url = Mojo::URL->new($service);
  my $host = lc($url->host // $service);
  my $scheme = $url->scheme // 'http';
  my $port = $url->port;
  my $default = $scheme eq 'https' ? 443 : 80;
  $host .= ':' . $port if defined $port && $port != $default;
  return $host;
}

1;
