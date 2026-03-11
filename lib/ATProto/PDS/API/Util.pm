package ATProto::PDS::API::Util;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use JSON::PP ();
use Mojo::IOLoop;

use ATProto::PDS::EventStream qw(encode_error_frame encode_info_frame);

our @EXPORT_OK = qw(
  blob_ref
  flatten_params
  iso8601
  pump_event_subscription
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

sub resolve_did_account ($c, $did) {
  my $account = $c->store->get_account_by_did($did);
  return $account if $account;
  my $target = lc($did // q());
  $target =~ s/%3a/:/ig;
  for my $row (@{ $c->store->list_accounts }) {
    my $candidate = lc($row->{did} // q());
    $candidate =~ s/%3a/:/ig;
    return $row if $candidate eq $target;
  }
  return undef;
}

sub resolve_repo ($c, $repo) {
  return undef unless defined $repo && length $repo;
  return $c->store->get_account_by_handle($repo) unless $repo =~ /\Adid:/;
  return resolve_did_account($c, $repo);
}

sub subscription_start_seq ($c, %args) {
  my $cursor_param      = $args{cursor_param};
  my $latest            = $args{latest} // $c->store->latest_event_seq;
  my $oldest            = $args{oldest} // $c->store->oldest_event_seq;
  my $future_limit      = $args{future_limit} // $latest;
  my $future_message    = $args{future_message} // 'Cursor is ahead of the local event stream';
  my $outdated_message  = $args{outdated_message} // 'Cursor predates the oldest locally retained event';

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

  if ($oldest && $cursor && $cursor < $oldest) {
    $c->subscription_send(
      binary     => encode_info_frame('OutdatedCursor', $outdated_message),
      frame_type => 'info',
    );
    return $oldest;
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
