package PLS::Server::Request::TextDocument::DidSave;

use strict;
use warnings;

use parent 'PLS::Server::Request';

use Coro;

use PLS::Parser::Document;
use PLS::Server::Request::Diagnostics::PublishDiagnostics;

=head1 NAME

PLS::Server::Request::TextDocument::DidSave

=head1 DESCRIPTION

This is a notification from the client to the server that
a text document was saved.

=cut

sub service
{
    my ($self, $server) = @_;

    $server->{server_requests}->put(PLS::Server::Request::Diagnostics::PublishDiagnostics->new(uri => $self->{params}{textDocument}{uri}));

    return;
} ## end sub service

1;
