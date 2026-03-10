package ATProto::PDS::Repo::CAR;

use v5.34;
use warnings;

use Exporter 'import';

use ATProto::PDS::Repo::CID;
use ATProto::PDS::Repo::DagCbor qw(decode_dag_cbor encode_dag_cbor);
use ATProto::PDS::Util::BaseX qw(decode_varint encode_varint);

our @EXPORT_OK = qw(read_car write_car);

sub write_car {
  my ($root_cid, $blocks) = @_;
  my $header = encode_dag_cbor({
    version => 1,
    roots   => $root_cid ? [ $root_cid ] : [],
  });

  my $out = encode_varint(length($header)) . $header;
  for my $block (@$blocks) {
    my $payload = $block->{cid}->bytes . $block->{bytes};
    $out .= encode_varint(length($payload)) . $payload;
  }
  return $out;
}

sub read_car {
  my ($bytes) = @_;
  my $offset = 0;

  my ($header_len, $consumed) = decode_varint($bytes, $offset);
  $offset += $consumed;
  my $header = decode_dag_cbor(substr($bytes, $offset, $header_len));
  $offset += $header_len;

  my @blocks;
  while ($offset < length($bytes)) {
    my ($block_len, $block_consumed) = decode_varint($bytes, $offset);
    $offset += $block_consumed;
    my $payload = substr($bytes, $offset, $block_len);
    $offset += $block_len;

    my ($cid, $cid_len) = ATProto::PDS::Repo::CID->from_bytes_with_length($payload);
    my $block_bytes = substr($payload, $cid_len);
    push @blocks, {
      cid   => $cid,
      bytes => $block_bytes,
    };
  }

  return {
    roots  => $header->{roots} || [],
    blocks => \@blocks,
  };
}

1;
