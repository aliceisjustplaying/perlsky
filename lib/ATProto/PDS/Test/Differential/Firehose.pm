package ATProto::PDS::Test::Differential::Firehose;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use Mojo::UserAgent;
use Time::HiRes qw(time);

use ATProto::PDS::EventStream qw(decode_frame);

our @EXPORT_OK = qw(
  first_frame
  frames_until_quiet
  next_commit_frame
  quiet_firehose
);

sub quiet_firehose ($url, $quiet_seconds = 0.5) {
  my $ua = Mojo::UserAgent->new;
  my $got_frame = 0;
  my $error;
  my $done = 0;

  $ua->websocket($url => sub ($ua, $tx) {
    unless ($tx->is_websocket) {
      $error = $tx->res->error->{message} // 'websocket handshake failed';
      $done = 1;
      Mojo::IOLoop->stop;
      return;
    }

    my $timer = Mojo::IOLoop->timer($quiet_seconds => sub {
      $done = 1;
      $tx->finish(1000);
    });

    $tx->on(binary => sub ($tx, $bytes) {
      $got_frame = 1;
      Mojo::IOLoop->remove($timer);
      $tx->finish(1000);
    });

    $tx->on(finish => sub ($tx, $code, $reason = undef) {
      Mojo::IOLoop->stop if $done || $got_frame || defined $error;
    });
  });

  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
  die "$error\n" if defined $error;
  return !$got_frame;
}

sub next_commit_frame ($url, $expected_path, $trigger, $timeout = 10) {
  my $ua = Mojo::UserAgent->new;
  my $frame;
  my $error;
  my $deadline = time + $timeout;
  my $triggered = 0;
  my $done = 0;

  $ua->websocket($url => sub ($ua, $tx) {
    unless ($tx->is_websocket) {
      $error = $tx->res->error->{message} // 'websocket handshake failed';
      $done = 1;
      Mojo::IOLoop->stop;
      return;
    }

    my $timer;
    $timer = Mojo::IOLoop->recurring(0.1 => sub {
      if (time >= $deadline) {
        $error = "timed out waiting for firehose commit at $expected_path";
        Mojo::IOLoop->remove($timer);
        $done = 1;
        $tx->finish(1000);
      }
    });

    $tx->on(binary => sub ($tx, $bytes) {
      my $decoded = decode_frame($bytes);
      my $header  = $decoded->{header} || {};
      my $body    = $decoded->{body}   || {};
      my @ops     = @{ $body->{ops} || [] };
      my $match   = grep { ($_->{path} // q()) eq $expected_path } @ops;
      if (($header->{t} // q()) eq '#commit' && $match) {
        $frame = $decoded;
        Mojo::IOLoop->remove($timer);
        $done = 1;
        $tx->finish(1000);
      }
    });

    Mojo::IOLoop->next_tick(sub {
      return if $triggered;
      $triggered = 1;
      eval { $trigger->() };
      if ($@) {
        $error = $@;
        Mojo::IOLoop->remove($timer);
        $done = 1;
        $tx->finish(1011);
      }
    });

    $tx->on(finish => sub ($tx, $code, $reason = undef) {
      Mojo::IOLoop->stop if $done || defined $error;
    });
  });

  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
  die "$error\n" if defined $error;
  return $frame;
}

sub first_frame ($url, $timeout = 5) {
  my $ua = Mojo::UserAgent->new;
  my $frame;
  my $error;
  my $done = 0;
  my $deadline = time + $timeout;

  $ua->websocket($url => sub ($ua, $tx) {
    unless ($tx->is_websocket) {
      $error = $tx->res->error->{message} // 'websocket handshake failed';
      $done = 1;
      Mojo::IOLoop->stop;
      return;
    }

    my $timer;
    $timer = Mojo::IOLoop->recurring(0.1 => sub {
      if (time >= $deadline) {
        $error = 'timed out waiting for firehose frame';
        Mojo::IOLoop->remove($timer);
        $done = 1;
        $tx->finish(1000);
      }
    });

    $tx->on(binary => sub ($tx, $bytes) {
      $frame = decode_frame($bytes);
      Mojo::IOLoop->remove($timer);
      $done = 1;
      $tx->finish(1000);
    });

    $tx->on(finish => sub ($tx, $code, $reason = undef) {
      Mojo::IOLoop->stop if $done || defined $error;
    });
  });

  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
  die "$error\n" if defined $error;
  return $frame;
}

sub frames_until_quiet ($url, $quiet_seconds = 0.25, $timeout = 5) {
  my $ua = Mojo::UserAgent->new;
  my @frames;
  my $error;
  my $done = 0;
  my $deadline = time + $timeout;

  $ua->websocket($url => sub ($ua, $tx) {
    unless ($tx->is_websocket) {
      $error = $tx->res->error->{message} // 'websocket handshake failed';
      $done = 1;
      Mojo::IOLoop->stop;
      return;
    }

    my $quiet_timer;
    my $reset_quiet = sub {
      Mojo::IOLoop->remove($quiet_timer) if defined $quiet_timer;
      $quiet_timer = Mojo::IOLoop->timer($quiet_seconds => sub {
        $done = 1;
        $tx->finish(1000);
      });
    };
    $reset_quiet->();

    my $watchdog;
    $watchdog = Mojo::IOLoop->recurring(0.1 => sub {
      if (time >= $deadline) {
        $error = "timed out waiting for websocket frames at $url";
        Mojo::IOLoop->remove($watchdog);
        Mojo::IOLoop->remove($quiet_timer) if defined $quiet_timer;
        $done = 1;
        $tx->finish(1000);
      }
    });

    $tx->on(binary => sub ($tx, $bytes) {
      push @frames, decode_frame($bytes);
      $reset_quiet->();
    });

    $tx->on(finish => sub ($tx, $code, $reason = undef) {
      Mojo::IOLoop->remove($watchdog) if defined $watchdog;
      Mojo::IOLoop->remove($quiet_timer) if defined $quiet_timer;
      Mojo::IOLoop->stop if $done || defined $error;
    });
  });

  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
  die "$error\n" if defined $error;
  return \@frames;
}

1;
