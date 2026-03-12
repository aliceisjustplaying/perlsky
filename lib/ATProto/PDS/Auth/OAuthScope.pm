package ATProto::PDS::Auth::OAuthScope;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use Mojo::Parameters;
use Mojo::Util qw(url_unescape);

our @EXPORT_OK = qw(
  oauth_expand_scope
  oauth_normalize_scope
  oauth_scope_allows
  oauth_scope_allows_permission
  oauth_scope_has_atproto
  oauth_required_permission_scope
);

my %PARSED_SCOPE_CACHE;
my %NORMALIZED_SCOPE_CACHE;

sub oauth_normalize_scope ($scope) {
  $scope //= q();
  return $NORMALIZED_SCOPE_CACHE{$scope} if exists $NORMALIZED_SCOPE_CACHE{$scope};

  my %seen;
  my @normalized;

  for my $token (grep { length } split /\s+/, $scope) {
    my $normalized = _normalize_scope_token($token);
    return $NORMALIZED_SCOPE_CACHE{$scope} = undef unless defined $normalized;
    next if $seen{$normalized}++;
    push @normalized, $normalized;
  }

  return $NORMALIZED_SCOPE_CACHE{$scope} = join ' ', sort @normalized;
}

sub oauth_scope_has_atproto ($scope) {
  return _parse_scope($scope)->{static}{atproto} ? 1 : 0;
}

sub oauth_expand_scope ($scope, $resolver) {
  my $normalized = oauth_normalize_scope($scope);
  return undef unless defined $normalized;
  return $normalized unless $normalized =~ /\binclude:/;
  return undef unless ref($resolver) eq 'CODE';

  my %seen;
  my @expanded;
  for my $token (grep { length } split /\s+/, $normalized) {
    my $include = _include_scope_from_token($token);
    if ($include) {
      my $scopes = $resolver->($include);
      return undef unless ref($scopes) eq 'ARRAY';
      for my $scope_token (@$scopes) {
        my $normalized_scope = _normalize_scope_token($scope_token);
        return undef unless defined $normalized_scope;
        return undef if _include_scope_from_token($normalized_scope);
        next if $seen{$normalized_scope}++;
        push @expanded, $normalized_scope;
      }
      next;
    }

    next if $seen{$token}++;
    push @expanded, $token;
  }

  return join ' ', sort @expanded;
}

sub oauth_scope_allows ($scope, $required_scope) {
  return 1 if !defined($required_scope) || !length($required_scope);
  my $normalized = oauth_normalize_scope($scope);
  return 0 unless defined $normalized;
  my %granted = map { $_ => 1 } grep { length } split /\s+/, $normalized;
  return $granted{$required_scope} ? 1 : 0;
}

sub oauth_scope_allows_permission ($scope, %required) {
  my $parsed = _parse_scope($scope);
  my $type = $required{type} // q();
  return 0 unless length $type;

  return _allows_account($parsed, %required)  if $type eq 'account';
  return _allows_blob($parsed, %required)     if $type eq 'blob';
  return _allows_identity($parsed, %required) if $type eq 'identity';
  return _allows_repo($parsed, %required)     if $type eq 'repo';
  return _allows_rpc($parsed, %required)      if $type eq 'rpc';
  return 0;
}

sub oauth_required_permission_scope (%required) {
  my $type = $required{type} // q();
  return q() unless length $type;

  return _required_account_scope(%required)  if $type eq 'account';
  return _required_blob_scope(%required)     if $type eq 'blob';
  return _required_identity_scope(%required) if $type eq 'identity';
  return _required_repo_scope(%required)     if $type eq 'repo';
  return _required_rpc_scope(%required)      if $type eq 'rpc';
  return q();
}

