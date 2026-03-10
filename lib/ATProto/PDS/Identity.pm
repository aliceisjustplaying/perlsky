package ATProto::PDS::Identity;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use Mojo::URL;

our @EXPORT_OK = qw(
  account_did
  account_did_doc
  did_to_path
  is_valid_handle
  normalize_handle
  service_did
  service_did_doc
  service_host
);

sub service_host ($config_or_url) {
  my $config = _coerce_config($config_or_url);
  my $url = Mojo::URL->new($config->{base_url} // 'http://127.0.0.1:7755');
  my $host = lc($url->host // 'localhost');
  my $scheme = $url->scheme // 'http';
  my $port = $url->port;
  my $default = $scheme eq 'https' ? 443 : 80;
  $host .= ':' . $port if defined $port && $port != $default;
  return $host;
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
  my $did = service_did($config_or_url);
  return "$did:users:$account_id";
}

sub account_did_doc ($config_or_url, $account) {
  my $config   = _coerce_config($config_or_url);
  my $base_url = $config->{base_url} // 'http://127.0.0.1:7755';
  my $did      = $account->{did} // account_did($config, $account->{account_id} // $account->{id});
  my $handle   = $account->{handle};

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
    $doc{verificationMethod} = [{
      id                 => "$did#atproto",
      type               => 'Multikey',
      controller         => $did,
      publicKeyMultibase => $multibase,
    }];
    $doc{assertionMethod} = ["$did#atproto"];
  }
  return \%doc;
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

sub _coerce_config ($config_or_url) {
  return $config_or_url if ref($config_or_url) eq 'HASH';
  return {
    base_url           => $config_or_url,
    service_did_method => 'did:web',
  };
}

1;
