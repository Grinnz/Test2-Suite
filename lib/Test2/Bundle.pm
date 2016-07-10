package Test2::Bundle;
use strict;
use warnings;

our $VERSION = '0.000051';

use Test2::Util qw/pkg_to_file/;
use Carp qw/croak/;

sub EXPORTS {()};
sub PRAGMAS {()};

sub _tag_cmp {
    my ($av, $an) = ($a =~ m/^(v)(\d+)$/);
    my ($bv, $bn) = ($b =~ m/^(v)(\d+)$/);

    return $a cmp $b unless $av || $bv;
    return -1 if $av && !$bv;
    return  1 if $bv && !$av;
    return $an <=> $bn;
}

my %LOOKUP_CACHE;
sub import_lookup {
    my $class = shift;

    return $LOOKUP_CACHE{$class} if $LOOKUP_CACHE{$class};

    my %table = $class->EXPORTS;

    my (%symbols, %tags);
    for my $pkg (keys %table) {
        for my $tag (keys %{$table{$pkg}}) {
            my $def = $table{$pkg}->{$tag};

            if (ref($def) eq 'ARRAY') {
                while (my $item = shift @$def) {
                    my $spec = (@$def && ref $def->[0]) ? shift @$def : {};
                    my $name = join '' => ($spec->{'-prefix'} || '', $spec->{'-as'} || $item, $spec->{'-postfix'} || '');
                    $symbols{$name} = [$pkg, $item, $spec];
                    $tags{$tag}->{$pkg}->{$name} = $spec;
                }
            }
            else {
                $tags{$tag}->{$pkg} = { %{$tags{$tag}->{$pkg} || {}}, %$def };
            }
        }
    }

    # v# inheritence
    for my $tag (sort _tag_cmp keys %tags) {
        next unless $tag =~ m/^v(\d+)$/;
        my $p = $1 - 1;
        next unless $p;

        my $parent = $tags{"v$p"} ||= {};
        my $def = $tags{$tag};
        $tags{$tag} = { %$parent, %$def };
    }

    return $LOOKUP_CACHE{$class} = {
        symbols => \%symbols,
        tags    => \%tags,
    };
}

sub importer_class { 'Importer' }

sub do_import {
    my $class = shift;
    my %params = @_;

    my ($from, $into, $args) = @params{qw/from into args/};

    my $importer = $class->importer_class;

    my $file = pkg_to_file($importer);
    require $file unless $INC{$file};

    $importer->import_into($from, $into, @$args);
}

sub munge_import_args { shift; @_ }
sub parse_import_args {
    my $class = shift;

    my @args = $class->munge_import_args(@_);
    my $lookup = $class->import_lookup();

    my (%exports, %options, %tags);
    while (my $arg = shift @args) {
        my $type = substr($arg, 0, 1);
        if ($type eq '-') {
            $options{$arg} = shift @args;
        }
        elsif ($type eq ':') {
            substr($arg, 0, 1, '');
            my $tag = $lookup->{tags}->{$arg} or croak "invalid tag ':$arg'";
            $tags{$arg}++;

            for my $pkg (keys %$tag) {
                my $set = $lookup->{tags}->{$arg}->{$pkg};
                for my $e (keys %$set) {
                    my $spec = $set->{$e} or next;

                    my $info = $lookup->{symbols}->{$e} or croak "'$class' does not export '$e'";
                    my ($pkg, $item) = @$info;

                    push @{$exports{$pkg}} => $item;
                    push @{$exports{$pkg}} => $spec if ref($spec) && keys %$spec;
                }
            }
        }
        else {
            my $info = $lookup->{symbols}->{$arg} or croak "'$class' does not export '$arg'";
            my ($pkg, $item, $spec) = @$info;

            $spec = shift @args if @args && ref($args[0]);

            push @{$exports{$pkg}} => $item;
            push @{$exports{$pkg}} => $spec if $spec && keys %$spec;
        }
    }

    return (\%exports, \%options, \%tags);
}

sub before_import {}

sub import {
    my $class = shift;
    my $caller = caller;

    my ($exports, $options, $tags) = $class->parse_import_args(@_);

    my %ok_opts;
    my @cb_args = (
        into    => $caller,
        exports => $exports,
        options => $options,
        tags    => $tags,
        ok_opts => \%ok_opts,
    );

    $class->before_import(@cb_args);

    my @pragmas = $class->PRAGMAS();
    PRAGMA: while (my $mod = shift @pragmas) {
        my $spec = shift @pragmas;
        my $opts = $spec->{toggle};
        my $args = $spec->{args};

        $ok_opts{$_}++ for keys %$opts;

        for my $opt (keys %$opts) {
            next PRAGMA if $opts->{$opt}  && !$options->{$opt};
            next PRAGMA if !$opts->{$opt} && $options->{$opt};
        }

        my $file = pkg_to_file($mod);
        require $file unless $INC{$file};
        $mod->import(@$args);
    }

    for my $pkg (keys %$exports) {
        my $args = $exports->{$pkg};

        $class->do_import(
            from => $pkg,
            into => $caller,
            args => $args,
        );
    }

    $class->after_import(@cb_args);

    my @bad = grep { !$ok_opts{$_} } sort keys %$options;
    croak "Invalid options: " . join(', ', @bad) if @bad;

    return 1;
}

sub after_import {}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Bundle - Documentation for bundles.

=head1 DESCRIPTION

Bundles are collections of Tools and Plugins. Bundles should not provide any
tools or behaviors of their own, they should simply combine the tools and
behaviors of other packages.

=head1 FAQ

=over 4

=item Should my bundle subclass Test2::Bundle?

No. Currently this class is empty. Eventually we may want to add behavior, in
which case we do not want anyone to already be subclassing it.

=back

=head1 HOW DO I WRITE A BUNDLE?

Writing a bundle can be very simple:

    package Test2::Bundle::MyBundle;
    use strict;
    use warnings;

    use Test2::Plugin::ExitSummary; # Load a plugin

    use Test2::Tools::Basic qw/ok plan done_testing/;

    # Re-export the tools
    our @EXPORTS = qw/ok plan done_testing/;
    use base 'Exporter';

    1;

If you want to do anything more complex you should look into L<Import::Into>
and L<Symbol::Move>.

=head1 SOURCE

The source code repository for Test2-Suite can be found at
F<http://github.com/Test-More/Test2-Suite/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2016 Chad Granum E<lt>exodist@cpan.orgE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