sub _normalize_scope_token ($token) {
  return $token if $token eq 'atproto'
    || $token eq 'transition:email'
    || $token eq 'transition:generic'
    || $token eq 'transition:chat.bsky';

  my ($prefix, $positional, $params) = _scope_syntax($token);
  return undef unless defined $prefix;

  if ($prefix eq 'account') {
    my $parsed = _parse_account_scope($positional, $params) or return undef;
    return _format_account_scope($parsed);
  }
  if ($prefix eq 'blob') {
    my $parsed = _parse_blob_scope($positional, $params) or return undef;
    return _format_blob_scope($parsed);
  }
  if ($prefix eq 'identity') {
    my $parsed = _parse_identity_scope($positional, $params) or return undef;
    return _format_identity_scope($parsed);
  }
  if ($prefix eq 'include') {
    my $parsed = _parse_include_scope($positional, $params) or return undef;
    return _format_include_scope($parsed);
  }
  if ($prefix eq 'repo') {
    my $parsed = _parse_repo_scope($positional, $params) or return undef;
    return _format_repo_scope($parsed);
  }
  if ($prefix eq 'rpc') {
    my $parsed = _parse_rpc_scope($positional, $params) or return undef;
    return _format_rpc_scope($parsed);
  }

  return undef;
}

sub _parse_scope ($scope) {
  $scope //= q();
  return $PARSED_SCOPE_CACHE{$scope} if exists $PARSED_SCOPE_CACHE{$scope};

  my $parsed = {
    static   => {},
    account  => [],
    blob     => [],
    include  => [],
    identity => [],
    repo     => [],
    rpc      => [],
  };

  for my $token (grep { length } split /\s+/, $scope) {
    if (
      $token eq 'atproto'
      || $token eq 'transition:email'
      || $token eq 'transition:generic'
      || $token eq 'transition:chat.bsky'
    ) {
      $parsed->{static}{$token} = 1;
      next;
    }

    my ($prefix, $positional, $params) = _scope_syntax($token);
    next unless defined $prefix;

    if ($prefix eq 'account') {
      my $entry = _parse_account_scope($positional, $params);
      push @{ $parsed->{account} }, $entry if $entry;
      next;
    }
    if ($prefix eq 'blob') {
      my $entry = _parse_blob_scope($positional, $params);
      push @{ $parsed->{blob} }, $entry if $entry;
      next;
    }
    if ($prefix eq 'include') {
      my $entry = _parse_include_scope($positional, $params);
      push @{ $parsed->{include} }, $entry if $entry;
      next;
    }
    if ($prefix eq 'identity') {
      my $entry = _parse_identity_scope($positional, $params);
      push @{ $parsed->{identity} }, $entry if $entry;
      next;
    }
    if ($prefix eq 'repo') {
      my $entry = _parse_repo_scope($positional, $params);
      push @{ $parsed->{repo} }, $entry if $entry;
      next;
    }
    if ($prefix eq 'rpc') {
      my $entry = _parse_rpc_scope($positional, $params);
      push @{ $parsed->{rpc} }, $entry if $entry;
      next;
    }
  }

  return $PARSED_SCOPE_CACHE{$scope} = $parsed;
}

sub _scope_syntax ($token) {
  my $param_idx = index($token, '?');
  my $colon_idx = index($token, ':');

  my $prefix_end = -1;
  if ($param_idx >= 0 && $colon_idx >= 0) {
    $prefix_end = $param_idx < $colon_idx ? $param_idx : $colon_idx;
  } elsif ($param_idx >= 0) {
    $prefix_end = $param_idx;
  } elsif ($colon_idx >= 0) {
    $prefix_end = $colon_idx;
  }

  my $prefix = $prefix_end >= 0 ? substr($token, 0, $prefix_end) : $token;
  return unless length $prefix;

  my $positional;
  if ($colon_idx >= 0 && ($param_idx < 0 || $colon_idx < $param_idx)) {
    $positional = $param_idx >= 0
      ? url_unescape(substr($token, $colon_idx + 1, $param_idx - $colon_idx - 1))
      : url_unescape(substr($token, $colon_idx + 1));
  }

  my $params;
  if ($param_idx >= 0 && $param_idx < (length($token) - 1)) {
    $params = Mojo::Parameters->new(substr($token, $param_idx + 1));
  } else {
    $params = Mojo::Parameters->new;
  }

  return ($prefix, $positional, $params);
}

