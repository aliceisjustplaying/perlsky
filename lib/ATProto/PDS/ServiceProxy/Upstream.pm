package ATProto::PDS::ServiceProxy::Upstream;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';

use ATProto::PDS::API::Util qw(xrpc_error);
use ATProto::PDS::Constants qw(
  SERVICE_ID_BSKY_APPVIEW
  SERVICE_ID_BSKY_CHAT
);

our @EXPORT_OK = qw(
  _config
  _permission_audience_for_request
  _perform_upstream_request
  _target_for_request
  _target_from_proxy_header
);

sub _perform_upstream_request ($self, %args) {
  my $method   = $args{method};
  my $url      = $args{url};
  my $headers  = $args{headers} // {};
  my $body     = $args{body};
  my $attempts = ($method eq 'GET' || $method eq 'HEAD') ? 3 : 1;
  my $last_res;

  for my $attempt (1 .. $attempts) {
    my $tx = $method eq 'POST'
      ? $self->ua->build_tx($method => $url => $headers => $body)
      : $self->ua->build_tx($method => $url => $headers);

    $tx = eval { $self->ua->start($tx) };
    if (my $err = $@) {
      my $message = "$err";
      xrpc_error(502, 'UpstreamFailure', $message || 'Upstream service unreachable')
        if $attempt >= $attempts;
      select undef, undef, undef, 0.2 * $attempt;
      next;
    }

    my $res = eval { $tx->result };
    if (my $err = $@) {
      my $message = "$err";
      xrpc_error(502, 'UpstreamFailure', $message || 'Upstream service unreachable')
        if $attempt >= $attempts;
      select undef, undef, undef, 0.2 * $attempt;
      next;
    }

    if (my $err = $res->error) {
      if (!$res->code) {
        xrpc_error(502, 'UpstreamFailure', $err->{message} // 'Upstream service unreachable')
          if $attempt >= $attempts;
        select undef, undef, undef, 0.2 * $attempt;
        next;
      }
    }

    $last_res = $res;
    if (($method eq 'GET' || $method eq 'HEAD') && ($res->code // 0) >= 500 && $attempt < $attempts) {
      select undef, undef, undef, 0.2 * $attempt;
      next;
    }
    return $res;
  }

  return $last_res if $last_res;
  xrpc_error(502, 'UpstreamFailure', 'Upstream service unreachable');
}

sub _target_for_request ($self, $c, $nsid) {
  if (my $proxy_to = $c->req->headers->header('Atproto-Proxy')) {
    return $self->_target_from_proxy_header($proxy_to);
  }

  return {
    aud => $self->_config('chat_service_did', 'did:web:api.bsky.chat') . '#' . SERVICE_ID_BSKY_CHAT,
    did => $self->_config('chat_service_did', 'did:web:api.bsky.chat'),
    url => $self->_config('chat_service_url', 'https://api.bsky.chat'),
  } if $nsid =~ /\Achat\.bsky\./;

  return {
    aud => $self->_config('bsky_appview_did', 'did:web:api.bsky.app') . '#' . SERVICE_ID_BSKY_APPVIEW,
    did => $self->_config('bsky_appview_did', 'did:web:api.bsky.app'),
    url => $self->_config('bsky_appview_url', 'https://api.bsky.app'),
  } if $nsid =~ /\Aapp\.bsky\./ || $nsid eq 'com.atproto.moderation.createReport';

  return undef;
}

sub _target_from_proxy_header ($self, $proxy_to) {
  xrpc_error(400, 'InvalidRequest', 'Proxy header cannot contain spaces')
    if $proxy_to =~ /\s/;

  my ($did, $service_id) = $proxy_to =~ /\A([^#]+)#([^#]+)\z/;
  xrpc_error(400, 'InvalidRequest', 'Invalid proxy header format')
    unless defined $did && defined $service_id;

  my $appview_did = $self->_config('bsky_appview_did', 'did:web:api.bsky.app');
  return {
    aud => $proxy_to,
    did => $appview_did,
    url => $self->_config('bsky_appview_url', 'https://api.bsky.app'),
  } if $did eq $appview_did && $service_id eq SERVICE_ID_BSKY_APPVIEW;

  my $chat_did = $self->_config('chat_service_did', 'did:web:api.bsky.chat');
  return {
    aud => $proxy_to,
    did => $chat_did,
    url => $self->_config('chat_service_url', 'https://api.bsky.chat'),
  } if $did eq $chat_did && $service_id eq SERVICE_ID_BSKY_CHAT;

  xrpc_error(400, 'InvalidRequest', "Unsupported proxy target $proxy_to");
}

sub _config ($self, $key, $default) {
  return $self->settings->{$key} // $default;
}

sub _permission_audience_for_request ($self, $c, $nsid) {
  my $target = $self->_target_for_request($c, $nsid);
  return $target ? $target->{aud} : undef;
}

1;
