package ATProto::PDS::API::Util;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use JSON::PP ();

our @EXPORT_OK = qw(
  blob_ref
  flatten_params
  iso8601
  resolve_did_account
  resolve_repo
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

sub blob_ref ($cid, $mime_type, $size) {
  return {
    '$type'    => 'blob',
    ref        => { '$link' => $cid },
    mimeType   => $mime_type,
    size       => $size + 0,
  };
}

1;