sub _allowed_params ($params, @allowed) {
  my %allowed = map { $_ => 1 } @allowed;
  for my $name (@{ $params->names }) {
    return 0 unless $allowed{$name};
  }
  return 1;
}

sub _single_param ($params, $name) {
  my @values = @{ $params->every_param($name) };
  return undef unless @values;
  return undef if @values > 1;
  return $values[0];
}

sub _multi_param ($params, $name) {
  my @values = @{ $params->every_param($name) };
  return undef unless @values;
  return \@values;
}

sub _parse_account_scope ($positional, $params) {
  return unless defined $positional && length $positional;
  return unless $positional eq 'email' || $positional eq 'repo' || $positional eq 'status';
  return unless _allowed_params($params, 'action');

  my $actions = _multi_param($params, 'action') // ['read'];
  my %valid = map { $_ => 1 } qw(read manage);
  return if grep { !$valid{$_} } @$actions;
  my %wanted = map { $_ => 1 } @$actions;
  my @normalized = grep { $wanted{$_} } qw(manage read);
  @normalized = ('read') unless @normalized;

  return {
    attr   => $positional,
    action => \@normalized,
  };
}

sub _parse_identity_scope ($positional, $params) {
  return unless defined $positional && length $positional;
  return unless $positional eq 'handle' || $positional eq '*';
  return unless _allowed_params($params);
  return {
    attr => $positional,
  };
}

sub _parse_include_scope ($positional, $params) {
  return unless defined $positional && length $positional;
  return unless _is_nsid($positional);
  return unless _allowed_params($params, 'aud');
  my $aud = _single_param($params, 'aud');
  return unless !defined($aud) || _is_atproto_audience($aud);
  return {
    nsid => $positional,
    (defined($aud) ? (aud => $aud) : ()),
  };
}

sub _parse_blob_scope ($positional, $params) {
  return unless _allowed_params($params, 'accept');
  my $accept = defined($positional) ? [$positional] : _multi_param($params, 'accept');
  return unless $accept && @$accept;
  return if grep { !_is_accept($_) } @$accept;

  my %seen;
  my @normalized = grep { !$seen{$_}++ } map { lc $_ } @$accept;
  @normalized = ('*/*') if grep { $_ eq '*/*' } @normalized;
  if (!grep { $_ eq '*/*' } @normalized) {
    my %wildcards = map { $_ => 1 } grep { /\A[^\/]+\/\*\z/ } @normalized;
    @normalized = grep {
      my ($base) = split m{/}, $_, 2;
      !$wildcards{"$base/*"} || $_ eq "$base/*"
    } @normalized;
    @normalized = sort @normalized;
  }

  return {
    accept => \@normalized,
  };
}

sub _parse_repo_scope ($positional, $params) {
  return unless _allowed_params($params, 'collection', 'action');
  return if defined($positional) && defined _single_param($params, 'collection');

  my $collections = defined($positional) ? [$positional] : _multi_param($params, 'collection');
  return unless $collections && @$collections;
  return if grep { !_is_collection($_) } @$collections;

  my $actions = _multi_param($params, 'action') // [qw(create update delete)];
  my %valid_action = map { $_ => 1 } qw(create update delete);
  return if grep { !$valid_action{$_} } @$actions;

  my %collection_seen;
  my @normalized_collections = grep { !$collection_seen{$_}++ } @$collections;
  @normalized_collections = ('*') if grep { $_ eq '*' } @normalized_collections;
  @normalized_collections = sort @normalized_collections unless @normalized_collections == 1 && $normalized_collections[0] eq '*';

  my %action_seen = map { $_ => 1 } @$actions;
  my @normalized_actions = grep { $action_seen{$_} } qw(create update delete);

  return {
    collection => \@normalized_collections,
    action     => \@normalized_actions,
  };
}

