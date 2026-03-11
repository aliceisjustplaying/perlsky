package ATProto::PDS::EventStream;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use CBOR::XS ();

use ATProto::PDS::Repo::DagCbor qw(encode_dag_cbor);
use ATProto::PDS::Repo::CID;

our @EXPORT_OK = qw(
  decode_frame
  encode_error_frame
  encode_info_frame
  encode_message_frame
);

sub encode_message_frame ($type, $payload) {
  my $header = {
    op => 1,
    t  => $type,
  };
  return encode_dag_cbor($header) . encode_dag_cbor($payload);
}

sub encode_error_frame ($error, $message = undef) {
  my $header = {
    op => -1,
  };
  my $body = {
    error => $error,
    (defined $message ? (message => $message) : ()),
  };
  return encode_dag_cbor($header) . encode_dag_cbor($body);
}

sub encode_info_frame ($name, $message = undef) {
  return encode_message_frame('#info', {
    name    => $name,
    (defined $message ? (message => $message) : ()),
  });
}

sub decode_frame ($bytes) {
  my $decoder = _frame_decoder();
  my ($header, $header_len) = $decoder->decode_prefix($bytes);
  my ($body, $body_len) = $decoder->decode_prefix(substr($bytes, $header_len));
  return {
    header   => $header,
    body     => $body,
    consumed => $header_len + $body_len,
  };
}

sub _frame_decoder {
  state $decoder = CBOR::XS->new->filter(sub {
    my ($tag, $value) = @_;
    if ($tag == 42 && !ref($value)) {
      my $cid_bytes = substr($value, 1);
      return ATProto::PDS::Repo::CID->from_bytes($cid_bytes);
    }
    return;
  });
  return $decoder;
}

1;
