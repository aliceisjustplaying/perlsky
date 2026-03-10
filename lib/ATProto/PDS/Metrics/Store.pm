package ATProto::PDS::Metrics::Store;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Time::HiRes qw(time);

use Exporter 'import';

our @EXPORT_OK = qw(observe_store_operation);

sub observe_store_operation ($metrics, $operation, $code) {
  my $start = time;
  my $wantarray = wantarray;
  my (@result, $result);
  my $status = 'ok';

  my $ok = eval {
    if (!defined $wantarray) {
      $code->();
    } elsif ($wantarray) {
      @result = $code->();
    } else {
      $result = $code->();
    }
    1;
  };

  if (!$ok) {
    $status = 'error';
  }

  if ($metrics) {
    my $duration = time - $start;
    my $labels = {
      operation => $operation,
      status    => $status,
    };
    $metrics->increment_counter('perlsky_store_operations_total', 1, $labels);
    $metrics->observe_histogram('perlsky_store_operation_duration_seconds', $duration, $labels);
  }

  die $@ unless $ok;
  return if !defined $wantarray;
  return $wantarray ? @result : $result;
}

1;
