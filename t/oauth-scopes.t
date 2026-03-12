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

use ATProto::PDS::Auth::OAuthScope qw(
  oauth_normalize_scope
  oauth_scope_allows_permission
  oauth_scope_has_atproto
  oauth_required_permission_scope
);

is(
  oauth_normalize_scope('atproto repo:app.bsky.feed.post?action=create&action=update transition:generic'),
  'atproto repo:app.bsky.feed.post?action=create&action=update transition:generic',
  'normalization preserves supported scope values',
);

ok(oauth_scope_has_atproto('atproto transition:generic'), 'atproto marker is detected');
ok(!oauth_scope_has_atproto('transition:generic'), 'missing atproto marker is detected');

ok(
  oauth_scope_allows_permission('atproto transition:email', type => 'account', attr => 'email', action => 'read'),
  'transition:email allows reading account email',
);
ok(
  !oauth_scope_allows_permission('atproto transition:email', type => 'account', attr => 'email', action => 'manage'),
  'transition:email does not allow managing account email',
);

ok(
  oauth_scope_allows_permission('atproto transition:generic', type => 'repo', collection => 'app.bsky.feed.post', action => 'create'),
  'transition:generic allows repo writes',
);
ok(
  oauth_scope_allows_permission('atproto transition:generic', type => 'blob', mime => 'image/png'),
  'transition:generic allows blob uploads',
);
ok(
  oauth_scope_allows_permission('atproto transition:generic', type => 'rpc', aud => 'did:web:api.bsky.app#bsky_appview', lxm => 'app.bsky.actor.getProfile'),
  'transition:generic allows non-chat rpc calls',
);
ok(
  !oauth_scope_allows_permission('atproto transition:generic', type => 'rpc', aud => 'did:web:api.bsky.chat#bsky_chat', lxm => 'chat.bsky.convo.getMessages'),
  'transition:generic does not allow chat rpc calls',
);
ok(
  oauth_scope_allows_permission('atproto transition:chat.bsky', type => 'rpc', aud => 'did:web:api.bsky.chat#bsky_chat', lxm => 'chat.bsky.convo.getMessages'),
  'transition:chat.bsky allows chat rpc calls',
);

ok(
  oauth_scope_allows_permission('atproto repo:app.bsky.feed.post?action=create', type => 'repo', collection => 'app.bsky.feed.post', action => 'create'),
  'granular repo permission allows the requested create action',
);
ok(
  !oauth_scope_allows_permission('atproto repo:app.bsky.feed.post?action=create', type => 'repo', collection => 'app.bsky.feed.post', action => 'delete'),
  'granular repo permission does not allow a different action',
);

ok(
  oauth_scope_allows_permission('atproto blob:image/*', type => 'blob', mime => 'image/jpeg'),
  'blob wildcard matches image subtype',
);
ok(
  !oauth_scope_allows_permission('atproto blob:image/png', type => 'blob', mime => 'image/jpeg'),
  'blob permission rejects a different mime type',
);

ok(
  oauth_scope_allows_permission('atproto account:email?action=manage', type => 'account', attr => 'email', action => 'read'),
  'account manage implies account read',
);
ok(
  oauth_scope_allows_permission('atproto identity:*', type => 'identity', attr => 'handle'),
  'identity wildcard matches handle updates',
);
ok(
  oauth_scope_allows_permission('atproto rpc:app.bsky.actor.getProfile?aud=did:web:api.bsky.app#bsky_appview', type => 'rpc', aud => 'did:web:api.bsky.app#bsky_appview', lxm => 'app.bsky.actor.getProfile'),
  'rpc permission matches exact audience and lxm',
);
ok(
  oauth_scope_allows_permission('atproto rpc:app.bsky.actor.getProfile?aud=*', type => 'rpc', aud => 'did:web:api.bsky.app#bsky_appview', lxm => 'app.bsky.actor.getProfile'),
  'rpc permission supports wildcard audience',
);
ok(
  !oauth_scope_allows_permission('atproto rpc:app.bsky.actor.getProfile?aud=did:web:api.bsky.app#bsky_appview', type => 'rpc', aud => 'did:web:api.bsky.chat#bsky_chat', lxm => 'app.bsky.actor.getProfile'),
  'rpc permission rejects a different audience',
);

is(
  oauth_required_permission_scope(type => 'rpc', aud => 'did:web:api.bsky.app#bsky_appview', lxm => 'app.bsky.actor.getProfile'),
  'rpc:app.bsky.actor.getProfile?aud=did:web:api.bsky.app#bsky_appview',
  'required rpc scope renders in canonical form',
);

done_testing;
