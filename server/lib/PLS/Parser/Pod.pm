package PLS::Parser::Pod;

use strict;
use warnings;

use File::Spec;
use IPC::Open3;
use Pod::Markdown;
use Symbol qw(gensym);

use PLS::Parser::Document;

sub new
{
    my ($class, @args) = @_;

    my %args = @args;

    my %self = (
        document => $args{document},
        element => $args{element}
    );

    return bless \%self, $class;
}

sub line_number
{
    my ($self) = @_;

    return $self->{element}->lsp_line_number;
}

sub column_number
{
    my ($self) = @_;

    return $self->{element}->lsp_column_number
}

sub name
{
    my ($self) = @_;

    return '';
}

sub get_perldoc_location
{
    my (undef, $dir) = File::Spec->splitpath($^X);
    my $perldoc = File::Spec->catfile($dir, 'perldoc');
    # try to use the perldoc matching this perl executable, falling back to the perldoc in the PATH
    return (-f $perldoc and -x $perldoc) ? $perldoc : 'perldoc';
}

sub run_perldoc_command
{
    my ($class, @command) = @_;

    my $markdown = '';

    my $err = gensym;
    my $pid = open3(my $in, my $out, $err, get_perldoc_location(), @command);

    close $in, () = <$err>; # need to read all of error file handle
    my $pod = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    my $exit_code = $? >> 8;
    return 0 if $exit_code != 0;
    return $class->get_markdown_from_text(\$pod);
}

sub get_markdown_from_lines
{
    my ($class, $lines) = @_;

    my $markdown = '';
    my $parser = Pod::Markdown->new();

    $parser->output_string(\$markdown);
    $parser->no_whining(1);
    $parser->parse_lines(@$lines, undef);

    $class->clean_markdown(\$markdown);

    my $ok = $parser->content_seen;
    return 0 unless $ok;
    return $ok, \$markdown;
}

sub get_markdown_from_text
{
    my ($class, $text) = @_;

    my $markdown = '';
    my $parser = Pod::Markdown->new();

    $parser->output_string(\$markdown);
    $parser->no_whining(1);
    $parser->parse_string_document($$text);

    $class->clean_markdown(\$markdown);

    my $ok = $parser->content_seen;
    return 0 unless $ok;
    return $ok, \$markdown;
}

sub clean_markdown
{
    my ($class, $markdown) = @_;

    # remove first extra space to avoid markdown from being displayed inappropriately as code
    $$markdown =~ s/\n\n/\n/;
}

sub combine_markdown
{
    my ($class, @markdown_parts) =@_;

    return join "\n---\n", @markdown_parts;
}

1;