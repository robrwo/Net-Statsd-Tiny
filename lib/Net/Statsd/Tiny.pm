package Net::Statsd::Tiny;

# ABSTRACT: A tiny StatsD client

use v5.10;

use Moo 1.000000;

use IO::Socket 1.18 ();
use IO::String;

our $VERSION = 'v0.3.0';

=head1 SYNOPSIS

    use Net::Statsd::Tiny;

    my $stats = Net::Statsd::Tiny->new(
      prefix          => 'myapp.',
      autoflush       => 0,
      max_buffer_size => 8192,
    );

    ...

    $stats->increment('this.counter');

    $stats->set_add( $username ) if $username;

    $stats->timing( $run_time * 1000 );

    $stats->flush;

=head1 DESCRIPTION

This is a small StatsD client that supports the
L<StatsD Metrics Export Specification v0.1|https://github.com/b/statsd_spec>.

It supports the following features:

=over

=item Multiple metrics can be sent in a single UDP packet.

=item It supports the meter and histogram metric types.

=back

Note that the specification requires the measured values to be
integers no larger than 64-bits, but ideally 53-bits.

The current implementation does not validate the values. If you want
validation, see L<Net::Statsd::Lite>.

=head1 ATTRIBUTES

=attribute C<host>

The host of the statsd daemon. It defaults to C<127.0.0.1>.

=cut

has host => (
    is      => 'ro',
    default => '127.0.0.1',
);

=attribute C<port>

The port that the statsd daemon is listening on. It defaults to
C<8125>.

=cut

has port => (
    is      => 'ro',
    default => 8125,
);

=attribute C<proto>

The network protocol that the statsd daemon is using. It defaults to
C<udp>.

=cut

has proto => (
    is      => 'ro',
    default => 'udp',
);

=attribute C<prefix>

The prefix to prepend to metric names. It defaults to a blank string.

=cut

has prefix => (
    is      => 'ro',
    default => '',
);

=attribute C<autoflush>

A flag indicating whether metrics will be send immediately. It
defaults to true.

When it is false, metrics will be saved in a buffer and only sent when
the buffer is full, or when the L</flush> method is called.

Note that when this is disabled, you will want to flush the buffer
regularly at the end of each task (e.g. a website request or job).

Not all StatsD daemons support receiving multiple metrics in a single
packet.

=cut

has autoflush => (
    is      => 'ro',
    default => 1,
);

has _buffer => (
    is      => 'lazy',
    builder => sub {
        IO::String->new;
    },
);

=attribute C<max_buffer_size>

The specifies the maximum buffer size. It defaults to C<512>.

=cut

has max_buffer_size => (
    is      => 'ro',
    default => 512,
);

has _socket => (
    is      => 'lazy',
    builder => sub {
        my ($self) = shift;
        my $sock = IO::Socket::INET->new(
            PeerAddr => $self->host,
            PeerPort => $self->port,
            Proto    => $self->proto,
        ) or die "Failed to initialize socket: $!";
        return $sock;
    },
    handles => { _send => 'send' },
);

=head1 METHODS

=method C<counter>

  $stats->counter( $metric, $value, $rate );

This adds the C<$value> to the counter specified by the C<$metric>
name.

If a C<$rate> is specified and less than 1, then a sampling rate will
be added. C<$rate> must be between 0 and 1.

=method C<update>

This is an alias for L</counter>, for compatability with
L<Etsy::StatsD> or L<Net::Statsd::Client>.

=method C<increment>

  $stats->increment( $metric, $rate );

This is an alias for

  $stats->counter( $metric, 1, $rate );

=method C<decrement>

  $stats->decrement( $metric, $rate );

This is an alias for

  $stats->counter( $metric, -1, $rate );

=method C<metric>

  $stats->metric( $metric, $value );

This is a counter that only accepts positive (increasing) values. It
is appropriate for counters that will never decrease (e.g. the number
of requests processed.)  However, this metric type is not supported by
many StatsD daemons.

=method C<gauge>

  $stats->gauge( $metric, $value );

