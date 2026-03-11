package ATProto::PDS::Store::SQLite::Labels;

use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';

use ATProto::PDS::Metrics::Store qw(observe_store_operation);

our @EXPORT_OK = qw(
  put_label
  get_label
  list_labels
);

sub put_label ($self, %args) {
  return observe_store_operation($self->{metrics}, 'put_label', sub {
    my $subject_key = $args{subject_key} // die 'subject_key is required';
    my $src         = $args{src}         // die 'src is required';
    my $uri         = $args{uri}         // die 'uri is required';
    my $val         = $args{val}         // die 'val is required';
    my $now         = $args{created_at}  // time;
    ATProto::PDS::Store::SQLite::_execute_sql(
      $self->dbh,
      q{
        INSERT INTO labels (
          subject_key, src, uri, cid, val, neg, exp, sig, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(subject_key, src, val) DO UPDATE SET
          id = excluded.id,
          uri = excluded.uri,
          cid = excluded.cid,
          neg = excluded.neg,
          exp = excluded.exp,
          sig = excluded.sig,
          created_at = excluded.created_at,
          updated_at = excluded.updated_at
      },
      [
        $subject_key,
        $src,
        $uri,
        $args{cid},
        $val,
        ($args{neg} ? 1 : 0),
        $args{exp},
        $args{sig},
        $now,
        $args{updated_at} // $now,
      ],
      ATProto::PDS::Store::SQLite::_blob_bind_positions_for_names(
        [qw(subject_key src uri cid val neg exp sig created_at updated_at)],
        qw(sig),
      ),
    );
    return $self->get_label(
      subject_key => $subject_key,
      src         => $src,
      val         => $val,
    );
  });
}

sub get_label ($self, %args) {
  return ATProto::PDS::Store::SQLite::_row_from_blob_columns(
    $self->dbh->selectrow_hashref(
      q{
        SELECT * FROM labels
        WHERE subject_key = ? AND src = ? AND val = ?
      },
      undef,
      $args{subject_key},
      $args{src},
      $args{val},
    ),
    qw(sig),
  );
}

sub list_labels ($self, %args) {
  return observe_store_operation($self->{metrics}, 'list_labels', sub {
    my $limit = $args{limit} // 50;
    $limit = 250 if $limit > 250;
    my $cursor = $args{cursor};
    my @where;
    my @bind;
    if (my $sources = $args{sources}) {
      if (@$sources) {
        my $placeholders = join(', ', ('?') x @$sources);
        push @where, "src IN ($placeholders)";
        push @bind, @$sources;
      }
    }
    if (defined $cursor && length $cursor) {
      push @where, q{id > ?};
      push @bind, int($cursor);
    }
    if (my $uri_patterns = $args{uri_patterns}) {
      my ($sql, @sql_bind) = ATProto::PDS::Store::SQLite::_uri_pattern_where($uri_patterns);
      if (defined $sql) {
        push @where, $sql;
        push @bind, @sql_bind;
      }
    }
    my $sql = q{SELECT * FROM labels};
    $sql .= q{ WHERE } . join(q{ AND }, @where) if @where;
    $sql .= q{ ORDER BY id ASC LIMIT ?};
    push @bind, $limit + 1;
    my $rows = $self->dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
    my @items = @$rows;
    my $next_cursor;
    if (@items > $limit) {
      @items = @items[0 .. $limit - 1];
      $next_cursor = $items[-1]{id};
    }
    return {
      items  => [ map { ATProto::PDS::Store::SQLite::_row_from_blob_columns($_, qw(sig)) } @items ],
      cursor => $next_cursor,
    };
  });
}

1;
