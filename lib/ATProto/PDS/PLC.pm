package ATProto::PDS::PLC;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use Digest::SHA qw(sha256);
use Mojo::JSON qw(decode_json encode_json);
use Mojo::URL;
use Mojo::UserAgent;
use Mojo::Util qw(url_escape);

use ATProto::PDS::Crypto::Secp256k1 qw(
  public_key_multibase_from_public_key
  sign_compact_low_s
  signing_did_from_private_key
  signing_did_to_public_key_multibase
);
use ATProto::PDS::Repo::CID;
use ATProto::PDS::Repo::DagCbor qw(encode_dag_cbor);
use ATProto::PDS::Util::BaseX qw(base64url_encode encode_base32);

our @EXPORT_OK = qw(
  account_did_method
  create_plc_account
  create_signed_plc_operation
  format_plc_did_doc
  is_plc_did
  plc_rotation_did
  plc_rotation_private_key
  plc_update_handle
  recommended_did_credentials
  refresh_plc_did_doc
  submit_plc_operation
);

sub account_did_method ($config) {
  return $config->{account_did_method} // 'did:web';
}

sub is_plc_did ($did) {
  return defined($did) && $did =~ /\Adid:plc:/ ? 1 : 0;
}

sub plc_rotation_private_key ($config) {
  my $hex = $config->{plc_rotation_private_key_hex}
    // die 'plc_rotation_private_key_hex is required when account_did_method is did:plc';
  return pack('H*', $hex);
}

sub plc_rotation_did ($config) {
  return signing_did_from_private_key(plc_rotation_private_key($config));
}

sub recommended_did_credentials ($config, $account) {
  my @rotation_keys = (plc_rotation_did($config));
  unshift @rotation_keys, $config->{plc_recovery_did_key}
    if defined($config->{plc_recovery_did_key}) && length($config->{plc_recovery_did_key});

  return {
    alsoKnownAs         => ($account->{handle} ? [ 'at://' . $account->{handle} ] : []),
    verificationMethods => {
      atproto => $account->{signing_key_did},
    },
    rotationKeys => \@rotation_keys,
    services     => {
      atproto_pds => {
        type     => 'AtprotoPersonalDataServer',
        endpoint => $config->{base_url},
      },
    },
  };
}

sub create_plc_account ($config, %args) {
  my $credentials = recommended_did_credentials($config, {
    handle          => $args{handle},
    signing_key_did => $args{signing_key_did},
  });

  my %unsigned = (
    type                => 'plc_operation',
    verificationMethods => $credentials->{verificationMethods},
    rotationKeys        => $credentials->{rotationKeys},
    alsoKnownAs         => $credentials->{alsoKnownAs},
    services            => $credentials->{services},
    prev                => undef,
  );

  my $operation = create_signed_plc_operation($config, \%unsigned);
  my $did = _did_for_create_op($operation);
  submit_plc_operation($config, $did, $operation);

  return {
    did       => $did,
    operation => $operation,
    did_doc   => format_plc_did_doc($did, {
      alsoKnownAs         => $operation->{alsoKnownAs},
      verificationMethods => $operation->{verificationMethods},
      services            => $operation->{services},
    }),
  };
}

sub plc_update_handle ($config, $account, $handle) {
  my $last_op = get_last_plc_operation($config, $account->{did});
  my @aka = grep { !defined($_) || $_ !~ /\Aat:\/\// } @{ $last_op->{alsoKnownAs} || [] };
  unshift @aka, 'at://' . $handle;

  my $operation = create_signed_plc_operation($config, {
    type                => 'plc_operation',
    verificationMethods => $last_op->{verificationMethods},
    rotationKeys        => $last_op->{rotationKeys},
    alsoKnownAs         => \@aka,
    services            => $last_op->{services},
    prev                => ATProto::PDS::Repo::CID->for_dag_cbor(encode_dag_cbor($last_op))->to_string,
  });

  submit_plc_operation($config, $account->{did}, $operation);
  return refresh_plc_did_doc($config, $account->{did});
}

sub create_signed_plc_operation ($config, $operation) {
  my %unsigned = %{$operation};
  delete $unsigned{sig};
  my $sig = sign_compact_low_s(plc_rotation_private_key($config), encode_dag_cbor(\%unsigned));
  return {
    %unsigned,
    sig => base64url_encode($sig),
  };
}

sub submit_plc_operation ($config, $did, $operation) {
  my $ua = _plc_ua($config);
  my $tx = $ua->post(
    _plc_endpoint($config, $did) => {
      'Content-Type' => 'application/json',
      Accept         => 'application/json',
    } => json => $operation,
  );
  my $res = $tx->result;
  die 'PLC operation failed: ' . ($res->body || $res->message || 'unknown error')
    unless $res->is_success;
  return 1;
}

sub refresh_plc_did_doc ($config, $did) {
  my $data = fetch_plc_document_data($config, $did);
  return format_plc_did_doc($did, $data);
}

sub fetch_plc_document_data ($config, $did) {
  my $ua = _plc_ua($config);
  my $tx = $ua->get(_plc_endpoint($config, $did, 'data'));
  my $res = $tx->result;
  die 'PLC document lookup failed: ' . ($res->body || $res->message || 'unknown error')
    unless $res->is_success;
  return decode_json($res->body);
}

sub get_last_plc_operation ($config, $did) {
  my $ua = _plc_ua($config);
  my $tx = $ua->get(_plc_endpoint($config, $did, 'log', 'last'));
  my $res = $tx->result;
  die 'PLC operation lookup failed: ' . ($res->body || $res->message || 'unknown error')
    unless $res->is_success;
  return decode_json($res->body);
}

sub format_plc_did_doc ($did, $data) {
  return {
    '@context' => [
      'https://www.w3.org/ns/did/v1',
      'https://w3id.org/security/suites/secp256k1-2019/v1',
    ],
    id                 => $did,
    alsoKnownAs        => $data->{alsoKnownAs} || [],
    verificationMethod => [
      map {
        +{
          id                 => '#' . $_,
          type               => 'EcdsaSecp256k1VerificationKey2019',
          controller         => $did,
          publicKeyMultibase => signing_did_to_public_key_multibase($data->{verificationMethods}{$_}),
        }
      } sort keys %{ $data->{verificationMethods} || {} }
    ],
    service => [
      map {
        +{
          id              => '#' . $_,
          type            => $data->{services}{$_}{type},
          serviceEndpoint => $data->{services}{$_}{endpoint},
        }
      } sort keys %{ $data->{services} || {} }
    ],
  };
}

sub _did_for_create_op ($operation) {
  my $hash = sha256(encode_dag_cbor($operation));
  return 'did:plc:' . substr(encode_base32($hash), 0, 24);
}

sub _plc_url ($config) {
  return $config->{plc_url} // 'https://plc.directory';
}

sub _plc_ua ($config) {
  state %ua_for;
  my $origin = _plc_url($config);
  return $ua_for{$origin} ||= Mojo::UserAgent->new(max_redirects => 0);
}

sub _plc_endpoint ($config, @segments) {
  my $base = Mojo::URL->new(_plc_url($config))->to_string;
  $base =~ s{/+\z}{};
  my $path = join '/', map { url_escape($_, '^A-Za-z0-9\\-._~') } @segments;
  return $base . '/' . $path;
}

1;