sub _parse_rpc_scope ($positional, $params) {
  return unless _allowed_params($params, 'aud', 'lxm');
  return if defined($positional) && defined _multi_param($params, 'lxm');

  my $aud = _single_param($params, 'aud');
  return unless defined($aud) && length($aud);
  return unless $aud eq '*' || $aud !~ /\s/;

  my $lxm = defined($positional) ? [$positional] : _multi_param($params, 'lxm');
  return unless $lxm && @$lxm;
  return if grep { !_is_lxm($_) } @$lxm;
  return if $aud eq '*' && grep { $_ eq '*' } @$lxm;

  my %seen;
  my @normalized_lxm = grep { !$seen{$_}++ } @$lxm;
  @normalized_lxm = ('*') if grep { $_ eq '*' } @normalized_lxm;
  @normalized_lxm = sort @normalized_lxm unless @normalized_lxm == 1 && $normalized_lxm[0] eq '*';

  return {
    aud => $aud,
    lxm => \@normalized_lxm,
  };
}

sub _allows_account ($parsed, %required) {
  my $attr = $required{attr} // q();
  return 0 unless length $attr;
  my $action = $required{action} // 'read';

  return 1
    if $attr eq 'email'
    && $action eq 'read'
    && $parsed->{static}{'transition:email'};

  for my $permission (@{ $parsed->{account} }) {
    next unless $permission->{attr} eq $attr;
    return 1 if grep { $_ eq 'manage' || $_ eq $action } @{ $permission->{action} };
  }
  return 0;
}

sub _allows_identity ($parsed, %required) {
  my $attr = $required{attr} // q();
  return 0 unless length $attr;
  for my $permission (@{ $parsed->{identity} }) {
    return 1 if $permission->{attr} eq '*' || $permission->{attr} eq $attr;
  }
  return 0;
}

