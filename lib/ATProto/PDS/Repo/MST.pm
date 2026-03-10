package ATProto::PDS::Repo::MST;

use v5.34;
use warnings;

use Digest::SHA qw(sha256);
use Exporter 'import';

use ATProto::PDS::Repo::Bytes;
use ATProto::PDS::Repo::CID;
use ATProto::PDS::Repo::DagCbor qw(encode_dag_cbor);

our @EXPORT_OK = qw(build_mst);

sub build_mst {
  my ($entries) = @_;

  my @items = map {
    +{
      key   => $_,
      cid   => $entries->{$_},
      layer => _leading_zero_pairs($_),
    }
  } sort keys %$entries;

  if (!@items) {
    my $bytes = encode_dag_cbor({ l => undef, e => [] });
    my $cid   = ATProto::PDS::Repo::CID->for_dag_cbor($bytes);
    return {
      root   => $cid,
      blocks => [ { cid => $cid, bytes => $bytes } ],
    };
  }

  my $max_layer = 0;
  for my $item (@items) {
    $max_layer = $item->{layer} if $item->{layer} > $max_layer;
  }

  return _build_node(\@items, $max_layer);
}

sub _build_node {
  my ($items, $layer) = @_;
  my @blocks;

  my @same_indexes = grep { $items->[$_]{layer} == $layer } 0 .. $#$items;
  my $left_cid;
  my @entries;

  if (!@same_indexes) {
    my $child = _build_node($items, $layer - 1);
    push @blocks, @{ $child->{blocks} };
    $left_cid = $child->{root};
  } else {
    my $first = $same_indexes[0];
    if ($first > 0) {
      my $child = _build_node([ @$items[0 .. $first - 1] ], $layer - 1);
      push @blocks, @{ $child->{blocks} };
      $left_cid = $child->{root};
    }

    for my $pos (0 .. $#same_indexes) {
      my $index = $same_indexes[$pos];
      my $next  = $same_indexes[$pos + 1] // scalar(@$items);
      my $right_cid;

      if ($index + 1 < $next) {
        my $child = _build_node([ @$items[$index + 1 .. $next - 1] ], $layer - 1);
        push @blocks, @{ $child->{blocks} };
        $right_cid = $child->{root};
      }

      push @entries, {
        key => $items->[$index]{key},
        v   => $items->[$index]{cid},
        t   => $right_cid,
      };
    }
  }

  my $node = _serialize_node($left_cid, \@entries);
  my $bytes = encode_dag_cbor($node);
  my $cid   = ATProto::PDS::Repo::CID->for_dag_cbor($bytes);
  push @blocks, { cid => $cid, bytes => $bytes };

  return {
    root   => $cid,
    blocks => \@blocks,
  };
}

sub _serialize_node {
  my ($left_cid, $entries) = @_;
  my @compressed;
  my $prev = '';

  for my $entry (@$entries) {
    my $prefix = _common_prefix_len($prev, $entry->{key});
    push @compressed, {
      p => $prefix,
      k => ATProto::PDS::Repo::Bytes->new(substr($entry->{key}, $prefix)),
      v => $entry->{v},
      t => $entry->{t},
    };
    $prev = $entry->{key};
  }

  return {
    l => $left_cid,
    e => \@compressed,
  };
}

sub _common_prefix_len {
  my ($a, $b) = @_;
  my $length = length($a) < length($b) ? length($a) : length($b);
  my $i = 0;
  $i++ while $i < $length && substr($a, $i, 1) eq substr($b, $i, 1);
  return $i;
}

sub _leading_zero_pairs {
  my ($key) = @_;
  my $hash = sha256($key);
  my $zeros = 0;

  for my $byte (unpack('C*', $hash)) {
    $zeros++ if $byte < 64;
    $zeros++ if $byte < 16;
    $zeros++ if $byte < 4;
    if ($byte == 0) {
      $zeros++;
      next;
    }
    last;
  }

  return $zeros;
}

1;
