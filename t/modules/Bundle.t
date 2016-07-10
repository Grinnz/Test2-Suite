use Test2::Bundle::Extended;

use Test2::Bundle; # No Effect, here to make sure it does not die

BEGIN {
    $INC{'Foo/A.pm'} = __FILE__;
    $INC{'Foo/B.pm'} = __FILE__;
    $INC{'My/Bundle.pm'} = __FILE__;

    package Foo::A;
    our @EXPORT = qw/foo bar/;
    sub foo { 'foo a' }
    sub bar { 'bar a' }

    package Foo::B;
    our @EXPORT = qw/foo bar/;
    sub foo { 'foo b' }
    sub bar { 'bar b' }

    package My::Bundle;

    use base 'Test2::Bundle';

    sub PRAGMAS {
        (strict => {args => ['refs'], toggle => {-no_strict => 0, -no_pragmas => 0}});
    }

    sub EXPORTS {
        (
            'Foo::A' => {
                v1 => [qw/foo bar/],
                v2 => {foo => {-as => 'a_foo'}, bar => 0},
                A  => [qw/foo bar/],
                B => {foo => {-as => 'a_foo'}},
            },
            'Foo::B' => {
                v2 => {foo => 1, bar => {-as => 'b_bar'}},
                a => {foo => {-as => 'b_foo'}},
                B => [qw/foo bar/],
            },
        );
    }
}

subtest pragmas => sub {
    no strict qw/refs vars/;

    is(eval { my $x = 'xx'; our $xx = 'worked'; $$x; }, 'worked', "Turned off strict refs") or warn $@;
    is(eval '$x = "worked"', 'worked', "Turned off strict vars") or warn $@;

    {
        use My::Bundle;

        like(
            dies(sub { ${'xx'} }),
            qr/Can't use string \("xx"\) as a SCALAR ref while "strict refs" in use/,
            "Turned on strict refs"
        );

        is(eval '$x = "worked"', 'worked', "args used, strict vars is still off") or warn $@;
    }

    {
        use My::Bundle -no_strict => 1;
        is(eval { my $x = 'xx'; our $xx = 'worked'; $$x; }, 'worked', "strict not turned back on");
    }

    {
        use My::Bundle -no_pragmas => 1;
        is(eval { my $x = 'xx'; our $xx = 'worked'; $$x; }, 'worked', "strict not turned back on");
    }
};

subtest tag_cmp => sub {
    package Test2::Bundle;

    main::is(
        [sort _tag_cmp qw/oops v2 v3 v10 v100 v1 foo bar baz 123/],
        [qw/v1 v2 v3 v10 v100/, sort {$a cmp $b} qw/oops foo bar baz 123/],
        "vN tags come first, in numeric order, followed by others in cmp order"
    );
};


done_testing;

__END__

sub IMPORTER_CLASS { 'Importer' }

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