sub _allows_blob ($parsed, %required) {
  return 1 if $parsed->{static}{'transition:generic'};

  my $mime = lc($required{mime} // q());
  return 0 unless _is_mime($mime);
  for my $permission (@{ $parsed->{blob} }) {
    return 1 if _matches_any_accept($permission->{accept}, $mime);
  }
  return 0;
}

sub _allows_repo ($parsed, %required) {
  return 1 if $parsed->{static}{'transition:generic'};

  my $collection = $required{collection} // q();
  my $action     = $required{action} // q();
  return 0 unless _is_collection($collection);
  return 0 unless $action eq 'create' || $action eq 'update' || $action eq 'delete';

  for my $permission (@{ $parsed->{repo} }) {
    next unless grep { $_ eq $action } @{ $permission->{action} };
    return 1 if grep { $_ eq '*' || $_ eq $collection } @{ $permission->{collection} };
  }
  return 0;
}

sub _allows_rpc ($parsed, %required) {
  my $aud = $required{aud} // q();
  my $lxm = $required{lxm} // q();
  return 0 unless length($aud) && length($lxm);

  if ($parsed->{static}{'transition:generic'}) {
    return 1 if $lxm eq '*';
    return 1 if $lxm !~ /\Achat\.bsky\./;
  }
  if ($parsed->{static}{'transition:chat.bsky'}) {
    return 1 if $lxm =~ /\Achat\.bsky\./;
  }

  for my $permission (@{ $parsed->{rpc} }) {
    next unless $permission->{aud} eq '*' || $permission->{aud} eq $aud;
    return 1 if grep { $_ eq '*' || $_ eq $lxm } @{ $permission->{lxm} };
  }
  return 0;
}

sub _required_account_scope (%required) {
  my $attr = $required{attr} // q();
  my $action = $required{action} // 'read';
  return q() unless length $attr;
  return "account:$attr" if $action eq 'read';
  return "account:$attr?action=$action";
}

sub _required_identity_scope (%required) {
  my $attr = $required{attr} // q();
  return length($attr) ? "identity:$attr" : q();
}

sub _required_blob_scope (%required) {
  my $mime = lc($required{mime} // q());
  return length($mime) ? "blob:$mime" : q();
}

sub _required_repo_scope (%required) {
  my $collection = $required{collection} // q();
  my $action     = $required{action} // q();
  return q() unless length($collection) && length($action);
  return "repo:$collection?action=$action";
}

sub _required_rpc_scope (%required) {
  my $aud = $required{aud} // q();
  my $lxm = $required{lxm} // q();
  return q() unless length($aud) && length($lxm);
  return "rpc:$lxm?aud=$aud";
}

sub _format_account_scope ($parsed) {
  return "account:$parsed->{attr}"
    if @{ $parsed->{action} } == 1 && $parsed->{action}[0] eq 'read';
  my $params = Mojo::Parameters->new;
  $params->append(action => $_) for @{ $parsed->{action} };
  return "account:$parsed->{attr}?" . $params->to_string;
}

sub _format_blob_scope ($parsed) {
  return 'blob:' . $parsed->{accept}[0]
    if @{ $parsed->{accept} } == 1;
  my $params = Mojo::Parameters->new;
  $params->append(accept => $_) for @{ $parsed->{accept} };
  return 'blob?' . $params->to_string;
}

sub _format_identity_scope ($parsed) {
  return "identity:$parsed->{attr}";
}

sub _format_include_scope ($parsed) {
  my $scope = "include:$parsed->{nsid}";
  return $scope unless defined $parsed->{aud} && length $parsed->{aud};
  my $params = Mojo::Parameters->new;
  $params->append(aud => $parsed->{aud});
  return $scope . '?' . $params->to_string;
}

sub _format_repo_scope ($parsed) {
  my $scope = @{ $parsed->{collection} } == 1
    ? 'repo:' . $parsed->{collection}[0]
    : do {
        my $params = Mojo::Parameters->new;
        $params->append(collection => $_) for @{ $parsed->{collection} };
        'repo?' . $params->to_string;
      };

  my %default = map { $_ => 1 } qw(create update delete);
  my $is_default = @{ $parsed->{action} } == 3
    && !grep { !$default{$_} } @{ $parsed->{action} };
  return $scope if $is_default;

  my $params = Mojo::Parameters->new;
  if ($scope =~ /\?(.+)\z/) {
    $params = Mojo::Parameters->new($1);
    $scope =~ s/\?.+\z//;
  }
  $params->append(action => $_) for @{ $parsed->{action} };
  return $scope . '?' . $params->to_string;
}

sub _format_rpc_scope ($parsed) {
  my $scope = @{ $parsed->{lxm} } == 1
    ? 'rpc:' . $parsed->{lxm}[0]
    : 'rpc';
  my $params = Mojo::Parameters->new;
  if (@{ $parsed->{lxm} } > 1) {
    $params->append(lxm => $_) for @{ $parsed->{lxm} };
  }
  $params->append(aud => $parsed->{aud});
  return $scope . '?' . $params->to_string;
}

sub _is_collection ($value) {
  return 1 if defined($value) && $value eq '*';
  return _is_nsid($value);
}

sub _is_lxm ($value) {
  return 1 if defined($value) && $value eq '*';
  return _is_nsid($value);
}

sub _is_nsid ($value) {
  return 0 unless defined($value) && length($value);
  return $value =~ /\A[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+\z/ ? 1 : 0;
}

sub _is_atproto_audience ($value) {
  return 0 unless defined($value) && length($value);
  return 0 if $value =~ /\s/;
  return $value =~ /\Adid:[a-z0-9]+:[^?#\s]+#[A-Za-z0-9._:-]+\z/i ? 1 : 0;
}

sub _is_accept ($value) {
  return 0 unless defined($value) && length($value);
  return 1 if $value eq '*/*';
  return 1 if $value =~ /\A[^\/\s]+\/\*\z/;
  return _is_mime($value);
}

sub _is_mime ($value) {
  return 0 unless defined($value) && length($value);
  return $value =~ /\A[^\/\s*]+\/[^\/\s*]+\z/ ? 1 : 0;
}

sub _matches_any_accept ($accepts, $mime) {
  for my $accept (@$accepts) {
    return 1 if $accept eq '*/*';
    if ($accept =~ m{\A([^/\s*]+)/\*\z}) {
      my $prefix = $1;
      return 1 if $mime =~ m{\A\Q$prefix\E/};
      next;
    }
    return 1 if $accept eq $mime;
  }
  return 0;
}

sub _include_scope_from_token ($token) {
  my ($prefix, $positional, $params) = _scope_syntax($token);
  return undef unless defined $prefix && $prefix eq 'include';
  return _parse_include_scope($positional, $params);
}

1;
