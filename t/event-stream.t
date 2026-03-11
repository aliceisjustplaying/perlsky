use v5.34;
use warnings;

use Config ();
use CBOR::XS ();
use File::Spec;
use FindBin qw($Bin);
use Test::More;

BEGIN {
  require lib;
  my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
  lib->import(
    File::Spec->catdir($root, 'lib'),
    File::Spec->catdir($root, 'local', 'lib', 'perl5'),
    File::Spec->catdir($root, 'local', 'lib', 'perl5', $Config::Config{archname}),
  );
}

use ATProto::PDS::EventStream qw(decode_frame encode_error_frame encode_info_frame encode_message_frame);
use ATProto::PDS::Repo::DagCbor qw(encode_dag_cbor);
use ATProto::PDS::Repo::CID;

my $cid = ATProto::PDS::Repo::CID->for_raw('event-stream');

my $message = encode_message_frame('#commit', {
  seq    => 7,
  commit => $cid,
  repo   => 'did:web:example.test',
});

my $decoded = decode_frame($message);
is($decoded->{header}{op}, 1, 'message frames decode as op=1');
is($decoded->{header}{t}, '#commit', 'message frames preserve the type');
is($decoded->{body}{seq}, 7, 'message frames preserve the body payload');
ok($decoded->{body}{commit}->isa('ATProto::PDS::Repo::CID'), 'CID fields decode as CID objects');
is($decoded->{body}{commit}->to_string, $cid->to_string, 'decoded CID matches the encoded CID');
is($decoded->{consumed}, length($message), 'decode_frame reports the consumed message length');

my $info = decode_frame(encode_info_frame('OutdatedCursor', 'Cursor is too old'));
is($info->{header}{t}, '#info', 'info helpers emit #info frames');
is($info->{body}{name}, 'OutdatedCursor', 'info helpers preserve the info name');
is($info->{body}{message}, 'Cursor is too old', 'info helpers preserve the optional message');

my $error = decode_frame(encode_error_frame('FutureCursor', 'Cursor is too new'));
is($error->{header}{op}, -1, 'error helpers emit error frames');
is($error->{body}{error}, 'FutureCursor', 'error helpers preserve the error name');
is($error->{body}{message}, 'Cursor is too new', 'error helpers preserve the optional message');

my $trailing = decode_frame($message . 'junk');
is($trailing->{consumed}, length($message), 'decode_frame reports only the first frame when trailing bytes remain');
is($trailing->{body}{commit}->to_string, $cid->to_string, 'trailing bytes do not corrupt the decoded frame');

my $truncated_error = do {
  my @warnings;
  local $@;
  local $SIG{__WARN__} = sub { push @warnings, @_ };
  my $error = eval { decode_frame(substr($message, 0, length($message) - 1)); 1 } ? undef : $@;
  is_deeply(\@warnings, [], 'truncated frames fail without decoder warnings');
  $error;
};
ok($truncated_error, 'truncated frames are rejected');

my $invalid_cid_frame = encode_dag_cbor({
  op => 1,
  t  => '#commit',
}) . CBOR::XS::encode_cbor({
  commit => CBOR::XS::tag(42, ''),
  repo   => 'did:web:example.test',
  seq    => 8,
});

my $invalid_cid_error = do {
  my @warnings;
  local $@;
  local $SIG{__WARN__} = sub { push @warnings, @_ };
  my $error = eval { decode_frame($invalid_cid_frame); 1 } ? undef : $@;
  is_deeply(\@warnings, [], 'invalid CID tag payloads fail without decoder warnings');
  $error;
};
like($invalid_cid_error, qr/invalid CID tag payload/, 'invalid CID tag payloads are rejected cleanly');

done_testing;
