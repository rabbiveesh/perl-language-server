package PLS::Server::Response::Completion;

use strict;
use warnings;

use parent q(PLS::Server::Response);
use feature 'state';

use Pod::Functions;
use List::Util;
use Module::CoreList;
use Module::Metadata;
use ExtUtils::Installed;

use PLS::Parser::Document;
use PLS::Parser::PackageSymbols;
use PLS::Parser::Pod;
use PLS::Server::State;

=head1 NAME

PLS::Server::Response::Completion

=head1 DESCRIPTION

This is a message from the server to the client with a list
of completion items for the current location.

=cut

sub new
{
    my ($class, $request) = @_;

    my $self = bless {id => $request->{id}, result => undef}, $class;

    my $document = PLS::Parser::Document->new(uri => $request->{params}{textDocument}{uri}, line => $request->{params}{position}{line});
    return $self if (ref $document ne 'PLS::Parser::Document');

    my ($range, $arrow, $package, $filter) = $document->find_word_under_cursor(@{$request->{params}{position}}{qw(line character)});

    return $self if (ref $range ne 'HASH');

    $range->{start}{line}    = $request->{params}{position}{line};
    $range->{end}{line}      = $request->{params}{position}{line};
    $range->{end}{character} = $request->{params}{position}{character};

    $package =~ s/::$// if (length $package);

    my @results;
    my $full_text = $document->get_full_text();

    my @futures;

    if ($filter =~ /^[\$\@\%]/)
    {
        push @results, @{get_variables($document, $filter, $full_text)};
    }
    else
    {
        unless ($arrow)
        {
            push @results, @{get_packages($document, $full_text)} unless $arrow;
            push @results, @{get_keywords()}                      unless $arrow;
        }

        if ($package)
        {
            push @futures, get_package_functions($package, $filter, $arrow);
        }

        if ($filter)
        {
            push @results, @{get_constants($document, $filter, $full_text)};
            push @futures, get_imported_package_functions($document, $full_text);
            push @results, @{get_subroutines($document, $arrow, $full_text)};
        } ## end if ($filter)
    } ## end else [ if ($filter =~ /^[\$\@\%]/...)]

    push @results, @{Future->wait_all(@futures)->then(
            sub {
                [map { @{$_->result} } grep { $_->is_ready } @_]
            }
          )->get()
    };

    foreach my $result (@results)
    {
        my $new_text = $result->{label};
        $new_text = $result->{insertText} if (length $result->{insertText});
        delete $result->{insertText};

        push @{$self->{result}}, {%$result, textEdit => {newText => $new_text, range => $range}};
    } ## end foreach my $result (@results...)

    if (not $arrow and not $package and $filter !~ /^\%\@/)
    {
        push @{$self->{result}}, get_snippets();
    }

    return $self;
} ## end sub new

sub get_keywords
{
    state @keywords;

    return \@keywords if (scalar @keywords);

    my %seen_keywords;

    foreach my $family (keys %Pod::Functions::Kinds)
    {
        foreach my $sub (@{$Pod::Functions::Kinds{$family}})
        {
            next if $sub =~ /\s+/;
            next if $seen_keywords{$sub}++;
            push @keywords, {label => $sub, kind => 14};
        } ## end foreach my $sub (@{$Pod::Functions::Kinds...})
    } ## end foreach my $family (keys %Pod::Functions::Kinds...)

    foreach my $keyword (
        qw(cmp continue default do else elsif eq for foreach ge given gt if le lock lt ne not or package sub unless until when while x xor -r -w -x -o -R -W -X -O -e -z -s -f -d -l -p -S -b -c -t -u -g -k -T -B -M -A -C)
      )
    {
        next if $seen_keywords{$keyword}++;
        push @keywords, {label => $keyword, kind => 14};
    } ## end foreach my $keyword (...)

    return \@keywords;
} ## end sub get_keywords

sub get_ext_modules
{
    # Can use state here, external modules unlikely to change.
    state @ext_modules;

    return \@ext_modules if (scalar @ext_modules);

    my $include   = PLS::Parser::Pod->get_clean_inc();
    my $installed = ExtUtils::Installed->new(inc_override => $include);

    foreach my $module ($installed->modules)
    {
        my @files = $installed->files($module, 'prog');
        $module =~ s/::/\//g;

        # Find all the packages that are part of this module
        foreach my $file (@files)
        {
            my ($path) = $file =~ /(\Q$module\E(?:\/.+)?)\.pm$/;
            next unless (length $path);
            my $mod_package = $path =~ s/\//::/gr;
            push @ext_modules, $mod_package;
        } ## end foreach my $file (@files)
    } ## end foreach my $module ($installed...)

    return \@ext_modules;
} ## end sub get_ext_modules

