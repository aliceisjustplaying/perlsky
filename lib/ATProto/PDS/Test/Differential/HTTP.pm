package ATProto::PDS::Test::Differential::HTTP;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use MIME::Base64 qw(encode_base64);
use Mojo::URL;
use Mojo::UserAgent;

our @EXPORT_OK = qw(
  admin_auth_header
  auth_header
  get_form
  get_json
  get_json_url
  post_bytes
  post_empty
  post_json
);

sub post_json ($origin, $nsid, $payload, $headers = {}) {
  my $ua = Mojo::UserAgent->new(max_redirects => 0);
  my $tx = $ua->post(
    "$origin/xrpc/$nsid" => {
      'Content-Type' => 'application/json',
      %{$headers},
    } => json => $payload,
  );
  return $tx->result;
}

sub post_empty ($origin, $nsid, $headers = {}) {
  my $ua = Mojo::UserAgent->new(max_redirects => 0);
  my $tx = $ua->post("$origin/xrpc/$nsid" => $headers);
  return $tx->result;
}

sub post_bytes ($origin, $nsid, $bytes, $content_type, $headers = {}) {
  my $ua = Mojo::UserAgent->new(max_redirects => 0);
  my $tx = $ua->post(
    "$origin/xrpc/$nsid" => {
      'Content-Type' => $content_type,
      %{$headers},
    } => $bytes,
  );
  return $tx->result;
}

sub get_form ($origin, $nsid, $query, $headers = {}) {
  my $ua  = Mojo::UserAgent->new(max_redirects => 0);
  my $url = Mojo::URL->new("$origin/xrpc/$nsid")->query($query);
  my $tx  = $ua->get($url => $headers);
  return $tx->result;
}

sub get_json ($origin, $nsid, $query = undef, $headers = {}) {
  return defined $query
    ? get_form($origin, $nsid, $query, $headers)
    : Mojo::UserAgent->new(max_redirects => 0)->get("$origin/xrpc/$nsid" => $headers)->result;
}

sub get_json_url ($url) {
  return Mojo::UserAgent->new(max_redirects => 0)->get($url)->result;
}

sub auth_header ($token) {
  return { Authorization => "Bearer $token" };
}

sub admin_auth_header ($password) {
  return {
    Authorization => 'Basic ' . encode_base64("admin:$password", q()),
  };
}

1;
