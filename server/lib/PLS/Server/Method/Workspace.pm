package PLS::Server::Method::Workspace;

use strict;
use warnings;

use PLS::Server::Request::Workspace::Configuration;
use PLS::Server::Request::Workspace::DidChangeConfiguration;
use PLS::Server::Request::Workspace::DidChangeWatchedFiles;
use PLS::Server::Request::Workspace::ExecuteCommand;

sub get_request
{
    my ($request) = @_;

    my (undef, $method) = split '/', $request->{method};

    if ($method eq 'didChangeConfiguration')
    {
        return PLS::Server::Request::Workspace::DidChangeConfiguration->new($request);
    }
    if ($method eq 'didChangeWatchedFiles')
    {
        return PLS::Server::Request::Workspace::DidChangeWatchedFiles->new($request);
    }
    if ($method eq 'configuration')
    {
        return PLS::Server::Request::Workspace::Configuration->new($request);
    }
    if ($method eq 'executeCommand')
    {
        return PLS::Server::Request::Workspace::ExecuteCommand->new($request);
    }
} ## end sub get_request

1;
