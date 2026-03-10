package ATProto::PDS::LexiconRegistry;

use strict;
use warnings;

use Mojo::Base -base, -signatures;
use JSON::PP qw(decode_json);
use File::Basename qw(dirname);
use File::Spec;
use Mojo::File qw(path);

has root => sub {
    my $base = dirname(__FILE__);
    return File::Spec->catdir($base, '..', '..', '..', 'share', 'lexicons');
};

has lexicons => sub { {} };

sub new ($class, @args) {
    my $self = $class->SUPER::new(@args);
    $self->_load_lexicons;
    return $self;
}

sub ids ($self) {
    return [ sort keys %{ $self->lexicons } ];
}

sub count ($self) {
    return scalar keys %{ $self->lexicons };
}

sub get ($self, $id) {
    return $self->lexicons->{$id};
}

sub _load_lexicons ($self) {
    my $candidate = File::Spec->catdir($self->root, 'share', 'lexicons');
    my $root = path(-d $candidate ? $candidate : $self->root);
    return unless -d $root;

    for my $file ($root->list_tree->grep(qr/\.json$/)->each) {
        my $json = decode_json($file->slurp);
        next unless ref($json) eq 'HASH' && $json->{id};
        $self->lexicons->{ $json->{id} } = $json;
    }
}

1;