sub get_package_functions
{
    my ($package, $filter, $arrow) = @_;

    return Future->done([]) unless (length $package);

    return PLS::Parser::PackageSymbols::get_package_symbols($PLS::Server::State::CONFIG, $package)->then(
        sub {
            my ($functions) = @_;

            return Future->done([]) if (ref $functions ne 'HASH');

            my $separator = $arrow ? '->' : '::';
            my @functions;

            foreach my $package_name (keys %{$functions})
            {
                foreach my $name (@{$functions->{$package_name}})
                {
                    my $fully_qualified = join $separator, $package_name, $name;

                    my $result = {
                                  label    => $name,
                                  sortText => $fully_qualified,
                                  kind     => 3
                                 };

                    if ($arrow)
                    {
                        $result->{insertText} = $name;
                    }
                    else
                    {
                        $result->{insertText} = $fully_qualified;
                    }

                    if ($arrow)
                    {
                        if (length $filter)
                        {
                            $result->{filterText} = $name;
                        }
                        else
                        {
                            $result->{filterText} = $fully_qualified;
                        }
                    } ## end if ($arrow)
                    else
                    {
                        $result->{filterText} = $fully_qualified;
                    }

                    push @functions, $result;
                } ## end foreach my $name (@{$functions...})
            } ## end foreach my $package_name (keys...)

            return Future->done(\@functions);
        }
    );
} ## end sub get_package_functions

sub get_imported_package_functions
{
    my ($document, $full_text) = @_;

    my $imports = $document->get_imports($full_text);
    return Future->done([]) if (ref $imports ne 'ARRAY' or not scalar @{$imports});

    return PLS::Parser::PackageSymbols::get_imported_package_symbols($PLS::Server::State::CONFIG, @{$imports})->then(
        sub {
            my ($imported_functions) = @_;

            my @results;
            foreach my $package_name (keys %{$imported_functions})
            {
                foreach my $subroutine (@{$imported_functions->{$package_name}})
                {
                    my $result = {
                                  kind   => 3,
                                  label  => $subroutine,
                                  data   => $package_name,
                                  detail => "${package_name}::${subroutine}",
                                 };

                    $result->{labelDetails} = {description => "${package_name}::${subroutine}"}
                      if $PLS::Server::State::CLIENT_CAPABILITIES->{textDocument}{completion}{completionItem}{labelDetailsSupport};
                    push @results, $result;
                } ## end foreach my $subroutine (@{$imported_functions...})
            } ## end foreach my $package_name (keys...)
            return Future->done(\@results);
        }
    );
} ## end sub get_imported_package_functions

sub get_subroutines
{
    my ($document, $arrow, $full_text) = @_;

    my @subroutines;

    foreach my $sub (@{$document->get_subroutines_fast($full_text)})
    {
        next if ($sub =~ /\n/);
        push @subroutines, {label => $sub, kind => 3};
    }

    foreach my $sub (keys %{$document->{index}->subs})
    {
        foreach my $data (@{$document->{index}->subs->{$sub}})
        {
            my $result = {label => $sub, kind => 3};

            if (length $data->{package})
            {
                $result->{detail} = $data->{package} . '::' . $sub;
                $result->{data}   = $data->{package};
            }

            push @subroutines, $result;
        } ## end foreach my $data (@{$document...})
    } ## end foreach my $sub (keys %{$document...})

    return \@subroutines;
} ## end sub get_subroutines

