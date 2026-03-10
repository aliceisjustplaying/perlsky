package ATProto::PDS::API::Util;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';

our @EXPORT_OK = qw(xrpc_error iso8601);

sub xrpc_error ($status, $error, $message) {
  die {
    status  => $status,
    error   => $error,
    message => $message,
  };
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

1;
