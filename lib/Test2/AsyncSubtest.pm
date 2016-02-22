package Test2::AsyncSubtest;
use strict;
use warnings;

use Carp qw/croak/;
use Test2::Util qw/get_tid/;

use Test2::API();
use Test2::Hub::AsyncSubtest();
use Test2::Util::Trace();
use Test2::Event::Exception();

use Test2::Util::HashBase qw/name hub errored events _finished event_used pid tid/;

our @CARP_NOT = qw/Test2::Tools::AsyncSubtest/;

sub init {
    my $self = shift;

    croak "'name' is a required attribute"
        unless $self->{+NAME};

    $self->{+PID} = $$;
    $self->{+TID} = get_tid();

    unless($self->{+HUB}) {
        my $ipc = Test2::API::test2_ipc();
        my $hub = Test2::Hub::AsyncSubtest->new(format => undef, ipc => $ipc);
        $self->{+HUB} = $hub;
    }

    my $hub = $self->{+HUB};
    my @events;
    $hub->listen(sub { push @events => $_[1] });
    $self->{+EVENTS} = \@events;
}

sub run {
    my $self = shift;
    my $code = pop;
    my %params = @_;

    croak "AsyncSubtest->run() takes a codeblock as its last argument"
        unless $code && ref($code) eq 'CODE';

    croak "Subtest is already complete, cannot call run()"
        if $self->{+_FINISHED};

    my $hub = $self->{+HUB};
    my $stack = Test2::API::test2_stack();
    $stack->push($hub);
    my ($ok, $err, $finished);
    T2_SUBTEST_WRAPPER: {
        $ok = eval { $code->($params{args} ? @{$params{args}} : ()); 1 };
        $err = $@;

        # They might have done 'BEGIN { skip_all => "whatever" }'
        if (!$ok && $err =~ m/Label not found for "last T2_SUBTEST_WRAPPER"/) {
            $ok  = undef;
            $err = undef;
        }
        else {
            $finished = 1;
        }
    }
    $stack->pop($hub);

    if (!$finished) {
        if(my $bailed = $hub->bailed_out) {
            my $ctx = Test2::API::context();
            $ctx->bail($bailed->reason);
            $ctx->release;
        }
        my $code = $hub->exit_code;
        $ok = !$code;
        $err = "Subtest ended with exit code $code" if $code;
    }

    unless($ok) {
        my $e = Test2::Event::Exception->new(
            error => $err,
            trace => $params{trace} || Test2::Util::Trace->new(
                frame => [caller(0)],
            ),
        );
        $hub->send($e);
        $self->{+ERRORED} = 1;
    }

    return $hub->is_passing;
}

sub finish {
    my $self = shift;
    my %params = @_;

    croak "Subtest is already finished"
        if $self->{+_FINISHED}++;

    croak "Subtest can only be finished in the process that created it"
        unless $$ == $self->{+PID};

    croak "Subtest can only be finished in the thread that created it"
        unless get_tid == $self->{+TID};

    my $hub = $self->{+HUB};
    my $trace = $params{trace} ||= Test2::Util::Trace->new(
        frame => [caller[0]],
    );

    $hub->finalize($trace, 1)
        unless $hub->no_ending || $hub->ended;

    if ($hub->ipc) {
        $hub->ipc->drop_hub($hub->hid);
        $hub->set_ipc(undef);
    }

    return $hub->is_passing;
}

sub event_data {
    my $self = shift;
    my $hub = $self->{+HUB};

    croak "Subtest data can only be used in the process that created it"
        unless $$ == $self->{+PID};

    croak "Subtest data can only be used in the thread that created it"
        unless get_tid == $self->{+TID};

    $self->{+EVENT_USED} = 1;

    return (
        pass => $hub->is_passing,
        name => $self->{+NAME},
        buffered  => 1,
        subevents => $self->{+EVENTS},
    );
}

sub diagnostics {
    my $self = shift;
    # If the subtest died then we've already sent an appropriate event. No
    # need to send another telling the user that the plan was wrong.
    return if $self->{+ERRORED};

    croak "Subtest diagnostics can only be used in the process that created it"
        unless $$ == $self->{+PID};

    croak "Subtest diagnostics can only be used in the thread that created it"
        unless get_tid == $self->{+TID};

    my $hub = $self->{+HUB};
    return if $hub->check_plan;
    return "Bad subtest plan, expected " . $hub->plan . " but ran " . $hub->count;
}

sub DESTROY {
    my $self = shift;
    return if $self->{+EVENT_USED};
    return if $self->{+PID} != $$;
    return if $self->{+TID} != get_tid;

    warn "Subtest $self->{+NAME} did not finish!" unless $self->{+_FINISHED};
    warn "Subtest $self->{+NAME} was not used to procude any events";

    exit 255;
}

1;
