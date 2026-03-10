package ATProto::PDS::Metrics;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use JSON::PP ();

sub new ($class, %args) {
  my $self = bless {
    service => $args{service} // 'perlsky',
    metrics => {},
  }, $class;

  $self->_register_counter(
    'perlsky_xrpc_requests_total',
    'Total XRPC HTTP requests by method, endpoint, type, and status.',
    [qw(method nsid endpoint_type status)],
  );
  $self->_register_histogram(
    'perlsky_xrpc_request_duration_seconds',
    'XRPC HTTP request duration in seconds.',
    [qw(method nsid endpoint_type status)],
    [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
  );
  $self->_register_counter(
    'perlsky_subscription_connections_total',
    'Total websocket subscription connections opened.',
    [qw(nsid)],
  );
  $self->_register_counter(
    'perlsky_subscription_closes_total',
    'Total websocket subscription closes by endpoint and close code.',
    [qw(nsid code)],
  );
  $self->_register_gauge(
    'perlsky_subscription_active',
    'Active websocket subscription connections.',
    [qw(nsid)],
  );
  $self->_register_counter(
    'perlsky_subscription_frames_total',
    'Total websocket frames emitted by endpoint, frame type, and encoding.',
    [qw(nsid frame_type encoding)],
  );
  $self->_register_counter(
    'perlsky_subscription_bytes_total',
    'Total websocket frame bytes emitted by endpoint and encoding.',
    [qw(nsid encoding)],
  );
  $self->_register_histogram(
    'perlsky_subscription_duration_seconds',
    'Subscription connection lifetime in seconds.',
    [qw(nsid)],
    [0.1, 0.5, 1, 5, 15, 30, 60, 300, 900, 3600],
  );
  $self->_register_counter(
    'perlsky_crawler_requests_total',
    'Total outbound requestCrawl notifications by crawler service and result.',
    [qw(service result)],
  );
  $self->_register_histogram(
    'perlsky_crawler_request_duration_seconds',
    'Outbound requestCrawl latency in seconds.',
    [qw(service result)],
    [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
  );
  $self->_register_counter(
    'perlsky_blob_ingress_bytes_total',
    'Total bytes accepted through repo blob uploads.',
    [qw(mime_type)],
  );
  $self->_register_counter(
    'perlsky_blob_egress_bytes_total',
    'Total bytes served through sync blob downloads.',
    [qw(mime_type)],
  );
  $self->_register_counter(
    'perlsky_store_operations_total',
    'Total instrumented store operations by operation and status.',
    [qw(operation status)],
  );
  $self->_register_histogram(
    'perlsky_store_operation_duration_seconds',
    'Duration of instrumented store operations.',
    [qw(operation status)],
    [0.0005, 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1],
  );
  $self->_register_gauge(
    'perlsky_build_info',
    'Static build information for the running service.',
    [qw(service)],
  );
  $self->set_gauge('perlsky_build_info', 1, { service => $self->{service} });

  return $self;
}

sub increment_counter ($self, $name, $value = 1, $labels = {}) {
  my $metric = $self->_metric($name, 'counter');
  my $key = _label_key($metric->{labels}, $labels);
  $metric->{samples}{$key} += $value;
  return $metric->{samples}{$key};
}

sub set_gauge ($self, $name, $value, $labels = {}) {
  my $metric = $self->_metric($name, 'gauge');
  my $key = _label_key($metric->{labels}, $labels);
  $metric->{samples}{$key} = $value;
  return $value;
}

sub add_gauge ($self, $name, $delta, $labels = {}) {
  my $metric = $self->_metric($name, 'gauge');
  my $key = _label_key($metric->{labels}, $labels);
  $metric->{samples}{$key} += $delta;
  return $metric->{samples}{$key};
}

sub observe_histogram ($self, $name, $value, $labels = {}) {
  my $metric = $self->_metric($name, 'histogram');
  my $key = _label_key($metric->{labels}, $labels);
  my $sample = $metric->{samples}{$key} ||= {
    sum     => 0,
    count   => 0,
    buckets => { map { $_ => 0 } @{ $metric->{buckets} } },
    labels  => { %{$labels} },
  };

  $sample->{sum} += $value;
  $sample->{count} += 1;
  for my $bucket (@{ $metric->{buckets} }) {
    $sample->{buckets}{$bucket} += 1 if $value <= $bucket;
  }
  return $sample;
}

sub render_prometheus ($self) {
  my @lines;
  for my $name (sort keys %{ $self->{metrics} }) {
    my $metric = $self->{metrics}{$name};
    push @lines, "# HELP $name $metric->{help}";
    push @lines, "# TYPE $name $metric->{type}";

    if ($metric->{type} eq 'histogram') {
      for my $key (sort keys %{ $metric->{samples} }) {
        my $sample = $metric->{samples}{$key};
        my %base = %{ $sample->{labels} || {} };
        for my $bucket (@{ $metric->{buckets} }) {
          push @lines, _format_sample(
            "${name}_bucket",
            { %base, le => $bucket },
            $sample->{buckets}{$bucket} || 0,
          );
        }
        push @lines, _format_sample("${name}_bucket", { %base, le => '+Inf' }, $sample->{count});
        push @lines, _format_sample("${name}_sum", \%base, $sample->{sum});
        push @lines, _format_sample("${name}_count", \%base, $sample->{count});
      }
      next;
    }

    for my $key (sort keys %{ $metric->{samples} }) {
      push @lines, _format_sample($name, _decode_label_key($key), $metric->{samples}{$key});
    }
  }

  return join("\n", @lines) . "\n";
}

sub _metric ($self, $name, $expected_type) {
  my $metric = $self->{metrics}{$name}
    or die "metric $name is not registered";
  die "metric $name is not a $expected_type"
    unless $metric->{type} eq $expected_type;
  return $metric;
}

sub _register_counter ($self, $name, $help, $labels) {
  $self->{metrics}{$name} = {
    type    => 'counter',
    help    => $help,
    labels  => $labels,
    samples => {},
  };
}

sub _register_gauge ($self, $name, $help, $labels) {
  $self->{metrics}{$name} = {
    type    => 'gauge',
    help    => $help,
    labels  => $labels,
    samples => {},
  };
}

sub _register_histogram ($self, $name, $help, $labels, $buckets) {
  $self->{metrics}{$name} = {
    type    => 'histogram',
    help    => $help,
    labels  => $labels,
    buckets => [ sort { $a <=> $b } @$buckets ],
    samples => {},
  };
}

sub _format_sample ($name, $labels, $value) {
  my $label_text = _format_labels($labels);
  return defined($label_text) ? "$name$label_text $value" : "$name $value";
}

sub _format_labels ($labels) {
  my @keys = sort keys %{$labels || {}};
  return undef unless @keys;
  my @pairs = map {
    my $value = defined $labels->{$_} ? $labels->{$_} : q();
    $value =~ s/\\/\\\\/g;
    $value =~ s/"/\\"/g;
    $value =~ s/\n/\\n/g;
    qq{$_="$value"}
  } @keys;
  return '{' . join(',', @pairs) . '}';
}

sub _label_key ($ordered_labels, $labels) {
  state $json = JSON::PP->new->canonical(1)->allow_nonref(1);
  my %normalized = map {
    my $value = $labels->{$_};
    $_ => defined $value ? "$value" : q()
  } @$ordered_labels;
  return $json->encode(\%normalized);
}

sub _decode_label_key ($key) {
  return JSON::PP::decode_json($key);
}

1;
