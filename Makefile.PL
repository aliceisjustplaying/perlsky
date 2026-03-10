use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'ATProto::PDS',
    VERSION_FROM => 'lib/ATProto/PDS.pm',
    ABSTRACT     => 'Perl 5 implementation of an AT Protocol PDS',
    AUTHOR       => 'aliceisjustplaying',
    EXE_FILES    => ['script/perlds'],
    PREREQ_PM    => {
        'CBOR::XS'    => '1.87',
        'Crypt::PK::Ed25519' => '0',
        'DBD::SQLite' => '1.64',
        'DBI'         => '1.643',
        'Mojolicious' => '9.42',
        'Test::Deep'  => '1.204',
        'Test2::V0'   => '0.000162',
    },
);