sub get_packages
{
    my ($document, $full_text) = @_;

    my @packages;

    # Can use state here, core modules unlikely to change.
    state $core_modules = [Module::CoreList->find_modules(qr//, $])];
    my $ext_modules = get_ext_modules();

    push @packages, @{$document->get_packages_fast($full_text)};

    foreach my $pack (@{$core_modules}, @{$ext_modules})
    {
        next if ($pack =~ /\n/);
        push @packages, $pack;
    }

    if (ref $document->{index} eq 'PLS::Parser::Index')
    {
        push @packages, @{$document->{index}->get_all_packages()};
    }

    return [map { {label => $_, kind => 7} } List::Util::uniq sort @packages];
} ## end sub get_packages

sub get_constants
{
    my ($document, $filter, $full_text) = @_;

    my %seen_constants;
    my @constants;

    foreach my $constant (@{$document->get_constants_fast($full_text)})
    {
        next if $seen_constants{$constant}++;
        next if ($constant =~ /\n/);
        push @constants, {label => $constant, kind => 21};
    } ## end foreach my $constant (@{$document...})

    return \@constants;
} ## end sub get_constants

sub get_variables
{
    my ($document, $full_text) = @_;

    my @variables;
    my %seen_variables;

    state @builtin_variables;

    unless (scalar @builtin_variables)
    {
        my $perldoc = PLS::Parser::Pod->get_perldoc_location();

        if (open my $fh, '-|', $perldoc, '-Tu', 'perlvar')
        {
            while (my $line = <$fh>)
            {
                if ($line =~ /=item\s*(C<)?([\$\@\%]\S+)\s*/)
                {
                    # If variable started with pod sequence "C<" remove ">" from the end
                    my $variable = $2;
                    $variable = substr $variable, 0, -1 if (length $1);

                    # Remove variables indicated by pod sequences
                    next if ($variable =~ /^\$</ and $variable ne '$<');
                    push @builtin_variables, $variable;
                } ## end if ($line =~ /=item\s*(C<)?([\$\@\%]\S+)\s*/...)
            } ## end while (my $line = <$fh>)

            close $fh;
        } ## end if (open my $fh, '-|',...)
    } ## end unless (scalar @builtin_variables...)

    foreach my $variable (@builtin_variables, @{$document->get_variables_fast($full_text)})
    {
        next if $seen_variables{$variable}++;
        next if ($variable =~ /\n/);
        push @variables,
          {
            label => $variable,
            kind  => 6
          };

        # add other variable forms to the list for arrays and hashes
        if ($variable =~ /^[\@\%]/)
        {
            my $name   = $variable =~ s/^[\@\%]/\$/r;
            my $append = $variable =~ /^\@/ ? '[' : '{';
            push @variables,
              {
                label      => $variable,
                insertText => $name . $append,
                filterText => $name,
                kind       => 6
              };
        } ## end if ($variable =~ /^[\@\%]/...)
    } ## end foreach my $variable (@builtin_variables...)

    return \@variables;
} ## end sub get_variables

sub get_snippets
{
    state @snippets = (
            {
             label            => 'sub',
             detail           => 'Insert subroutine',
             kind             => 15,
             insertTextFormat => 2,
             insertText       => "sub \$1\n{\n\t\$0\n}",
            },
            {
             label            => 'foreach',
             detail           => 'Insert foreach loop',
             kind             => 15,
             insertTextFormat => 2,
             insertText       => "foreach my \$1 (\$2)\n{\n\t\$0\n}",
            },
            {
             label            => 'for',
             detail           => 'Insert C-style for loop',
             kind             => 15,
             insertTextFormat => 2,
             insertText       => "for (\$1 ; \$2 ; \$3)\n{\n\t\$0\n}",
            },
            {
             label            => 'while',
             detail           => 'Insert while statement',
             kind             => 15,
             insertTextFormat => 2,
             insertText       => "while (\$1)\n{\n\t\$0\n}",
            },
            {
             label            => 'if',
             detail           => 'Insert if statement',
             kind             => 15,
             insertTextFormat => 2,
             insertText       => "if (\$1)\n{\n\t\$0\n}",
            },
            {
             label            => 'elsif',
             detail           => 'Insert elsif statement',
             kind             => 15,
             insertTextFormat => 2,
             insertText       => "elsif (\$1)\n{\n\t\$0\n}",
            },
            {
             label            => 'else',
             detail           => 'Insert else statement',
             kind             => 15,
             insertTextFormat => 2,
             insertText       => "else\n{\n\t\$0\n}",
            },
            {
             label            => 'package',
             detail           => 'Create a new package',
             kind             => 15,
             insertTextFormat => 2,
             insertText       => "package \$1;\n\nuse strict;\nuse warnings;\n\n\$0\n\n1;",
            },
            {
             label            => 'open my $fh, ...',
             filterText       => 'open',
             sortText         => 'open',
             detail           => 'Insert an open statement',
             kind             => 15,
             insertTextFormat => 2,
             insertText       => q[open $1, '${2|<,>,>>,+<,+>,\|-,-\|,>&,<&=,>>&=|}', $3],
            },
            {
             label            => 'do { local $/; <$fh> }',
             filterText       => 'do',
             sortText         => 'do1',
             detail           => 'Slurp an entire filehandle',
             kind             => 15,
             insertTextFormat => 2,
             insertText       => 'do { local $/; <$1> }'
            },
            {
             label            => 'while (my $line = <$fh>) { ... }',
             filterText       => 'while',
             sortText         => 'while1',
             detail           => 'Iterate through a filehandle line-by-line',
             kind             => 15,
             insertTextFormat => 2,
             insertText       => "while (my \$1 = <\$2>)\n{\n\t\$0\n}"
            },
            {
             label            => 'my ($param1, $param2, ...) = @_;',
             filterText       => 'my',
             sortText         => 'my1',
             detail           => 'Get subroutine parameters',
             kind             => 15,
             insertTextFormat => 2,
             insertText       => "my (\$1) = \@_;\n\n"
            },
            {
             label            => '$? >> 8',
             filterText       => '$?',
             sortText         => '$?',
             detail           => 'Get exit code',
             kind             => 15,
             insertTextFormat => 2,
             insertText       => '? >> 8'
            },
            {
             label            => 'sort { $a <=> $b } ...',
             filterText       => 'sort',
             sortText         => 'sort1',
             detail           => 'Sort numerically ascending',
             kind             => 15,
             insertTextFormat => 2,
             insertText       => 'sort { \$a <=> \$b } $1'
            },
            {
             label            => 'reverse sort { $a <=> $b } ...',
             filterText       => 'sort',
             sortText         => 'sort2',
             detail           => 'Sort numerically descending',
             kind             => 15,
             insertTextFormat => 2,
             insertText       => 'reverse sort { \$a <=> \$b } $1'
            }
           );

    return @snippets;
} ## end sub get_snippets

1;
