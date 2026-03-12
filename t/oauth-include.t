use v5.34;
use warnings;

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
use ATProto::PDS::Auth::OAuthScope qw(oauth_scope_allows_permission);

{
  package OAuthIncludeTestContext;

  sub new {
    my ($class) = @_;
    return bless {}, $class;
  }
}

my $oauth = ATProto::PDS::Auth::OAuth->new(settings => {
  base_url   => 'https://perlsky.example',
  jwt_secret => 'test-secret',
});
my $context = OAuthIncludeTestContext->new;

{
  no warnings 'redefine';
  local *ATProto::PDS::Auth::OAuth::_load_permission_set = sub {
    my (undef, undef, $nsid) = @_;
    return {
      permissions => [
        {
          type       => 'permission',
          resource   => 'rpc',
          inheritAud => 1,
          lxm        => [
            'app.bsky.notification.getPreferences',
            'app.bsky.notification.updateSeen',
            'chat.bsky.convo.getMessages',
          ],
        },
        {
          type       => 'permission',
          resource   => 'repo',
          action     => ['create'],
          collection => [
            'app.bsky.feed.post',
            'com.atproto.server.createSession',
          ],
        },
        {
          type     => 'permission',
          resource => 'blob',
          accept   => ['image/*'],
        },
        {
          type     => 'permission',
          resource => 'identity',
          attr     => 'handle',
        },
        {
          type     => 'permission',
          resource => 'account',
          attr     => 'email',
          action   => 'manage',
        },
      ],
    } if $nsid eq 'app.bsky.authManageNotifications';
    return undef;
  };

  my $compiled = $oauth->_compile_token_scope(
    $context,
    'atproto include:app.bsky.authManageNotifications?aud=did:web:api.bsky.app#bsky_appview',
  );

  like(
    $compiled,
    qr/\Aatproto\b/,
    'compiled include scope preserves the atproto marker',
  );
  ok(
    oauth_scope_allows_permission(
      $compiled,
      type => 'rpc',
      aud  => 'did:web:api.bsky.app#bsky_appview',
      lxm  => 'app.bsky.notification.getPreferences',
    ),
    'compiled scope allows included RPC permissions with inherited audience',
  );
  ok(
    oauth_scope_allows_permission(
      $compiled,
      type       => 'repo',
      action     => 'create',
      collection => 'app.bsky.feed.post',
    ),
    'compiled scope allows included repo permissions under the same authority',
  );
  ok(
    !oauth_scope_allows_permission(
      $compiled,
      type => 'rpc',
      aud  => 'did:web:api.bsky.chat#bsky_chat',
      lxm  => 'chat.bsky.convo.getMessages',
    ),
    'compiled scope drops out-of-authority RPC permissions from permission sets',
  );
  ok(
    !oauth_scope_allows_permission(
      $compiled,
      type       => 'repo',
      action     => 'create',
      collection => 'com.atproto.server.createSession',
    ),
    'compiled scope drops out-of-authority repo permissions from permission sets',
  );
  ok(
    !oauth_scope_allows_permission(
      $compiled,
      type => 'blob',
      mime => 'image/png',
    ),
    'compiled scope ignores blob permissions from permission sets',
  );
  ok(
    !oauth_scope_allows_permission(
      $compiled,
      type => 'identity',
      attr => 'handle',
    ),
    'compiled scope ignores identity permissions from permission sets',
  );
  ok(
    !oauth_scope_allows_permission(
      $compiled,
      type   => 'account',
      attr   => 'email',
      action => 'manage',
    ),
    'compiled scope ignores account permissions from permission sets',
  );
}

done_testing;
