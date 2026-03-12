package ATProto::PDS::API::Util;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use JSON::PP ();
use Mojo::IOLoop;

use ATProto::PDS::EventStream qw(encode_error_frame encode_info_frame);
use ATProto::PDS::Identity qw(normalize_handle);

our @EXPORT_OK = qw(
  blob_ref
  flatten_params
  iso8601
  pump_event_subscription
  render_empty_success
  resolve_did_account
  resolve_repo
  subscription_start_seq
  xrpc_error
);

sub xrpc_error ($status, $error, $message) {
  die {
    status  => $status,
    error   => $error,
    message => $message,
  };
}

sub flatten_params (@values) {
  my @flat;
  for my $value (@values) {
    push @flat, ref($value) eq 'ARRAY' ? @$value : $value;
  }
  return @flat;
}

sub iso8601 ($epoch = undef) {
  my @gmt = gmtime($epoch // time);
  return sprintf(
    '%04d-%02d-%02dT%02d:%02d:%02dZ',
    $gmt[5] + 1900,
    $gmt[4] + 1,
    $gmt[3],
    $gmt[2],
    $gmt[1],
    $gmt[0],
  );
}

sub render_empty_success ($c) {
  $c->render(data => q());
  return;
}

sub resolve_did_account ($c, $did) {
  my $target = lc($did // q());
  $target =~ s/%3a/:/ig;
  my $cache = $c->can('stash') ? ($c->stash('resolve_did_account_cache') || {}) : {};
  if (exists $cache->{$target}) {
    _observe_repo_resolution($c, 'did_account', 'request_cache');
    return $cache->{$target};
  }

  my $account = $c->store->get_account_by_did($did);
  if ($account) {
    _observe_repo_resolution($c, 'did_account', 'exact');
    $cache->{$target} = $account if $c->can('stash');
    $c->stash(resolve_did_account_cache => $cache) if $c->can('stash');
    return $account;
  }

  for my $row (@{ $c->store->list_accounts }) {
    my $candidate = lc($row->{did} // q());
    $candidate =~ s/%3a/:/ig;
    if ($candidate eq $target) {
      _observe_repo_resolution($c, 'did_account', 'list_scan');
      if ($c->can('stash')) {
        $cache->{$target} = $row;
        $c->stash(resolve_did_account_cache => $cache);
      }
      return $row;
    }
  }
  if ($c->can('stash')) {
    $cache->{$target} = undef;
    $c->stash(resolve_did_account_cache => $cache);
  }
  _observe_repo_resolution($c, 'did_account', 'miss');
  return undef;
}

sub resolve_repo ($c, $repo) {
  return undef unless defined $repo && length $repo;
  my $cache = $c->can('stash') ? ($c->stash('resolve_repo_cache') || {}) : {};
  my $cache_key = lc($repo);
  if (exists $cache->{$cache_key}) {
    _observe_repo_resolution($c, 'repo', 'request_cache');
    return $cache->{$cache_key};
  }

  if ($repo !~ /\Adid:/i) {
    my $normalized = normalize_handle($repo, $c->config_value('service_handle_domain', 'localhost'));
    my $account = $c->store->get_account_by_handle($repo);
    my $source = 'exact';
    if (!$account && defined($normalized)) {
      $account = $c->store->get_account_by_handle($normalized);
      $source = 'normalized' if $account;
    }
    if ($c->can('stash')) {
      $cache->{$cache_key} = $account;
      $cache->{ lc($normalized) } = $account if defined $normalized && length $normalized;
      $c->stash(resolve_repo_cache => $cache);
    }
    _observe_repo_resolution($c, 'repo', $account ? $source : 'miss');
    return $account;
  }
  my $account = resolve_did_account($c, $repo);
  if ($c->can('stash')) {
    $cache->{$cache_key} = $account;
    $c->stash(resolve_repo_cache => $cache);
  }
  _observe_repo_resolution($c, 'repo', $account ? 'did_account' : 'miss');
  return $account;
}

sub _observe_repo_resolution ($c, $resolver, $source) {
  return unless $c && $c->can('app');
  my $app = eval { $c->app } or return;
  my $metrics = eval { $app->metrics } or return;
  $metrics->increment_counter(
    'perlsky_repo_resolution_total',
    1,
    {
      resolver => $resolver,
      source   => $source,
    },
  );
}

sub subscription_start_seq ($c, %args) {
  my $cursor_param      = $args{cursor_param};
  my $latest            = $args{latest} // $c->store->latest_event_seq;
  my $future_limit      = $args{future_limit} // $latest;
  my $future_message    = $args{future_message} // 'Cursor is ahead of the local event stream';
  my $outdated_message  = $args{outdated_message} // 'Cursor predates the oldest locally retained event';
  my $backfill_window   = $args{backfill_window_seconds}
    // $c->config_value('subscription_backfill_window_seconds', 3600);
  my $backfill_cutoff = $args{backfill_cutoff} // (time - $backfill_window);

  if (!defined $cursor_param || $cursor_param eq q()) {
    return $latest + 1;
  }

  my $cursor = int($cursor_param);
  if ($cursor > $future_limit) {
    $c->subscription_send(
      binary     => encode_error_frame('FutureCursor', $future_message),
      frame_type => 'error',
    );
    $c->finish(1008);
    return undef;
  }

  my $next_event = $args{next_event} // $c->store->next_event_after_seq($cursor);
  if ($next_event && ($next_event->{created_at} // 0) < $backfill_cutoff) {
    $c->subscription_send(
      binary     => encode_info_frame('OutdatedCursor', $outdated_message),
      frame_type => 'info',
    );
    my $resume_seq = $args{backfill_start} // $c->store->earliest_event_seq_after_time($backfill_cutoff);
    return defined($resume_seq) ? $resume_seq : ($latest + 1);
  }

  return $cursor + 1;
}

sub pump_event_subscription ($c, $next_seq, $frame_for_event) {
  my $drain;
  $drain = sub {
    my $events = $c->store->list_events_from($next_seq, limit => 100);
    for my $event (@$events) {
      $next_seq = $event->{seq} + 1;
      my ($frame, $frame_type) = $frame_for_event->($event);
      next unless defined $frame;
      $c->subscription_send(
        binary     => $frame,
        frame_type => $frame_type // ($event->{type} // 'message'),
      );
    }
  };

  $drain->();
  my $timer_id = Mojo::IOLoop->recurring(0.25 => sub { $drain->() });
  $c->on(finish => sub ($c, $code, $reason = undef) {
    Mojo::IOLoop->remove($timer_id) if defined $timer_id;
  });
  return;
}

sub blob_ref ($cid, $mime_type, $size) {
  return {
    '$type'    => 'blob',
    ref        => { '$link' => $cid },
    mimeType   => $mime_type,
    size       => $size + 0,
  };
}

1;
