requires 'Mojolicious', '9.39';
requires 'CBOR::XS', '1.86';
requires 'CryptX', '0.087';
requires 'Test::Deep', '1.204';

on 'test' => sub {
  requires 'Test2::Suite', '0.000162';
};
