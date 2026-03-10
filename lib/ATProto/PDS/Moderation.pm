package ATProto::PDS::Moderation;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use JSON::PP ();

use ATProto::PDS::API::Util qw(xrpc_error);
use ATProto::PDS::Auth::JWT qw(decode_jwt);

our @EXPORT_OK = qw(
  assert_blob_readable
  assert_login_allowed
  assert_record_readable
  assert_repo_readable
  assert_repo_writable
  assert_report_allowed
  can_read_private_blob
  current_record_subject
  current_subject_status
  is_blob_takedown
  is_record_takedown
  is_repo_takedown
  parse_at_uri
  subject_key
);

sub subject_key ($subject) {
  return 'repo:' . ($subject->{did} // q())
    if ref($subject) eq 'HASH' && exists $subject->{did} && !exists $subject->{uri} && !exists $subject->{cid};
  return 'record:' . ($subject->{uri} // q())
    if ref($subject) eq 'HASH' && exists $subject->{uri};
  return 'blob:' . ($subject->{did} // q()) . ':' . ($subject->{cid} // q())
    if ref($subject) eq 'HASH' && exists $subject->{did} && exists $subject->{cid};
  xrpc_error(400, 'InvalidRequest', 'Unsupported subject payload');
}

sub parse_at_uri ($uri) {
  return unless defined $uri && $uri =~ m{\Aat://([^/]+)/([^/]+)/([^/?#]+)\z};
  return ($1, $2, $3);
}

sub current_record_subject ($c, $uri) {
  my ($did, $collection, $rkey) = parse_at_uri($uri);
  return undef unless defined $did;
  my $record = $c->store->get_record($did, $collection, $rkey);
  return undef unless $record;
  return {
    uri => $uri,
    cid => $record->{cid},
  };
}

sub current_subject_status ($c, $subject) {
  my $key = subject_key($subject);
  my $status = $c->store->get_subject_status($key);
  return undef unless $status;
  my $current_subject = $status->{subject} || $subject;
  if (exists $subject->{uri}) {
    my $current = current_record_subject($c, $subject->{uri});
    return undef unless $current;
    $current_subject = {
      %{$current},
      ($status->{subject}{'$type'} ? ('$type' => $status->{subject}{'$type'}) : ()),
    };
  }
  return {
    %{$status},
    subject => $current_subject,
  };
}

sub is_repo_takedown ($c, $did) {
  my $status = $c->store->get_subject_status('repo:' . ($did // q()));
  return ($status && $status->{takedown} && $status->{takedown}{applied}) ? 1 : 0;
}

sub is_record_takedown ($c, $uri) {
  my $status = $c->store->get_subject_status('record:' . ($uri // q()));
  return ($status && $status->{takedown} && $status->{takedown}{applied}) ? 1 : 0;
}

sub is_blob_takedown ($c, $did, $cid) {
  my $status = $c->store->get_subject_status('blob:' . ($did // q()) . ':' . ($cid // q()));
  return ($status && $status->{takedown} && $status->{takedown}{applied}) ? 1 : 0;
}

sub assert_login_allowed ($c, $account, %opts) {
  xrpc_error(403, 'AccountDeleted', 'Account has been deleted') if defined $account->{deleted_at};
  if (is_repo_takedown($c, $account->{did}) && !$opts{allow_takedown}) {
    xrpc_error(403, 'AccountTakedown', 'Account has been taken down');
  }
  if (defined $account->{deactivated_at} && !$opts{allow_deactivated}) {
    xrpc_error(403, 'AccountDeactivated', 'Account is deactivated');
  }
  return 1;
}

sub assert_repo_readable ($c, $account, %opts) {
  return 1 unless $account;
  if (is_repo_takedown($c, $account->{did})) {
    xrpc_error(
      $opts{status}  // 404,
      $opts{error}   // 'RepoNotFound',
      $opts{message} // 'Repository was not found',
    );
  }
  return 1;
}

sub assert_record_readable ($c, $uri, %opts) {
  if (is_record_takedown($c, $uri)) {
    xrpc_error(
      $opts{status}  // 404,
      $opts{error}   // 'RecordNotFound',
      $opts{message} // 'Record was not found',
    );
  }
  return 1;
}

sub assert_repo_writable ($c, $account) {
  if (is_repo_takedown($c, $account->{did}) || defined $account->{deactivated_at}) {
    xrpc_error(401, 'InvalidToken', 'Bad token scope');
  }
  return 1;
}

sub can_read_private_blob ($c, $did) {
  my $auth = $c->req->headers->authorization // q();
  return 1 if defined($c->config_value('admin_password')) && length($c->config_value('admin_password'))
    && $auth =~ /\ABearer\s+\Q@{[$c->config_value('admin_password')]}\E\z/;
  return 0 unless $auth =~ /\ABearer\s+(.+)\z/i;
  my $token = $1;
  my $decoded = eval { decode_jwt($token, $c->config_value('jwt_secret', 'perlds-dev-secret')) };
  return 0 unless $decoded && ref($decoded) eq 'HASH';
  my $claims = $decoded->{claims} || {};
  return (($claims->{sub} // q()) eq ($did // q())) ? 1 : 0;
}

sub assert_blob_readable ($c, $account, $blob) {
  my $private_ok = can_read_private_blob($c, $account->{did});
  if ((is_repo_takedown($c, $account->{did}) || is_blob_takedown($c, $account->{did}, $blob->{cid}) || defined $blob->{quarantined_at}) && !$private_ok) {
    xrpc_error(404, 'BlobNotFound', 'Blob was not found');
  }
  return 1;
}

sub assert_report_allowed ($c, $account, $reason_type) {
  return 1 unless is_repo_takedown($c, $account->{did});
  return 1 if ($reason_type // q()) eq 'com.atproto.moderation.defs#reasonAppeal';
  xrpc_error(403, 'InvalidRequest', 'Report not accepted from takendown account');
}

1;
