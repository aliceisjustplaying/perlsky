use v5.34;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Config ();
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

use ATProto::PDS::Auth::OAuth;
use ATProto::PDS::Repo::CAR qw(write_car);
use ATProto::PDS::Repo::CID;
use ATProto::PDS::Repo::DagCbor qw(encode_dag_cbor);

{
  package OAuthLexiconResolutionTestUA;

  sub new ($class, %args) {
    return bless {
      body  => $args{body},
      calls => [],
    }, $class;
  }

  sub get ($self, $url, @rest) {
    push @{ $self->{calls} }, $url->to_string;
    return bless {
      body => $self->{body},
    }, 'OAuthLexiconResolutionTestTx';
  }

  sub calls ($self) {
    return $self->{calls};
  }
}

{
  package OAuthLexiconResolutionTestTx;

  sub result ($self) {
    return bless {
      body => $self->{body},
    }, 'OAuthLexiconResolutionTestResult';
  }
}

{
  package OAuthLexiconResolutionTestResult;

  sub is_success { return 1 }
  sub body ($self) { return $self->{body} }
}

{
  package OAuthLexiconResolutionTestContext;

  sub new ($class) {
    return bless {}, $class;
  }

  sub app ($self) {
    return bless {}, 'OAuthLexiconResolutionTestApp';
  }
}

{
  package OAuthLexiconResolutionTestApp;

  sub lexicons ($self) {
    return bless {}, 'OAuthLexiconResolutionTestLexicons';
  }
}

{
  package OAuthLexiconResolutionTestLexicons;

  sub get ($self, $nsid) {
    return undef;
  }
}

my $nsid = 'pub.leaflet.authFullPermissions';
my $lexicon = {
  lexicon => 1,
  id      => $nsid,
  defs    => {
    main => {
      type        => 'permission-set',
      permissions => [{
        type       => 'permission',
        resource   => 'rpc',
        inheritAud => 1,
        lxm        => ['pub.leaflet.reader.getSavedFeeds'],
      }],
    },
  },
};

my $bytes = encode_dag_cbor($lexicon);
my $car = write_car(
  undef,
  [{
    cid   => ATProto::PDS::Repo::CID->for_dag_cbor($bytes),
    bytes => $bytes,
  }],
);
my $ua = OAuthLexiconResolutionTestUA->new(body => $car);
my $oauth = ATProto::PDS::Auth::OAuth->new(
  settings => { jwt_secret => 'test-secret' },
  ua       => $ua,
);

{
  no warnings 'redefine';
  local *ATProto::PDS::Auth::OAuth::_resolve_lexicon_authority_did = sub ($self, $loaded_nsid) {
    return 'did:plc:btxrwcaeyodrap5mnjw2fvmz' if $loaded_nsid eq $nsid;
    return undef;
  };
  local *ATProto::PDS::Auth::OAuth::_resolve_remote_did_doc = sub ($self, $did) {
    return {
      id      => $did,
      service => [{
        id              => '#atproto_pds',
        type            => 'AtprotoPersonalDataServer',
        serviceEndpoint => 'https://chanterelle.us-west.host.bsky.network',
      }],
    };
  };

  my $loaded = $oauth->_load_permission_set(OAuthLexiconResolutionTestContext->new, $nsid);
  is(
    $loaded->{type},
    'permission-set',
    'permission set is loaded from the authority PDS sync.getRecord response',
  );
  is_deeply(
    $loaded->{permissions},
    $lexicon->{defs}{main}{permissions},
    'permission-set permissions are preserved',
  );
  is(
    scalar(@{ $ua->calls }),
    1,
    'permission-set loader makes a single remote request',
  );
  like(
    $ua->calls->[0],
    qr{\Ahttps://chanterelle\.us-west\.host\.bsky\.network/xrpc/com\.atproto\.sync\.getRecord\?},
    'loader fetches lexicons from the authority PDS sync.getRecord endpoint',
  );
  like(
    $ua->calls->[0],
    qr{(?:\?|&)did=did%3Aplc%3Abtxrwcaeyodrap5mnjw2fvmz(?:&|\z)},
    'loader queries the authority DID directly instead of an appview repo handle',
  );
}

done_testing;
