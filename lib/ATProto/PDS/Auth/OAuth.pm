package ATProto::PDS::Auth::OAuth;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use Mojo::Base -base, -signatures;

use Crypt::PK::ECC;
use Digest::SHA qw(sha256);
use JSON::PP qw(decode_json encode_json);
use Mojo::JSON qw(false true);
use Mojo::URL;
use Mojo::UserAgent;
use Mojo::Util qw(xml_escape);
use ATProto::PDS::API::Helpers qw(find_account verify_login_password);
use ATProto::PDS::API::Util qw(xrpc_error);
use ATProto::PDS::Auth::JWT qw(decode_jwt encode_jwt);
use ATProto::PDS::Auth::OAuthScope qw(
  oauth_expand_scope
  oauth_normalize_scope
  oauth_scope_allows
  oauth_scope_has_atproto
  oauth_required_permission_scope
  oauth_scope_allows_permission
);
use ATProto::PDS::Auth::Password qw(random_hex timing_safe_eq);
use ATProto::PDS::Constants qw(TOKEN_AUD_ACCESS TOKEN_AUD_REFRESH);
use ATProto::PDS::Moderation qw(assert_login_allowed is_repo_takedown);
use ATProto::PDS::Util::BaseX qw(base64url_decode base64url_encode);

our @EXPORT_OK = qw(
  oauth_expand_scope
  oauth_normalize_scope
  oauth_scope_allows
  oauth_scope_allows_permission
  oauth_scope_has_atproto
  oauth_required_permission_scope
);

has settings => sub { {} };
has ua => sub {
  state $ua = Mojo::UserAgent->new;
  $ua->max_redirects(5);
  return $ua;
};

sub protected_resource_metadata ($self) {
  my $resource = $self->_issuer;
  return {
    resource                  => $resource,
    authorization_servers     => [$resource],
    bearer_methods_supported  => ['header'],
    scopes_supported          => [],
    resource_documentation    => 'https://atproto.com',
  };
}

sub authorization_server_metadata ($self) {
  my $issuer = $self->_issuer;
  return {
    issuer                                     => $issuer,
    scopes_supported                           => [
      'atproto',
      'transition:email',
      'transition:generic',
      'transition:chat.bsky',
    ],
    subject_types_supported                    => ['public'],
    authorization_endpoint                     => $issuer . '/oauth/authorize',
    token_endpoint                             => $issuer . '/oauth/token',
    revocation_endpoint                        => $issuer . '/oauth/revoke',
    pushed_authorization_request_endpoint      => $issuer . '/oauth/par',
    jwks_uri                                   => $issuer . '/oauth/jwks',
    response_types_supported                   => ['code'],
    response_modes_supported                   => ['query', 'fragment', 'form_post'],
    grant_types_supported                      => ['authorization_code', 'refresh_token'],
    code_challenge_methods_supported           => ['S256'],
    prompt_values_supported                    => ['none', 'login', 'consent', 'select_account', 'create'],
    token_endpoint_auth_methods_supported      => ['private_key_jwt', 'none'],
    token_endpoint_auth_signing_alg_values_supported => ['ES256'],
    dpop_signing_alg_values_supported          => ['ES256'],
    authorization_response_iss_parameter_supported => true,
    request_parameter_supported                => true,
    request_uri_parameter_supported            => true,
    require_request_uri_registration           => true,
    require_pushed_authorization_requests      => true,
    client_id_metadata_document_supported      => true,
    protected_resources                        => [$issuer],
  };
}

sub jwks ($self) {
  return { keys => [] };
}