A gauge can be thought of as a counter that is maintained by the
client instead of the daemon, where C<$value> is a positive integer.

However, this also supports gauge increment extensions. If the number
is prefixed by a "+", then the gauge is incremented by that amount,
and if the number is prefixed by a "-", then the gauge is decremented
by that amount.

=method C<timing>

  $stats->timing( $metric, $value, $rate );

This logs a "timing" in milliseconds, so that statistics about the
metric can be gathered. The C<$value> must be positive number,
although the specification recommends that integers be used.

In actually, any values can be logged, and this is often used as a
generic histogram for non-timing values (especially since many StatsD
daemons do not support the L</histogram> metric type).

If a C<$rate> is specified and less than 1, then a sampling rate will
be added. C<$rate> must be between 0 and 1.  Note that sampling
rates for timings may not be supported by all statsd servers.

=method C<timing_ms>

This is an alias for L</timing>, for compatability with
L<Net::Statsd::Client>.

=method C<histogram>

  $stats->histogram( $metric, $value );

This logs a value so that statistics about the metric can be
gathered. The C<$value> must be a positive number, although the
specification recommends that integers be used.

=method C<set_add>

  $stats->set_add( $metric, $string );

This adds the the C<$string> to a set, for logging the number of
unique things, e.g. IP addresses or usernames.

=method C<add_set>

This is an alias for L</set_add>. It is deprecated and will be removed
in a later version.

=cut

BEGIN {
    my $class = __PACKAGE__;

    my %PROTOCOL = (
        set_add   => 's',
        counter   => 'c',
        gauge     => 'g',
        histogram => 'h',
        meter     => 'm',
        timing    => 'ms',
    );

    foreach my $name ( keys %PROTOCOL ) {

        no strict 'refs';    ## no critic (ProhibitNoStrict)

        my $tmpl = '%s:%s|' . $PROTOCOL{$name};

        *{"${class}::${name}"} = sub {
            my ( $self, $metric, $value, $rate ) = @_;
            if ( ( defined $rate ) && ( $rate < 1 ) ) {
                $self->_record( $tmpl . '|@%f', $metric, $value, $rate );
            }
            else {
                $self->_record( $tmpl, $metric, $value );
            }
        };

    }

    # Alises for other Net::Statsd::Client or Etsy::StatsD

    {
        no strict 'refs';    ## no critic (ProhibitNoStrict)

        *{"${class}::update"}    = \&counter;
        *{"${class}::timing_ms"} = \&timing;
        *{"${class}::add_set"}   = \&set_add;

    }

}

sub increment {
    my ( $self, $metric, $rate ) = @_;
    $self->counter( $metric, 1, $rate );
}

sub decrement {
    my ( $self, $metric, $rate ) = @_;
    $self->counter( $metric, -1, $rate );
}

sub _record {
    my ( $self, $template, @args ) = @_;

    my $data = $self->prefix . sprintf( $template, @args );

    my $fh  = $self->_buffer;
    my $len = length($data);

    if ( $len >= $self->max_buffer_size ) {
        warn "Data is too large";
        return $self;
    }

    $len += length( ${ $fh->string_ref } );
    if ( $len >= $self->max_buffer_size ) {
        $self->flush;
    }

    say {$fh} $data;

    $self->flush if $self->autoflush;
}

=method C<flush>

This sends the buffer to the L</host> and empties the buffer, if there
is any data in the buffer.

=cut

sub flush {
    my ($self) = @_;

    my $fh = $self->_buffer;

    my $data = ${ $fh->string_ref };

    if ( length($data) ) {
        $self->_send( $data, 0 );
        $fh->truncate;
    }
}

sub DEMOLISH {
    my ( $self, $is_global ) = @_;

    return if $is_global;

    $self->flush;
}

=head1 SEE ALSO

L<Net::Statsd::Lite> which has a similar API but uses L<Moo> and
L<Type::Tiny> for data validation.

L<https://github.com/b/statsd_spec>

=head1 append:AUTHOR

The initial development of this module was sponsored by Science Photo
Library L<https://www.sciencephoto.com>.

=cut

1;
