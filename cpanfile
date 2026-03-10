requires 'CBOR::XS', '1.87';
requires 'CryptX', '0.087';
requires 'DBD::SQLite', '1.64';
requires 'DBI', '1.643';
requires 'Mojolicious', '9.42';
requires 'Test::Deep', '1.204';

on 'test' => sub {
  requires 'Test2::Suite', '0.000162';
};
