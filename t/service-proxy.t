use v5.34;
use warnings;

use Config ();
use File::Path qw(remove_tree);
use File::Spec;
use FindBin qw($Bin);
use JSON::PP qw(decode_json);
use MIME::Base64 qw(decode_base64);
use Test::More;
use Time::HiRes qw(sleep);

BEGIN {
  require lib;
  my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
  lib->import(
    File::Spec->catdir($root, 'lib'),
    File::Spec->catdir($root, 'local', 'lib', 'perl5'),
    File::Spec->catdir($root, 'local', 'lib', 'perl5', $Config::Config{archname}),
  );
}

use Crypt::PK::ECC;
use IO::Socket::INET;
use Mojo::Server::Daemon;
use Mojo::URL;
use Mojo::UserAgent;
use Mojo::Util qw(url_unescape);
use Mojolicious;
use Test::Mojo;
use ATProto::PDS;

my @mock_pids;
END {
  my $status = $?;
  kill 'TERM', @mock_pids if @mock_pids;
  waitpid($_, 0) for @mock_pids;
  $? = $status;
}

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $tmp  = File::Spec->catdir($root, 'data', 'tmp-tests', 'service-proxy');
remove_tree($tmp) if -d $tmp;

my $appview_app = Mojolicious->new;
my %appview_seen;
my ($alice_profile, $bob_profile, $alice_did, $bob_did_value, $alice_handle, $bob_handle);
$appview_app->routes->get('/ready')->to(cb => sub {
  my ($c) = @_;
  $c->render(text => 'ok');
});
$appview_app->routes->any('/xrpc/*nsid')->to(cb => sub {
  my ($c) = @_;
  my $nsid = $c->stash('nsid');
  if ($nsid eq 'app.bsky.unspecced.getTrendingTopics' && !$appview_seen{$nsid}++) {
    return $c->render(status => 500, json => {
      error   => 'UpstreamTemporaryFailure',
      message => 'try again',
    });
  }
  if ($nsid eq 'app.bsky.actor.getProfile') {
    my $actor = $c->param('actor') // q();
    my $profile;
    if (
      defined($alice_profile)
      && (
        $actor eq ($alice_did // q())
        || $actor eq url_unescape($alice_did // q())
        || $actor eq ($alice_handle // q())
      )
    ) {
      $profile = $alice_profile;
    }
    elsif (
      defined($bob_profile)
      && (
        $actor eq ($bob_did_value // q())
        || $actor eq url_unescape($bob_did_value // q())
        || $actor eq ($bob_handle // q())
      )
    ) {
      $profile = $bob_profile;
    }
    $profile //= {
      did    => $actor,
      handle => $actor,
    };
    $c->res->headers->header('Cache-Control' => 'public, max-age=30');
    $c->res->headers->header('ETag' => 'W/"profile-mock"');
    return $c->render(json => {
      %$profile,
      auth => $c->req->headers->authorization,
    });
  }
  if ($nsid eq 'app.bsky.actor.getProfiles') {
    $c->res->headers->header('Cache-Control' => 'public, max-age=30');
    $c->res->headers->header('ETag' => 'W/"profiles-mock"');
  }
  my %body = (
    nsid => $nsid,
    auth => $c->req->headers->authorization,
  );
  $body{country} = $c->param('countryCode') if defined $c->param('countryCode');
  $body{region}  = $c->param('regionCode')  if defined $c->param('regionCode');
  if ($nsid eq 'app.bsky.actor.getPreferences') {
    $body{preferences} = [{
      '$type' => 'app.bsky.actor.defs#savedFeedsPref',
      pinned  => [],
      saved   => [],
    }];
  }
  if ($nsid eq 'app.bsky.notification.listNotifications') {
    $body{notifications} = [];
    $body{priority} = JSON::PP::false;
  }
  $c->render(json => \%body);
});

my $chat_app = Mojolicious->new;
$chat_app->routes->get('/ready')->to(cb => sub {
  my ($c) = @_;
  $c->render(text => 'ok');
});
$chat_app->routes->any('/xrpc/*nsid')->to(cb => sub {
  my ($c) = @_;
  $c->render(json => {
    nsid => $c->stash('nsid'),
    auth => $c->req->headers->authorization,
    logs => [],
  });
});

my $appview_url = _start_mock_server($appview_app);
my $chat_url    = _start_mock_server($chat_app);

my $app = ATProto::PDS->new(
  project_root => $root,
  settings     => {
    base_url              => 'http://127.0.0.1:7755',
    service_did_method    => 'did:web',
    service_handle_domain => 'localhost',
    jwt_secret            => 'proxy-secret',
    data_dir              => $tmp,
    db_path               => File::Spec->catfile($tmp, 'perlsky.sqlite'),
    bsky_appview_url      => $appview_url,
    bsky_appview_did      => 'did:web:appview.test',
    chat_service_url      => $chat_url,
    chat_service_did      => 'did:web:chat.test',
  },
);
my $t = Test::Mojo->new($app);

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'alice',
  email    => 'alice@example.com',
  password => 'password123',
})->status_is(200)
  ->json_has('/accessJwt')
  ->json_has('/did');

my $created = $t->tx->res->json;
my $access  = $created->{accessJwt};
my $did     = $created->{did};
my $account = $app->store->get_account_by_did($did);
my $handle  = $created->{handle};
($alice_did, $alice_handle) = ($did, $handle);
my $upstream_profile = sub {
  my ($did, $handle, $extra) = @_;
  $extra ||= {};
  return {
    did             => $did,
    handle          => $handle,
    associated      => {
      activitySubscription => { allowSubscriptions => 'followers' },
      chat                 => { allowIncoming => 'all' },
    },
    labels          => [],
    createdAt       => '2026-03-10T18:00:00Z',
    indexedAt       => '2026-03-10T18:00:00Z',
    followersCount  => 0,
    followsCount    => 0,
    postsCount      => 0,
    viewer          => {
      muted     => JSON::PP::false,
      blockedBy => JSON::PP::false,
    },
    %$extra,
  };
};
$alice_profile = $upstream_profile->($did, $created->{handle});

$t->post_ok('/xrpc/com.atproto.server.createAccount' => json => {
  handle   => 'bob',
  email    => 'bob@example.com',
  password => 'password123',
})->status_is(200)
  ->json_has('/accessJwt')
  ->json_has('/did');

my $created_bob = $t->tx->res->json;
my $bob_access  = $created_bob->{accessJwt};
my $bob_did     = $created_bob->{did};
($bob_did_value, $bob_handle) = ($bob_did, $created_bob->{handle});
$bob_profile = $upstream_profile->($bob_did, $created_bob->{handle});

$t->get_ok('/xrpc/app.bsky.ageassurance.getState?countryCode=GB&regionCode=ENG')
  ->status_is(200)
  ->json_is('/nsid' => 'app.bsky.ageassurance.getState')
  ->json_is('/country' => 'GB')
  ->json_is('/region' => 'ENG');

ok(!defined($t->tx->res->json->{auth}), 'anonymous appview request does not forward auth');

$t->get_ok('/xrpc/app.bsky.actor.getPreferences' => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/preferences' => []);

$t->post_ok('/xrpc/app.bsky.actor.putPreferences' => {
  Authorization => "Bearer $access",
} => json => {
  preferences => [{
    '$type' => 'app.bsky.actor.defs#savedFeedsPref',
    pinned  => ['at://did:plc:feed/app.bsky.feed.generator/demo'],
    saved   => [],
  }],
})->status_is(200)
  ->content_is(q());

$t->get_ok('/xrpc/app.bsky.actor.getPreferences' => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/preferences/0/$type' => 'app.bsky.actor.defs#savedFeedsPref')
  ->json_is('/preferences/0/pinned/0' => 'at://did:plc:feed/app.bsky.feed.generator/demo');

$t->post_ok('/xrpc/app.bsky.actor.putPreferences' => {
  Authorization => "Bearer $access",
} => json => {
  preferences => [{
    '$type' => 'com.atproto.server.defs#unknown',
  }],
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest');

$t->post_ok('/xrpc/app.bsky.actor.putPreferences' => {
  Authorization => "Bearer $access",
} => json => {
  preferences => [{
    '$type'     => 'app.bsky.actor.defs#personalDetailsPref',
    birthDate   => '1970-01-01T00:00:00.000Z',
  }],
})->status_is(200);

$t->get_ok('/xrpc/app.bsky.actor.getPreferences' => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/preferences/0/$type' => 'app.bsky.actor.defs#personalDetailsPref')
  ->json_is('/preferences/1/$type' => 'app.bsky.actor.defs#declaredAgePref')
  ->json_is('/preferences/1/isOverAge18' => JSON::PP::true);

$t->post_ok('/xrpc/com.atproto.server.createAppPassword' => {
  Authorization => "Bearer $access",
} => json => {
  name => 'prefs-device',
})->status_is(200)
  ->json_has('/password');

my $prefs_app_password = $t->tx->res->json->{password};

$t->post_ok('/xrpc/com.atproto.server.createSession' => json => {
  identifier => 'alice.localhost',
  password   => $prefs_app_password,
})->status_is(200)
  ->json_has('/accessJwt');

my $prefs_app_access = $t->tx->res->json->{accessJwt};

$t->get_ok('/xrpc/app.bsky.actor.getPreferences' => {
  Authorization => "Bearer $prefs_app_access",
})->status_is(200)
  ->json_is('/preferences/0/$type' => 'app.bsky.actor.defs#declaredAgePref')
  ->json_is('/preferences/0/isOverAge18' => JSON::PP::true);
ok(
  !scalar(grep { ($_->{'$type'} // q()) eq 'app.bsky.actor.defs#personalDetailsPref' } @{ $t->tx->res->json->{preferences} || [] }),
  'app password preference reads hide personalDetailsPref',
);

$t->post_ok('/xrpc/app.bsky.actor.putPreferences' => {
  Authorization => "Bearer $prefs_app_access",
} => json => {
  preferences => [{
    '$type'     => 'app.bsky.actor.defs#personalDetailsPref',
    birthDate   => '1970-01-01T00:00:00.000Z',
  }],
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest');

$t->get_ok('/xrpc/app.bsky.notification.getPreferences' => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/preferences/chat/include' => 'all')
  ->json_is('/preferences/chat/push' => JSON::PP::true)
  ->json_is('/preferences/like/include' => 'all')
  ->json_is('/preferences/like/list' => JSON::PP::true)
  ->json_is('/preferences/verified/list' => JSON::PP::true)
  ->json_is('/preferences/verified/push' => JSON::PP::true);

$t->post_ok('/xrpc/app.bsky.notification.putPreferencesV2' => {
  Authorization => "Bearer $access",
} => json => {
  like => {
    include => 'follows',
    list    => JSON::PP::false,
    push    => JSON::PP::false,
  },
  verified => {
    list => JSON::PP::false,
    push => JSON::PP::false,
  },
})->status_is(200)
  ->json_is('/preferences/like/include' => 'follows')
  ->json_is('/preferences/like/list' => JSON::PP::false)
  ->json_is('/preferences/like/push' => JSON::PP::false)
  ->json_is('/preferences/chat/include' => 'all')
  ->json_is('/preferences/verified/list' => JSON::PP::false)
  ->json_is('/preferences/verified/push' => JSON::PP::false);

$t->post_ok('/xrpc/app.bsky.notification.putPreferencesV2' => {
  Authorization => "Bearer $access",
} => json => {
  mystery => {
    push => JSON::PP::true,
  },
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest');

$t->post_ok('/xrpc/app.bsky.notification.putPreferencesV2' => {
  Authorization => "Bearer $access",
} => json => {
  like => {
    unknown => JSON::PP::true,
  },
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest');

$t->post_ok('/xrpc/app.bsky.notification.putPreferencesV2' => {
  Authorization => "Bearer $access",
} => json => {
  like => {
    include => ['follows'],
  },
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest');

$t->post_ok('/xrpc/app.bsky.notification.putPreferencesV2' => {
  Authorization => "Bearer $access",
} => json => {
  verified => {
    push => 'false',
  },
})->status_is(400)
  ->json_is('/error' => 'InvalidRequest');

$t->get_ok('/xrpc/app.bsky.notification.getPreferences' => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/preferences/like/include' => 'follows')
  ->json_is('/preferences/like/list' => JSON::PP::false)
  ->json_is('/preferences/like/push' => JSON::PP::false)
  ->json_is('/preferences/chat/include' => 'all')
  ->json_is('/preferences/verified/list' => JSON::PP::false)
  ->json_is('/preferences/verified/push' => JSON::PP::false);

$t->get_ok("/xrpc/app.bsky.actor.getProfile?actor=$did" => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/did' => url_unescape($did))
  ->header_is('Cache-Control' => 'public, max-age=30')
  ->header_is('ETag' => 'W/"profile-mock"');
ok($t->tx->res->json->{auth}, 'proxied getProfile forwards bearer auth upstream');

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.graph.follow',
  rkey       => 'follow-bob',
  record     => {
    '$type'   => 'app.bsky.graph.follow',
    subject   => $bob_did,
    createdAt => '2026-03-10T18:00:00Z',
  },
})->status_is(200)
  ->json_is('/uri' => "at://$did/app.bsky.graph.follow/follow-bob");
$alice_profile->{followsCount} = 1;
$bob_profile->{followersCount} = 1;
$bob_profile->{viewer}{following} = "at://$did/app.bsky.graph.follow/follow-bob";

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $bob_access",
} => json => {
  repo       => $bob_did,
  collection => 'app.bsky.graph.follow',
  rkey       => 'follow-alice',
  record     => {
    '$type'   => 'app.bsky.graph.follow',
    subject   => $did,
    createdAt => '2026-03-10T18:01:00Z',
  },
})->status_is(200)
  ->json_is('/uri' => "at://$bob_did/app.bsky.graph.follow/follow-alice");
$bob_profile->{followsCount} = 1;
$alice_profile->{followersCount} = 1;
$alice_profile->{viewer}{followedBy} = "at://$bob_did/app.bsky.graph.follow/follow-alice";
$alice_profile->{viewer}{knownFollowers} = {
  count => 1,
  followers => [
    {
      did    => $bob_did,
      handle => $created_bob->{handle},
    },
  ],
};
$bob_profile->{viewer}{followedBy} = "at://$bob_did/app.bsky.graph.follow/follow-alice";

$t->get_ok("/xrpc/app.bsky.actor.getProfile?actor=$did" => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->header_is('Cache-Control' => 'public, max-age=30')
  ->header_is('ETag' => 'W/"profile-mock"');
ok($t->tx->res->json->{auth}, 'proxied getProfile keeps forwarding auth after follow activity');

$t->get_ok("/xrpc/app.bsky.actor.getProfile?actor=$bob_did" => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->header_is('Cache-Control' => 'public, max-age=30')
  ->header_is('ETag' => 'W/"profile-mock"');
ok($t->tx->res->json->{auth}, 'proxied getProfile works for other local actors too');

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $bob_access",
} => json => {
  repo       => $bob_did,
  collection => 'app.bsky.feed.post',
  rkey       => 'bob-post',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'hello from bob',
    createdAt => '2026-03-10T18:02:00Z',
  },
})->status_is(200)
  ->json_is('/uri' => "at://$bob_did/app.bsky.feed.post/bob-post");

$t->get_ok("/xrpc/app.bsky.feed.getAuthorFeed?actor=$bob_did&limit=10" => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/nsid' => 'app.bsky.feed.getAuthorFeed');
ok($t->tx->res->json->{auth}, 'non-owner author feed proxies upstream instead of synthesizing local appview state');

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'browser-smoke',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'browser smoke post',
    createdAt => '2026-03-10T18:00:00Z',
  },
})->status_is(200)
  ->json_is('/uri' => "at://$did/app.bsky.feed.post/browser-smoke")
  ->json_has('/cid');

my $root_post = $t->tx->res->json;
my $post_uri = $root_post->{uri};

$t->get_ok("/xrpc/app.bsky.actor.getProfile?actor=$did" => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->header_is('Cache-Control' => 'public, max-age=30')
  ->header_is('ETag' => 'W/"profile-mock"');
ok($t->tx->res->json->{auth}, 'proxied getProfile stays available after local posts exist');

$t->get_ok("/xrpc/app.bsky.feed.getAuthorFeed?actor=$did&limit=10" => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/feed/0/post/uri' => $post_uri)
  ->json_is('/feed/0/post/record/text' => 'browser smoke post')
  ->json_is('/feed/0/post/author/associated/chat/allowIncoming' => 'all')
  ->json_is('/feed/0/post/author/associated/activitySubscription/allowSubscriptions' => 'followers')
  ->json_has('/feed/0/post/author/createdAt');
ok(!exists($t->tx->res->json->{feed}[0]{post}{author}{labels}), 'local author view omits non-authoritative labels');
ok(!exists($t->tx->res->json->{feed}[0]{post}{bookmarkCount}), 'local post view omits non-authoritative bookmarkCount');
ok(!exists($t->tx->res->json->{feed}[0]{post}{replyCount}), 'local post view omits non-authoritative replyCount');
ok(!exists($t->tx->res->json->{feed}[0]{post}{likeCount}), 'local post view omits non-authoritative likeCount');

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'quoted-remote',
  record     => {
    '$type' => 'app.bsky.feed.post',
    text    => 'quoted remote post',
    embed   => {
      '$type' => 'app.bsky.embed.record',
      record  => {
        uri => 'at://did:plc:remote/app.bsky.feed.post/quoted',
        cid => 'bafyremote-quoted',
      },
    },
    createdAt => '2026-03-10T18:01:00Z',
  },
})->status_is(200)
  ->json_has('/uri');

my $quoted_remote_uri = $t->tx->res->json->{uri};

$t->get_ok("/xrpc/app.bsky.feed.getAuthorFeed?actor=$did&limit=10" => {
  Authorization => "Bearer $access",
})->status_is(200);
ok(!$t->tx->res->json->{auth}, 'author feed keeps local read-after-write behavior for quoted remote records');
is($t->tx->res->json->{feed}[0]{post}{uri}, $quoted_remote_uri, 'quoted remote post stays visible in the local author feed');
ok(!exists($t->tx->res->json->{feed}[0]{post}{embed}), 'quoted remote post omits a non-authoritative derived embed');

$t->get_ok('/xrpc/app.bsky.feed.getPosts?uris=' . _uri_escape($quoted_remote_uri) => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/posts/0/uri' => $quoted_remote_uri);
ok(!$t->tx->res->json->{auth}, 'getPosts keeps local read-after-write behavior for quoted remote records');
ok(!exists($t->tx->res->json->{posts}[0]{embed}), 'getPosts omits non-authoritative derived embeds for remote quotes');

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.repost',
  rkey       => 'repost-remote',
  record     => {
    '$type'   => 'app.bsky.feed.repost',
    subject   => {
      uri => 'at://did:plc:remote/app.bsky.feed.post/reposted-post',
      cid => 'bafyremote-repost',
    },
    createdAt => '2026-03-10T18:00:30Z',
  },
})->status_is(200)
  ->json_has('/uri');

$t->get_ok("/xrpc/app.bsky.feed.getAuthorFeed?actor=$did&limit=10" => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/nsid' => 'app.bsky.feed.getAuthorFeed');
ok($t->tx->res->json->{auth}, 'author feed proxies upstream when repost records make the local feed incomplete');

$t->get_ok('/xrpc/app.bsky.feed.getPostThread?uri=' . _uri_escape($post_uri) => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/thread/post/uri' => $post_uri)
  ->json_is('/thread/post/record/text' => 'browser smoke post');

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'thread-reply-1',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'thread reply 1',
    reply     => {
      root   => { uri => $root_post->{uri}, cid => $root_post->{cid} },
      parent => { uri => $root_post->{uri}, cid => $root_post->{cid} },
    },
    createdAt => '2026-03-10T18:01:00Z',
  },
})->status_is(200)
  ->json_has('/cid');

my $reply_one = $t->tx->res->json;

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'thread-reply-2',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'thread reply 2',
    reply     => {
      root   => { uri => $root_post->{uri}, cid => $root_post->{cid} },
      parent => { uri => $reply_one->{uri}, cid => $reply_one->{cid} },
    },
    createdAt => '2026-03-10T18:02:00Z',
  },
})->status_is(200)
  ->json_has('/cid');

my $reply_two = $t->tx->res->json;

$t->get_ok('/xrpc/app.bsky.feed.getPostThread?uri=' . _uri_escape($reply_one->{uri}) => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/thread/post/uri' => $reply_one->{uri})
  ->json_is('/thread/parent/post/uri' => $root_post->{uri})
  ->json_is('/thread/replies/0/post/uri' => $reply_two->{uri});

my $reply_thread = $t->tx->res->json;

$t->get_ok('/xrpc/app.bsky.feed.getPostThread?uri=' . _uri_escape($reply_one->{uri}) . '&parentHeight=0' => {
  Authorization => "Bearer $access",
})->status_is(200);
ok(!exists($t->tx->res->json->{thread}{parent}), 'parentHeight=0 omits local parent stitching');

$t->get_ok('/xrpc/app.bsky.feed.getPostThread?uri=' . _uri_escape("at://$handle/app.bsky.feed.post/thread-reply-1") => {
  Authorization => "Bearer $access",
})->status_is(200);
is_deeply($t->tx->res->json, $reply_thread, 'handle-form local post URIs return the same thread payload');

$t->post_ok('/xrpc/com.atproto.repo.createRecord' => {
  Authorization => "Bearer $access",
} => json => {
  repo       => $did,
  collection => 'app.bsky.feed.post',
  rkey       => 'reply-remote-parent',
  record     => {
    '$type'   => 'app.bsky.feed.post',
    text      => 'reply to remote parent',
    reply     => {
      root   => { uri => 'at://did:plc:remote/app.bsky.feed.post/root', cid => 'bafyremote-root' },
      parent => { uri => 'at://did:plc:remote/app.bsky.feed.post/parent', cid => 'bafyremote-parent' },
    },
    createdAt => '2026-03-10T18:03:00Z',
  },
})->status_is(200)
  ->json_has('/cid');

my $remote_parent_reply = $t->tx->res->json;

$t->get_ok('/xrpc/app.bsky.feed.getPostThread?uri=' . _uri_escape($remote_parent_reply->{uri}) => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/nsid' => 'app.bsky.feed.getPostThread');
ok($t->tx->res->json->{auth}, 'local thread with remote parent proxies upstream instead of dropping the parent tree');

$t->get_ok('/xrpc/app.bsky.notification.listNotifications?limit=40' => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/notifications' => []);

my $appview_auth = _decode_bearer($t->tx->res->json->{auth});
is($appview_auth->{header}{alg}, 'ES256K', 'appview proxy auth uses ES256K');
is($appview_auth->{claims}{iss}, $did, 'appview proxy auth is issued by the account DID');
is($appview_auth->{claims}{aud}, 'did:web:appview.test', 'appview proxy auth targets the appview DID');
is($appview_auth->{claims}{lxm}, 'app.bsky.notification.listNotifications', 'appview proxy auth binds the proxied method');
ok(_verify_es256k($account->{public_key}, $appview_auth->{signing_input}, $appview_auth->{signature}), 'appview proxy auth signature verifies');

$t->get_ok('/xrpc/chat.bsky.convo.getLog' => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/logs' => [])
  ->json_is('/nsid' => 'chat.bsky.convo.getLog');

my $chat_auth = _decode_bearer($t->tx->res->json->{auth});
is($chat_auth->{claims}{aud}, 'did:web:chat.test', 'chat proxy auth targets the chat DID');
is($chat_auth->{claims}{lxm}, 'chat.bsky.convo.getLog', 'chat proxy auth binds the chat method');
ok(_verify_es256k($account->{public_key}, $chat_auth->{signing_input}, $chat_auth->{signature}), 'chat proxy auth signature verifies');

$t->get_ok('/xrpc/app.bsky.unspecced.getTrendingTopics?limit=14' => {
  Authorization => "Bearer $access",
})->status_is(200)
  ->json_is('/nsid' => 'app.bsky.unspecced.getTrendingTopics');

my $trending_auth = _decode_bearer($t->tx->res->json->{auth});
is($trending_auth->{claims}{aud}, 'did:web:appview.test', 'trending topics retry still targets the appview DID');
is($trending_auth->{claims}{lxm}, 'app.bsky.unspecced.getTrendingTopics', 'trending topics retry binds the proxied method');
ok(_verify_es256k($account->{public_key}, $trending_auth->{signing_input}, $trending_auth->{signature}), 'trending topics retry auth signature verifies');

$t->get_ok('/xrpc/app.bsky.actor.getPreferences' => {
  Authorization   => "Bearer $access",
  'Atproto-Proxy' => 'did:web:appview.test#bsky_appview',
})->status_is(200)
  ->json_is('/preferences/0/$type' => 'app.bsky.actor.defs#personalDetailsPref');

$t->get_ok('/xrpc/example.unsupported.method')
  ->status_is(404)
  ->json_is('/error' => 'UnknownMethod');

done_testing;

sub _decode_bearer {
  my ($header) = @_;
  like($header // q(), qr/\ABearer\s+/, 'upstream request includes bearer auth');
  my ($token) = $header =~ /\ABearer\s+(.+)\z/;
  my ($header_b64, $claims_b64, $sig_b64) = split /\./, $token, 3;
  return {
    header        => decode_json(_b64url_decode($header_b64)),
    claims        => decode_json(_b64url_decode($claims_b64)),
    signature     => _b64url_decode($sig_b64),
    signing_input => "$header_b64.$claims_b64",
  };
}

sub _uri_escape {
  my ($value) = @_;
  $value =~ s/([^A-Za-z0-9\-._~])/sprintf('%%%02X', ord($1))/ge;
  return $value;
}

sub _b64url_decode {
  my ($text) = @_;
  my $copy = $text;
  $copy =~ tr/-_/+\//;
  my $pad = length($copy) % 4;
  $copy .= '=' x (4 - $pad) if $pad;
  return decode_base64($copy);
}

sub _verify_es256k {
  my ($public_key, $message, $signature) = @_;
  my $pk = Crypt::PK::ECC->new;
  $pk->import_key_raw($public_key, 'secp256k1');
  return $pk->verify_message_rfc7518($signature, $message, 'SHA256');
}

sub _start_mock_server {
  my ($mock_app) = @_;
  my $port = _find_free_port();
  my $pid = fork();
  die 'fork failed' unless defined $pid;

  if ($pid == 0) {
    my $daemon = Mojo::Server::Daemon->new(
      app    => $mock_app,
      listen => ["http://127.0.0.1:$port"],
      silent => 1,
    );
    $daemon->run;
    exit 0;
  }

  push @mock_pids, $pid;
  my $url = "http://127.0.0.1:$port";
  _wait_for_ready($url);
  return $url;
}

sub _wait_for_ready {
  my ($base_url) = @_;
  my $ua = Mojo::UserAgent->new(max_redirects => 0);
  for (1 .. 100) {
    my $ok = eval {
      my $tx = $ua->get("$base_url/ready");
      my $res = $tx->result;
      return ($res->code // 0) == 200;
    };
    if ($ok) {
      return 1;
    }
    sleep 0.05;
  }
  die "mock server did not become ready at $base_url";
}

sub _find_free_port {
  my $sock = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Proto     => 'tcp',
    Listen    => 5,
  ) or die "unable to allocate port: $!";
  my $port = $sock->sockport;
  close $sock;
  return $port;
}
