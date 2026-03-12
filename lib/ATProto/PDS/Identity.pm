package ATProto::PDS::Identity;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use Mojo::URL;
use Mojo::UserAgent;

use ATProto::PDS::PLC qw(account_did_method format_plc_did_doc is_plc_did recommended_did_credentials);

our @EXPORT_OK = qw(
  account_did
  account_did_doc
  account_did_doc_valid_for_service
  did_to_path
  is_valid_handle
  normalize_handle
  resolve_handle_to_did
  service_did
  service_did_doc
  service_host
);

sub service_host ($config_or_url) {
  my $config = _coerce_config($config_or_url);
  state %host_for;
  my $base_url = $config->{base_url} // 'http://127.0.0.1:7755';
  return $host_for{$base_url} ||= do {
    my $url = Mojo::URL->new($base_url);
    my $host = lc($url->host // 'localhost');
    my $scheme = $url->scheme // 'http';
    my $port = $url->port;
    my $default = $scheme eq 'https' ? 443 : 80;
    $host .= ':' . $port if defined $port && $port != $default;
    $host;
  };
}

sub service_did ($config_or_url) {
  my $config = _coerce_config($config_or_url);
  my $method = $config->{service_did_method} // 'did:web';
  die "unsupported service DID method: $method" unless $method eq 'did:web';

  my $host = service_host($config);
  $host =~ s/:/%3A/g;
  return "did:web:$host";
}

sub account_did ($config_or_url, $account_id) {
  die 'account id is required' unless defined $account_id && length $account_id;
  my $config = _coerce_config($config_or_url);
  die 'did:plc accounts must be provisioned through the PLC flow'
    if account_did_method($config) eq 'did:plc';
  my $did = service_did($config_or_url);
  return "$did:users:$account_id";
}

sub account_did_doc ($config_or_url, $account) {
  my $config   = _coerce_config($config_or_url);
  my $base_url = $config->{base_url} // 'http://127.0.0.1:7755';
  my $did      = $account->{did} // account_did($config, $account->{account_id} // $account->{id});
  my $handle   = $account->{handle};

  if (is_plc_did($did)) {
    return $account->{did_doc} if $account->{did_doc};
    return format_plc_did_doc($did, recommended_did_credentials($config, $account))
      if $account->{signing_key_did};
  }

  my %doc = (
    '@context' => ['https://www.w3.org/ns/did/v1'],
    id         => $did,
    service    => [{
      id              => "$did#atproto_pds",
      type            => 'AtprotoPersonalDataServer',
      serviceEndpoint => $base_url,
    }],
  );
  $doc{alsoKnownAs} = ["at://$handle"] if defined $handle && length $handle;
  if (my $multibase = $account->{public_key_multibase}) {
    my $type = ($account->{signing_key_did} // q()) =~ /\Adid:key:/ ? 'EcdsaSecp256k1VerificationKey2019' : 'Multikey';
    if ($type eq 'EcdsaSecp256k1VerificationKey2019') {
      $doc{'@context'} = [
        'https://www.w3.org/ns/did/v1',
        'https://w3id.org/security/suites/secp256k1-2019/v1',
      ];
    }
    $doc{verificationMethod} = [{
      id                 => "$did#atproto",
      type               => $type,
      controller         => $did,
      publicKeyMultibase => $multibase,
    }];
    $doc{assertionMethod} = ["$did#atproto"];
  }
  return \%doc;
}

sub account_did_doc_valid_for_service ($config_or_url, $account) {
  return 0 unless ref($account) eq 'HASH';
  my $config = _coerce_config($config_or_url);
  my $did = $account->{did} // q();
  return 0 unless length $did;

  my $doc = $account->{did_doc} || account_did_doc($config, $account);
  return 0 unless ref($doc) eq 'HASH';

  my ($service) = grep {
    ref($_) eq 'HASH'
      && (
        ($_->{id} // q()) eq "$did#atproto_pds"
        || ($_->{id} // q()) eq '#atproto_pds'
        || ($_->{type} // q()) eq 'AtprotoPersonalDataServer'
      )
  } @{ $doc->{service} || [] };
  return 0 unless $service;
  return 0 unless ($service->{type} // q()) eq 'AtprotoPersonalDataServer';
  return 0 unless ($service->{serviceEndpoint} // q()) eq ($config->{base_url} // 'http://127.0.0.1:7755');

  my $expected_multibase = $account->{public_key_multibase} // q();
  return 1 unless length $expected_multibase;

  my ($verification_method) = grep {
    ref($_) eq 'HASH'
      && (
        (($_->{id} // q()) eq "$did#atproto")
        || (($_->{id} // q()) eq '#atproto')
        || (($_->{publicKeyMultibase} // q()) eq $expected_multibase)
      )
  } @{ $doc->{verificationMethod} || [] };
  return 0 unless $verification_method;
  return 0 unless ($verification_method->{publicKeyMultibase} // q()) eq $expected_multibase;

  my @assertion_methods = @{ $doc->{assertionMethod} || [] };
  if (@assertion_methods) {
    my %assertion_methods = map { ($_ // q()) => 1 } @assertion_methods;
    return 0 unless $assertion_methods{"$did#atproto"} || $assertion_methods{'#atproto'};
  }

  return 1;
}

sub did_to_path ($did) {
  die 'did is required' unless defined $did && length $did;
  die "unsupported DID: $did" unless $did =~ s/\Adid:web://;

  my @parts = split /:/, $did;
  shift @parts;
  return '/.well-known/did.json' unless @parts;
  return '/' . join('/', map { s/%3A/:/gr } @parts) . '/did.json';
}

sub service_did_doc ($config_or_url) {
  my $config = _coerce_config($config_or_url);
  my $did = service_did($config);
  my $base_url = $config->{base_url} // 'http://127.0.0.1:7755';

  return {
    '@context' => ['https://www.w3.org/ns/did/v1'],
    id         => $did,
    service    => [{
      id              => "$did#atproto_pds",
      type            => 'AtprotoPersonalDataServer',
      serviceEndpoint => $base_url,
    }],
  };
}

sub is_valid_handle ($handle, $allowed_domain = undef) {
  return 0 unless defined $handle && length $handle;
  $handle = normalize_handle($handle, $allowed_domain, { no_append => 1 });
  return defined $handle ? 1 : 0;
}

sub normalize_handle ($handle, $allowed_domain = undef, $opts = {}) {
  return undef unless defined $handle && length $handle;

  $handle =~ s/\A@+//;
  $handle = lc $handle;
  $handle .= ".$allowed_domain"
    if defined $allowed_domain && !$opts->{no_append} && $handle !~ /\./;

  return undef if $handle =~ /\A\.|\.\z/;
  return undef if $handle =~ /\.\./;
  return undef unless $handle =~ /\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+\z/;

  if (defined $allowed_domain) {
    my $suffix = lc $allowed_domain;
    return undef unless $handle eq $suffix || $handle =~ /\.\Q$suffix\E\z/;
  }

  return $handle;
}

sub resolve_handle_to_did ($config_or_url, $handle) {
  my $config = _coerce_config($config_or_url);
  my $normalized = normalize_handle($handle, undef, { no_append => 1 });
  return undef unless defined $normalized;

  return _resolve_handle_dns($normalized)
    // _resolve_handle_well_known($normalized);
}

sub _coerce_config ($config_or_url) {
  return $config_or_url if ref($config_or_url) eq 'HASH';
  return {
    base_url           => $config_or_url,
    service_did_method => 'did:web',
  };
}

sub _resolve_handle_dns ($handle) {
  state $resolver = do {
    return undef unless eval { require Net::DNS::Resolver; 1 };
    Net::DNS::Resolver->new;
  };
  return undef unless $resolver;
  my $packet = eval { $resolver->search('_atproto.' . $handle, 'TXT') };
  return undef if $@ || !$packet;

  for my $rr ($packet->answer) {
    next unless ($rr->type // q()) eq 'TXT';
    for my $txt ($rr->txtdata) {
      next unless defined $txt && $txt =~ /\Adid=(did:[^\s]+)\z/i;
      return $1;
    }
  }

  return undef;
}

sub _resolve_handle_well_known ($handle) {
  state $ua = do {
    my $client = Mojo::UserAgent->new(max_redirects => 0);
    $client->request_timeout(15);
    $client->inactivity_timeout(15);
    $client;
  };

  my $url = Mojo::URL->new('https://' . $handle)->path('/.well-known/atproto-did');
  my $tx = eval { $ua->get($url) };
  return undef if $@ || !$tx;

  my $res = eval { $tx->result };
  return undef if $@ || !$res;
  return undef unless ($res->code // 0) == 200;

  my $did = $res->body // q();
  $did =~ s/^\s+|\s+$//g;
  return undef unless $did =~ /\Adid:[^\s]+\z/;
  return $did;
}

1;