sub pushed_authorization_request ($self, $c) {
  my $body = $c->req->body_params->to_hash;
  my $client_id = $body->{client_id} // q();
  return _oauth_json_error($c, 400, 'invalid_request', 'client_id is required')
    unless length $client_id;

  my $client = eval { $self->_load_client_metadata($client_id) };
  return _oauth_json_error($c, 400, 'invalid_client', "$@") if $@;

  my $client_auth = eval {
    $self->_verify_client_auth(
      client => $client,
      body   => $body,
      url    => $self->_issuer . '/oauth/par',
    );
  };
  return _oauth_json_error($c, 401, 'invalid_client', "$@") if $@;

  my $dpop = eval {
    $self->_verify_dpop_proof(
      $c->req->headers->header('DPoP'),
      $c->req->method,
      $self->_request_url_without_query($c),
    );
  };
  return _oauth_json_error($c, 400, 'invalid_dpop_proof', "$@") if $@;

  my $redirect_uri = $body->{redirect_uri} // q();
  my $scope        = oauth_normalize_scope($body->{scope} // q());
  return _oauth_json_error($c, 400, 'invalid_request', 'response_type must be code')
    unless ($body->{response_type} // q()) eq 'code';
  return _oauth_json_error($c, 400, 'invalid_scope', 'scope contains unsupported values')
    unless defined $scope;
  return _oauth_json_error($c, 400, 'invalid_scope', 'scope must include atproto')
    unless oauth_scope_has_atproto($scope);
  my $compiled_scope = eval { $self->_compile_token_scope($c, $scope) };
  return _oauth_json_error($c, 400, 'invalid_scope', "$@") if $@;
  return _oauth_json_error($c, 400, 'invalid_request', 'redirect_uri is required')
    unless length $redirect_uri;
  return _oauth_json_error($c, 400, 'invalid_request', 'redirect_uri is not registered')
    unless grep { $_ eq $redirect_uri } @{ $client->{redirect_uris} // [] };
  return _oauth_json_error($c, 400, 'invalid_request', 'code_challenge is required')
    unless length($body->{code_challenge} // q());
  return _oauth_json_error($c, 400, 'invalid_request', 'code_challenge_method must be S256')
    unless ($body->{code_challenge_method} // q()) eq 'S256';

  if (defined($body->{resource}) && length($body->{resource}) && ($body->{resource} ne $self->_issuer)) {
    return _oauth_json_error($c, 400, 'invalid_target', 'resource is not supported');
  }

  my $request_uri = 'urn:ietf:params:oauth:request_uri:' . random_hex(24);
  my $expires_at  = time + 600;
  $c->store->create_oauth_request(
    id               => random_hex(12),
    request_uri      => $request_uri,
    client_id        => $client_id,
    client_name      => $client->{client_name},
    client_uri       => $client->{client_uri},
    redirect_uri     => $redirect_uri,
    scope            => $compiled_scope,
    state            => $body->{state},
    nonce            => $body->{nonce},
    login_hint       => $body->{login_hint},
    prompt           => $body->{prompt},
    code_challenge   => $body->{code_challenge},
    code_challenge_method => $body->{code_challenge_method},
    client_auth_method => $client_auth->{method},
    client_auth_alg    => $client_auth->{alg},
    client_auth_kid    => $client_auth->{kid},
    client_auth_jkt    => $client_auth->{jkt},
    client_assertion_jti => $client_auth->{jti},
    client_assertion_exp => $client_auth->{exp},
    dpop_jkt         => $dpop->{jkt},
    created_at       => time,
    expires_at       => $expires_at,
  );

  $c->res->code(201);
  $c->res->headers->header('Cache-Control' => 'no-store');
  $c->res->headers->header('Pragma'        => 'no-cache');
  $c->render(json => {
    request_uri => $request_uri,
    expires_in  => $expires_at - time,
  });
}

sub render_authorize ($self, $c) {
  my $request_uri = $c->param('request_uri') // q();
  my $request = $c->store->get_oauth_request_by_request_uri($request_uri);
  return _render_authorize_error($c, 400, 'invalid_request', 'authorization request was not found')
    unless $request;
  return _render_authorize_error($c, 400, 'invalid_request', 'authorization request has expired')
    if ($request->{expires_at} // 0) < time;

  my $identifier = $c->param('identifier') // ($request->{login_hint} // q());
  return $c->render(
    status => 200,
    format => 'html',
    data   => _authorize_html(
      request    => $request,
      identifier => $identifier,
      error      => $c->param('error'),
      issuer     => $self->_issuer,
    ),
  );
}

sub submit_authorize ($self, $c) {
  my $body = $c->req->body_params->to_hash;
  my $request_uri = $body->{request_uri} // q();
  my $request = $c->store->get_oauth_request_by_request_uri($request_uri);
  return _render_authorize_error($c, 400, 'invalid_request', 'authorization request was not found')
    unless $request;
  return _render_authorize_error($c, 400, 'invalid_request', 'authorization request has expired')
    if ($request->{expires_at} // 0) < time;

  if (($body->{decision} // 'approve') ne 'approve') {
    return $c->redirect_to($self->_authorization_redirect($request, error => 'access_denied'));
  }

  my $identifier = $body->{identifier} // ($request->{login_hint} // q());
  my $account = find_account($c, $identifier);
  my $authn = $account ? verify_login_password($c, $account, $body->{password} // q()) : undef;
  unless ($account && $authn && ($authn->{kind} // q()) eq 'account') {
    return $c->render(
      status => 401,
      format => 'html',
      data   => _authorize_html(
        request    => $request,
        identifier => $identifier,
        error      => 'Invalid identifier or password',
        issuer     => $self->_issuer,
      ),
    );
  }
  if (is_repo_takedown($c, $account->{did})) {
    return $c->render(
      status => 401,
      format => 'html',
      data   => _authorize_html(
        request    => $request,
        identifier => $identifier,
        error      => 'Invalid identifier or password',
        issuer     => $self->_issuer,
      ),
    );
  }
  assert_login_allowed($c, $account);

  my $grant = $c->store->upsert_oauth_grant(
    did        => $account->{did},
    client_id  => $request->{client_id},
    scope      => $request->{scope},
    created_at => time,
    updated_at => time,
  );

  my $code = random_hex(24);
  $c->store->authorize_oauth_request(
    id             => $request->{id},
    did            => $account->{did},
    grant_id       => $grant->{id},
    code           => $code,
    code_expires_at => time + 60,
  );

  return $c->redirect_to($self->_authorization_redirect($request, code => $code));
}

sub token ($self, $c) {
  my $body = $c->req->body_params->to_hash;
  my $client_id = $body->{client_id} // q();
  return _oauth_json_error($c, 400, 'invalid_request', 'client_id is required')
    unless length $client_id;

  my $client = eval { $self->_load_client_metadata($client_id) };
  return _oauth_json_error($c, 400, 'invalid_client', "$@") if $@;

  my $client_auth = eval {
    $self->_verify_client_auth(
      client => $client,
      body   => $body,
      url    => $self->_issuer . '/oauth/token',
    );
  };
  return _oauth_json_error($c, 401, 'invalid_client', "$@") if $@;

  my $dpop = eval {
    $self->_verify_dpop_proof(
      $c->req->headers->header('DPoP'),
      $c->req->method,
      $self->_request_url_without_query($c),
    );
  };
  return _oauth_json_error($c, 400, 'invalid_dpop_proof', "$@") if $@;

  my $grant_type = $body->{grant_type} // q();
  my $response = eval {
    if ($grant_type eq 'authorization_code') {
      return $self->_exchange_authorization_code($c, $body, $client_auth, $dpop);
    }
    if ($grant_type eq 'refresh_token') {
      return $self->_refresh_token_grant($c, $body, $client_auth, $dpop);
    }
    die 'unsupported grant_type';
  };
  if (my $err = $@) {
    my $message = "$err";
    my ($error, $description) = $message =~ /\A([^:]+):\s*(.+)\z/
      ? ($1, $2)
      : ('invalid_grant', $message);
    return _oauth_json_error($c, $error eq 'invalid_client' ? 401 : 400, $error, $description);
  }

  $c->res->headers->header('Cache-Control' => 'no-store');
  $c->res->headers->header('Pragma'        => 'no-cache');
  $c->render(json => $response);
}

sub revoke ($self, $c) {
  my $body = $c->req->body_params->to_hash;
  my $client_id = $body->{client_id} // q();
  return _oauth_json_error($c, 400, 'invalid_request', 'client_id is required')
    unless length $client_id;

  my $client = eval { $self->_load_client_metadata($client_id) };
  return _oauth_json_error($c, 400, 'invalid_client', "$@") if $@;

  my $client_auth = eval {
    $self->_verify_client_auth(
      client => $client,
      body   => $body,
      url    => $self->_issuer . '/oauth/revoke',
    );
  };
  return _oauth_json_error($c, 401, 'invalid_client', "$@") if $@;

  eval {
    $self->_verify_dpop_proof(
      $c->req->headers->header('DPoP'),
      $c->req->method,
      $self->_request_url_without_query($c),
    );
  };
  return _oauth_json_error($c, 400, 'invalid_dpop_proof', "$@") if $@;

  my $token = $body->{token} // q();
  if (length $token) {
    my $decoded = eval { decode_jwt($token, $self->_jwt_secret, allow_expired => 1) };
    if ($decoded) {
      my $claims = $decoded->{claims};
      my $session = $c->store->get_session($claims->{jti} // q());
      if ($session && ($session->{kind} // q()) eq 'oauth' && ($session->{client_id} // q()) eq $client_id) {
        _revoke_session_chain($c, $session);
      }
    }
  }

  $c->res->headers->header('Cache-Control' => 'no-store');
  $c->res->headers->header('Pragma'        => 'no-cache');
  $c->render(json => {});
}

sub authenticate_oauth_access_token ($self, $c, $token, %opts) {
  my $decoded = eval { decode_jwt($token, $self->_jwt_secret) };
  if (my $err = $@) {
    my ($code, $safe_message) = _jwt_decode_error("$err");
    xrpc_error(401, $code, $safe_message);
  }

  my $claims = $decoded->{claims};
  xrpc_error(401, 'InvalidToken', 'Unexpected token audience')
    unless ($claims->{aud} // q()) eq ($opts{audience} // TOKEN_AUD_ACCESS);
  xrpc_error(401, 'InvalidToken', 'Unexpected token type')
    unless ($claims->{typ} // q()) eq 'oauth_access';

  my $session_id = $claims->{jti} // q();
  xrpc_error(401, 'InvalidToken', 'Token is missing a session identifier')
    unless length $session_id;

  my $session = $c->store->get_session($session_id);
  xrpc_error(401, 'InvalidToken', 'Token session was not found') unless $session;
  xrpc_error(401, 'InvalidToken', 'Token session is not OAuth-backed')
    unless ($session->{kind} // q()) eq 'oauth';
  xrpc_error(401, 'ExpiredToken', 'Token session has already been revoked')
    if defined $session->{revoked_at};
  xrpc_error(401, 'ExpiredToken', 'Token session has expired')
    if defined($session->{expires_at}) && $session->{expires_at} < time;
  xrpc_error(401, 'InvalidToken', 'Token session did not match token subject')
    unless ($session->{did} // q()) eq ($claims->{sub} // q());

  my $cnf = $claims->{cnf};
  xrpc_error(401, 'InvalidToken', 'Token is missing confirmation key')
    unless ref($cnf) eq 'HASH' && length($cnf->{jkt} // q());
  xrpc_error(401, 'InvalidToken', 'Token confirmation key did not match session binding')
    unless ($session->{dpop_jkt} // q()) eq ($cnf->{jkt} // q());

  my $proof = eval {
    $self->_verify_dpop_proof(
      $c->req->headers->header('DPoP'),
      $c->req->method,
      $self->_request_url_without_query($c),
      access_token => $token,
      expected_jkt => $cnf->{jkt},
    );
  };
  if (my $err = $@) {
    my $message = "$err";
    $message =~ s/\s+at\s+\S+\s+line\s+\d+\.?\n?\z//;
    xrpc_error(401, 'InvalidToken', $message);
  }

  my $scope = oauth_normalize_scope($claims->{scope} // $session->{scope});
  if ($opts{disallow_oauth}) {
    xrpc_error(403, 'Forbidden', 'OAuth credentials are not supported for this endpoint');
  }
  if ($opts{required_scope} && !oauth_scope_allows($scope, $opts{required_scope})) {
    xrpc_error(400, 'InvalidToken', 'Bad token scope');
  }
  if ($opts{required_permission} && !oauth_scope_allows_permission($scope, %{ $opts{required_permission} })) {
    my $needed = oauth_required_permission_scope(%{ $opts{required_permission} });
    xrpc_error(403, 'Forbidden', qq{Missing required scope "$needed"});
  }

  my $account = $c->store->get_account_by_did($claims->{sub});
  xrpc_error(401, 'InvalidToken', 'Token subject no longer exists') unless $account;
  xrpc_error(401, 'InvalidToken', 'Token subject has been deleted') if defined $account->{deleted_at};
  return ($claims, $account, $session, $proof);
}

sub _exchange_authorization_code ($self, $c, $body, $client_auth, $dpop) {
  my $code = $body->{code} // q();
  die 'invalid_grant: code is required' unless length $code;

  my $request = $c->store->get_oauth_request_by_code($code);
  die 'invalid_grant: authorization code was not found' unless $request;
  die 'invalid_grant: authorization code has already been used'
    if defined $request->{consumed_at};
  die 'invalid_grant: authorization code has expired'
    if ($request->{code_expires_at} // 0) < time;
  die 'invalid_grant: authorization code was not approved' unless length($request->{did} // q());
  die 'invalid_grant: client_id did not match authorization request'
    unless ($request->{client_id} // q()) eq ($body->{client_id} // q());
  die 'invalid_grant: redirect_uri did not match authorization request'
    unless ($request->{redirect_uri} // q()) eq ($body->{redirect_uri} // q());
  die 'invalid_grant: client authentication changed during authorization flow'
    unless _client_auth_matches($request, $client_auth);

  my $verifier = $body->{code_verifier} // q();
  die 'invalid_grant: code_verifier is required' unless length $verifier;
  my $challenge = base64url_encode(sha256($verifier));
  die 'invalid_grant: PKCE verification failed'
    unless timing_safe_eq($challenge, $request->{code_challenge} // q());

  my $grant = $c->store->get_oauth_grant($request->{grant_id} // q());
  die 'invalid_grant: authorization grant was not found' unless $grant;
  my $account = $c->store->get_account_by_did($request->{did});
  die 'invalid_grant: authorization subject no longer exists' unless $account;

  my $session = $c->store->create_session(
    did             => $account->{did},
    kind            => 'oauth',
    scope           => $grant->{scope},
    expires_at      => time + (90 * 24 * 60 * 60),
    client_id       => $request->{client_id},
    grant_id        => $grant->{id},
    dpop_jkt        => $dpop->{jkt},
    client_auth_alg => $client_auth->{alg},
    client_auth_kid => $client_auth->{kid},
    client_auth_jkt => $client_auth->{jkt},
  );

  $c->store->consume_oauth_request_code($request->{id});
  return $self->_oauth_token_response($account, $session);
}

sub _refresh_token_grant ($self, $c, $body, $client_auth, $dpop) {
  my $refresh_token = $body->{refresh_token} // q();
  die 'invalid_grant: refresh_token is required' unless length $refresh_token;

  my $decoded = eval { decode_jwt($refresh_token, $self->_jwt_secret) };
  die 'invalid_grant: refresh token is invalid' unless $decoded;

  my $claims = $decoded->{claims};
  die 'invalid_grant: refresh token audience is invalid'
    unless ($claims->{aud} // q()) eq TOKEN_AUD_REFRESH;
  die 'invalid_grant: refresh token type is invalid'
    unless ($claims->{typ} // q()) eq 'oauth_refresh';

  my $session = $c->store->get_session($claims->{jti} // q());
  die 'invalid_grant: refresh token session was not found' unless $session;
  die 'invalid_grant: refresh token session is not OAuth-backed'
    unless ($session->{kind} // q()) eq 'oauth';
  die 'invalid_grant: client_id did not match session'
    unless ($session->{client_id} // q()) eq ($body->{client_id} // q());
  die 'invalid_grant: client authentication did not match session'
    unless _session_client_auth_matches($session, $client_auth);
  die 'invalid_grant: DPoP key changed during refresh'
    unless ($session->{dpop_jkt} // q()) eq ($dpop->{jkt} // q());

  my $rotated = $c->store->rotate_session(
    $session->{id},
    session_ttl      => (90 * 24 * 60 * 60),
    grace_ttl        => 300,
  );
  die 'invalid_grant: refresh token has already been used or revoked' unless $rotated;

  my $account = $c->store->get_account_by_did($rotated->{did});
  die 'invalid_grant: session subject no longer exists' unless $account;
  return $self->_oauth_token_response($account, $rotated);
}

sub _oauth_token_response ($self, $account, $session) {
  my $issuer = $self->_issuer;
  my $secret = $self->_jwt_secret;
  my $now = time;
  my $scope = oauth_normalize_scope($session->{scope});

  my $access_token = encode_jwt({
    iss   => $issuer,
    sub   => $account->{did},
    aud   => TOKEN_AUD_ACCESS,
    typ   => 'oauth_access',
    scope => $scope,
    cnf   => { jkt => $session->{dpop_jkt} },
    jti   => $session->{id},
    exp   => $now + 3600,
  }, $secret);

  my $refresh_token = encode_jwt({
    iss       => $issuer,
    sub       => $account->{did},
    aud       => TOKEN_AUD_REFRESH,
    typ       => 'oauth_refresh',
    scope     => $scope,
    client_id => $session->{client_id},
    jti       => $session->{id},
    exp       => $session->{expires_at} // ($now + (90 * 24 * 60 * 60)),
  }, $secret);

  return {
    access_token  => $access_token,
    token_type    => 'DPoP',
    expires_in    => 3600,
    refresh_token => $refresh_token,
    scope         => $scope,
    sub           => $account->{did},
  };
}

sub _authorization_redirect ($self, $request, %params) {
  my $url = Mojo::URL->new($request->{redirect_uri});
  my %query = map {
    my $value = $params{$_};
    defined($value) && length($value) ? ($_ => $value) : ()
  } sort keys %params;
  $query{state} = $request->{state} if defined($request->{state}) && length($request->{state});
  $query{iss}   = $self->_issuer;
  $url->query(\%query);
  return $url->to_string;
}

sub _load_client_metadata ($self, $client_id) {
  my $url = Mojo::URL->new($client_id);
  die 'client_id must be an absolute URL'
    unless length($url->scheme // q()) && length($url->host // q());
  die 'client_id must use https'
    if lc($url->scheme // q()) ne 'https' && !_is_localhost_url($url);

  my $tx = $self->ua->get($url);
  die 'unable to fetch client metadata' unless $tx->result;
  die 'unable to fetch client metadata'
    if $tx->error || !$tx->result->is_success;
  my $json = $tx->result->json;
  die 'client metadata must be a JSON object' unless ref($json) eq 'HASH';
  die 'client metadata client_id did not match request'
    unless ($json->{client_id} // q()) eq $client_id;
  die 'client metadata must declare code response support'
    unless grep { $_ eq 'code' } @{ $json->{response_types} // [] };
  die 'client metadata must declare authorization_code grant support'
    unless grep { $_ eq 'authorization_code' } @{ $json->{grant_types} // [] };
  die 'client metadata must declare DPoP-bound access tokens'
    unless $json->{dpop_bound_access_tokens};

  my $method = $json->{token_endpoint_auth_method} // 'none';
  die 'unsupported client authentication method'
    unless $method eq 'private_key_jwt' || $method eq 'none';
  if ($method eq 'private_key_jwt') {
    die 'client metadata must provide jwks_uri for private_key_jwt'
      unless length($json->{jwks_uri} // q()) || ref($json->{jwks}) eq 'HASH';
  }

  return $json;
}

sub _verify_client_auth ($self, %args) {
  my $client = $args{client};
  my $body   = $args{body} || {};
  my $method = $client->{token_endpoint_auth_method} // 'none';
  return { method => 'none' } if $method eq 'none';

  my $assertion_type = $body->{client_assertion_type} // q();
  my $assertion = $body->{client_assertion} // q();
  die 'client_assertion is required'
    unless $assertion_type eq 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
      && length $assertion;

  my ($header, $claims, $signing_str, $signature) = _jwt_parts($assertion);
  die 'unsupported client assertion alg' unless ($header->{alg} // q()) eq 'ES256';
  my $jwk = $self->_resolve_client_jwk($client, $header->{kid});
  _verify_es256_signature($jwk, $signing_str, $signature);

  my $client_id = $client->{client_id} // q();
  die 'client assertion subject is invalid' unless ($claims->{sub} // q()) eq $client_id;
  die 'client assertion issuer is invalid' unless ($claims->{iss} // q()) eq $client_id;
  die 'client assertion jti is required' unless length($claims->{jti} // q());
  my $now = time;
  die 'client assertion has expired' if ($claims->{exp} // 0) <= $now;
  my @audiences = ($self->_issuer, $args{url});
  my $aud = $claims->{aud};
  my $aud_ok = ref($aud) eq 'ARRAY'
    ? scalar grep { my $candidate = $_; grep { $candidate eq $_ } @audiences } @$aud
    : scalar grep { defined($aud) && $aud eq $_ } @audiences;
  die 'client assertion audience is invalid' unless $aud_ok;

  return {
    method => 'private_key_jwt',
    alg    => $header->{alg},
    kid    => $header->{kid},
    jkt    => _jwk_thumbprint($jwk),
    jti    => $claims->{jti},
    exp    => $claims->{exp},
  };
}

sub _resolve_client_jwk ($self, $client, $kid = undef) {
  my $jwks = $client->{jwks};
  if (!$jwks && length($client->{jwks_uri} // q())) {
    my $url = Mojo::URL->new($client->{jwks_uri});
    die 'jwks_uri must use https'
      if lc($url->scheme // q()) ne 'https' && !_is_localhost_url($url);
    my $tx = $self->ua->get($url);
    die 'unable to fetch client jwks' unless $tx->result && $tx->result->is_success;
    $jwks = $tx->result->json;
  }
  die 'client jwks must be a JSON object' unless ref($jwks) eq 'HASH';
  my $keys = $jwks->{keys};
  die 'client jwks must contain keys' unless ref($keys) eq 'ARRAY' && @$keys;
  my @matches = defined($kid) && length($kid)
    ? grep { ($_->{kid} // q()) eq $kid } @$keys
    : @$keys;
  die 'client jwk was not found' unless @matches;
  return $matches[0];
}

sub _verify_dpop_proof ($self, $proof, $method, $url, %opts) {
  die 'DPoP proof is required' unless defined $proof && length $proof;
  my ($header, $claims, $signing_str, $signature) = _jwt_parts($proof);
  die 'DPoP proof alg is invalid' unless ($header->{alg} // q()) eq 'ES256';
  die 'DPoP proof typ is invalid' unless lc($header->{typ} // q()) eq 'dpop+jwt';
  die 'DPoP proof must include a JWK' unless ref($header->{jwk}) eq 'HASH';
  _verify_es256_signature($header->{jwk}, $signing_str, $signature);

  my $now = time;
  die 'DPoP proof is expired or too far in the future'
    if abs(($claims->{iat} // 0) - $now) > 300;
  die 'DPoP proof jti is required' unless length($claims->{jti} // q());
  die 'DPoP proof htm did not match request'
    unless uc($claims->{htm} // q()) eq uc($method // q());
  die 'DPoP proof htu did not match request'
    unless ($claims->{htu} // q()) eq $url;

  my $jkt = _jwk_thumbprint($header->{jwk});
  die 'DPoP proof key did not match token binding'
    if defined($opts{expected_jkt}) && ($opts{expected_jkt} // q()) ne $jkt;
  if (defined($opts{access_token})) {
    die 'DPoP proof ath is required' unless length($claims->{ath} // q());
    my $expected_ath = base64url_encode(sha256($opts{access_token}));
    die 'DPoP proof ath did not match token'
      unless timing_safe_eq($expected_ath, $claims->{ath});
  }

  return {
    jkt    => $jkt,
    header => $header,
    claims => $claims,
  };
}

sub _request_url_without_query ($self, $c) {
  my $url = Mojo::URL->new($self->_issuer);
  my $req_url = $c->req->url->clone;
  $url->path($req_url->path->to_string);
  $url->query(undef);
  $url->fragment(undef);
  return $url->to_string;
}

sub _issuer ($self) {
  my $base = $self->settings->{base_url} // 'http://127.0.0.1:7755';
  return Mojo::URL->new($base)->path('')->query(undef)->fragment(undef)->to_string =~ s{/\z}{}r;
}

sub _compile_token_scope ($self, $c, $scope) {
  my $expanded = oauth_expand_scope($scope, sub ($include) {
    return $self->_permission_scopes_for_include($c, $include);
  });
  die 'scope contains unsupported values' unless defined $expanded;
  return $expanded;
}

sub _permission_scopes_for_include ($self, $c, $include) {
  my $permission_set = $self->_load_permission_set($c, $include->{nsid});
  die 'unable to retrieve permission sets'
    unless ref($permission_set) eq 'HASH';

  my $authority = _include_authority($include->{nsid});
  die 'unable to retrieve permission sets'
    unless defined $authority && length $authority;

  my @scopes;
  for my $permission (@{ $permission_set->{permissions} || [] }) {
    next unless ref($permission) eq 'HASH';
    next unless ($permission->{type} // q()) eq 'permission';
    if (($permission->{resource} // q()) eq 'repo') {
      my $scope = _repo_scope_from_permission($authority, $permission);
      push @scopes, $scope if defined $scope;
      next;
    }
    if (($permission->{resource} // q()) eq 'rpc') {
      my $scope = _rpc_scope_from_permission($authority, $include, $permission);
      push @scopes, $scope if defined $scope;
      next;
    }
  }

  return \@scopes;
}

sub _load_permission_set ($self, $c, $nsid) {
  state %cache;
  return $cache{$nsid} if exists $cache{$nsid};

  my $local = $c->app->lexicons->get($nsid);
  if (_is_permission_set_lexicon($local, $nsid)) {
    return $cache{$nsid} = $local->{defs}{main};
  }

  my $authority_handle = _nsid_authority_handle($nsid);
  return $cache{$nsid} = undef unless defined $authority_handle && length $authority_handle;

  my $appview_url = $c->config_value('bsky_appview_url', 'https://api.bsky.app');
  return $cache{$nsid} = undef unless defined $appview_url && length $appview_url;

  my $url = Mojo::URL->new($appview_url)->path('/xrpc/com.atproto.repo.getRecord')->query(
    repo       => $authority_handle,
    collection => 'com.atproto.lexicon.schema',
    rkey       => $nsid,
  );
  my $tx = eval { $self->ua->get($url => { 'Accept-Encoding' => 'identity' }) };
  return $cache{$nsid} = undef if $@ || !$tx;

  my $res = $tx->result;
  return $cache{$nsid} = undef unless $res && $res->is_success;
  my $json = $res->json;
  my $value = ref($json) eq 'HASH' ? $json->{value} : undef;
  return $cache{$nsid} = undef unless _is_permission_set_lexicon($value, $nsid);
  return $cache{$nsid} = $value->{defs}{main};
}

sub _is_permission_set_lexicon ($lexicon, $nsid) {
  return 0 unless ref($lexicon) eq 'HASH';
  return 0 unless ($lexicon->{id} // q()) eq $nsid;
  return 0 unless ref($lexicon->{defs}) eq 'HASH';
  return 0 unless ref($lexicon->{defs}{main}) eq 'HASH';
  return 0 unless ($lexicon->{defs}{main}{type} // q()) eq 'permission-set';
  return 1;
}

sub _repo_scope_from_permission ($authority, $permission) {
  my @collections = _authority_scoped_nsids($authority, $permission->{collection});
  return undef unless @collections;

  my @actions = ref($permission->{action}) eq 'ARRAY'
    ? @{ $permission->{action} }
    : defined($permission->{action}) ? ($permission->{action}) : qw(create update delete);
  my %valid_action = map { $_ => 1 } qw(create update delete);
  return undef if grep { !$valid_action{$_} } @actions;

  my %seen_action;
  @actions = grep { !$seen_action{$_}++ } @actions;
  my %default = map { $_ => 1 } qw(create update delete);
  my $default_actions = @actions == 3 && !grep { !$default{$_} } @actions;

  my $scope = @collections == 1
    ? 'repo:' . $collections[0]
    : do {
        my $params = Mojo::Parameters->new;
        $params->append(collection => $_) for @collections;
        'repo?' . $params->to_string;
      };
  return $scope if $default_actions;

  my $params = Mojo::Parameters->new;
  if ($scope =~ /\?(.+)\z/) {
    $params = Mojo::Parameters->new($1);
    $scope =~ s/\?.+\z//;
  }
  $params->append(action => $_) for sort @actions;
  return $scope . '?' . $params->to_string;
}

sub _rpc_scope_from_permission ($authority, $include, $permission) {
  my @lxm = _authority_scoped_nsids($authority, $permission->{lxm});
  return undef unless @lxm;

  my $aud;
  if ($permission->{inheritAud}) {
    return undef if defined($permission->{aud}) && length($permission->{aud});
    $aud = $include->{aud};
  } else {
    $aud = $permission->{aud};
    return undef unless defined($aud) && length($aud) && $aud eq '*';
  }
  return undef unless defined($aud) && length($aud);
  my $scope = @lxm == 1 ? 'rpc:' . $lxm[0] : 'rpc';
  my $params = Mojo::Parameters->new;
  if (@lxm > 1) {
    $params->append(lxm => $_) for @lxm;
  }
  $params->append(aud => $aud);
  return $scope . '?' . $params->to_string;
}

sub _authority_scoped_nsids ($authority, $value) {
  my @values = ref($value) eq 'ARRAY'
    ? @$value
    : defined($value) ? ($value) : ();
  return grep { _nsid_within_authority($authority, $_) } @values;
}

sub _include_authority ($nsid) {
  return undef unless defined($nsid) && $nsid =~ /\./;
  return $nsid =~ s/\.[^.]+\z//r;
}

sub _nsid_authority_handle ($nsid) {
  my $authority = _include_authority($nsid);
  return undef unless defined $authority && length $authority;
  my @parts = split /\./, $authority;
  return undef unless @parts >= 2;
  return join '.', reverse @parts;
}

sub _nsid_within_authority ($authority, $value) {
  return 0 unless defined($authority) && length($authority);
  return 0 unless defined($value) && length($value);
  return 0 if $value eq '*';
  return 0 unless $value =~ /\A[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+\z/;
  return 0 unless length($value) > length($authority) + 1;
  return $value =~ /\A\Q$authority\E\./ ? 1 : 0;
}

sub _jwt_secret ($self) {
  my $secret = $self->settings->{jwt_secret};
  die 'jwt_secret is not configured'
    unless defined $secret && length $secret;
  die 'jwt_secret is using the legacy dev default'
    if $secret eq 'perlsky-dev-secret';
  return $secret;
}

sub _oauth_json_error ($c, $status, $error, $description) {
  $description =~ s/\s+at\s+\S+\s+line\s+\d+\.?\n?\z//;
  $c->res->code($status);
  $c->res->headers->header('Cache-Control' => 'no-store');
  $c->res->headers->header('Pragma'        => 'no-cache');
  return $c->render(json => {
    error             => $error,
    error_description => $description,
  });
}

sub _render_authorize_error ($c, $status, $error, $description) {
  $c->render(
    status => $status,
    format => 'html',
    data   => qq{<!doctype html><html><body><h1>@{[xml_escape($error)]}</h1><p>@{[xml_escape($description)]}</p></body></html>},
  );
}

sub _authorize_html (%args) {
  my $request    = $args{request};
  my $identifier = xml_escape($args{identifier} // q());
  my $error      = xml_escape($args{error} // q());
  my $client     = xml_escape($request->{client_name} || $request->{client_id});
  my $scopes     = join q{}, map {
    my $scope = xml_escape($_);
    qq{<li><code>$scope</code></li>}
  } grep { length } split /\s+/, ($request->{scope} // q());

  return <<"HTML";
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Authorize $client</title>
    <style>
      body { font-family: sans-serif; max-width: 38rem; margin: 2rem auto; padding: 0 1rem; }
      label { display: block; margin-top: 1rem; font-weight: 600; }
      input { width: 100%; padding: 0.6rem; font: inherit; }
      .error { color: #8b0000; margin: 1rem 0; }
      .actions { margin-top: 1.5rem; display: flex; gap: 0.75rem; }
      button { padding: 0.7rem 1rem; font: inherit; }
      ul { padding-left: 1.25rem; }
    </style>
  </head>
  <body>
    <h1>Authorize $client</h1>
    <p>This application is requesting access to your perlsky account.</p>
    @{[$error ? qq{<p class="error">$error</p>} : q()]}
    <p>Requested scopes:</p>
    <ul>$scopes</ul>
    <form method="post" action="/oauth/authorize">
      <input type="hidden" name="request_uri" value="@{[xml_escape($request->{request_uri})]}">
      <label for="identifier">Handle or email</label>
      <input id="identifier" name="identifier" type="text" autocomplete="username" value="$identifier">
      <label for="password">Password</label>
      <input id="password" name="password" type="password" autocomplete="current-password">
      <div class="actions">
        <button type="submit" name="decision" value="approve">Approve</button>
        <button type="submit" name="decision" value="deny">Deny</button>
      </div>
    </form>
  </body>
</html>
HTML
}

sub _client_auth_matches ($request, $client_auth) {
  return 0 unless ($request->{client_auth_method} // q()) eq ($client_auth->{method} // q());
  return 1 if ($client_auth->{method} // q()) eq 'none';
  return 0 unless ($request->{client_auth_alg} // q()) eq ($client_auth->{alg} // q());
  return 0 unless ($request->{client_auth_kid} // q()) eq ($client_auth->{kid} // q());
  return 0 unless ($request->{client_auth_jkt} // q()) eq ($client_auth->{jkt} // q());
  return 1;
}

sub _session_client_auth_matches ($session, $client_auth) {
  return 0 unless defined($session->{client_auth_alg}) || ($client_auth->{method} // q()) eq 'none';
  return 0 unless ($session->{client_auth_alg} // q()) eq ($client_auth->{alg} // q());
  return 0 unless ($session->{client_auth_kid} // q()) eq ($client_auth->{kid} // q());
  return 0 unless ($session->{client_auth_jkt} // q()) eq ($client_auth->{jkt} // q());
  return 1;
}

sub _revoke_session_chain ($c, $session) {
  my %seen;
  while ($session && !$seen{$session->{id}}++) {
    $c->store->revoke_session($session->{id});
    my $next_id = $session->{next_id} // q();
    last unless length $next_id;
    $session = $c->store->get_session($next_id);
  }
}

sub _jwt_parts ($jwt) {
  my ($header_b64, $claims_b64, $sig_b64) = split /\./, ($jwt // q()), 3;
  die 'token must contain three sections'
    unless defined($header_b64) && defined($claims_b64) && defined($sig_b64);
  my $header = decode_json(base64url_decode($header_b64));
  my $claims = decode_json(base64url_decode($claims_b64));
  my $signature = base64url_decode($sig_b64);
  return ($header, $claims, join('.', $header_b64, $claims_b64), $signature);
}

sub _verify_es256_signature ($jwk, $signing_str, $signature) {
  die 'jwk must be a P-256 EC key'
    unless ref($jwk) eq 'HASH'
      && ($jwk->{kty} // q()) eq 'EC'
      && ($jwk->{crv} // q()) eq 'P-256'
      && defined($jwk->{x})
      && defined($jwk->{y});
  my $public = _p256_public_key_from_jwk($jwk);
  my $pk = Crypt::PK::ECC->new;
  $pk->import_key_raw($public, 'prime256v1');
  die 'signature verification failed'
    unless $pk->verify_message_rfc7518($signature, $signing_str, 'SHA256');
  return 1;
}

sub _p256_public_key_from_jwk ($jwk) {
  my $x = base64url_decode($jwk->{x});
  my $y = base64url_decode($jwk->{y});
  die 'unexpected P-256 coordinate size'
    unless length($x) == 32 && length($y) == 32;
  return "\x04" . $x . $y;
}

sub _jwk_thumbprint ($jwk) {
  my %canonical = (
    crv => $jwk->{crv} // q(),
    kty => $jwk->{kty} // q(),
    x   => $jwk->{x}   // q(),
    y   => $jwk->{y}   // q(),
  );
  my $json = '{' . join(',', map {
    encode_json($_) . ':' . encode_json($canonical{$_})
  } qw(crv kty x y)) . '}';
  return base64url_encode(sha256($json));
}

sub _is_localhost_url ($url) {
  my $host = lc($url->host // q());
  return 1 if $host eq 'localhost';
  return 1 if $host eq '127.0.0.1';
  return 1 if $host eq '::1';
  return 0;
}

sub _jwt_decode_error ($message) {
  return ('ExpiredToken', 'Token has expired')
    if $message =~ /expired/i;
  return ('InvalidToken', 'Token is not yet valid')
    if $message =~ /not yet valid/i;
  return ('InvalidToken', 'Token has an unexpected audience')
    if $message =~ /unexpected audience/i;
  return ('InvalidToken', 'Token has an invalid signature')
    if $message =~ /invalid signature/i;
  return ('InvalidToken', 'Token is malformed')
    if $message =~ /three sections/i;
  return ('InvalidToken', 'Token is invalid');
}

1;
