package Net::Async::PostgreSQL::Client;
BEGIN {
  $Net::Async::PostgreSQL::Client::VERSION = '0.004';
}
use strict;
use warnings;
use Protocol::PostgreSQL::Client '0.005';
use parent qw{IO::Async::Protocol::Stream Protocol::PostgreSQL::Client};
use Scalar::Util ();

=head1 NAME

Net::Async::PostgreSQL - support for the PostgreSQL wire protocol

=head1 VERSION

version 0.004

=head1 SYNOPSIS

 # Simple queries are performed similar to DBI:
 $dbh->do(q{insert into something (x,y,z) values (1,2,3)});

 # These can also use bind variables:
 $dbh->do(q{insert into something (x,y,z) values (?,?,?)}, undef, 1,2,3);

 # Prepared statements work the same as DBI by default
 my $sth = $dbh->prepare(q{select * from table where name = ?});
 $sth->bind_param(1, 'test');
 $sth->execute;

 # ... but have async_ versions for passing handlers:
 my $sth = $dbh->async_prepare(
 	sql => q{select * from table where name = ?},
	on_error => sub { warn "failed" }
 );
 $sth->async_execute(
 	on_bind_request => sub {
		return @param;
	},
	on_header	=> sub { ... },
	on_row		=> sub { ... },
	on_error	=> sub { ... },
	on_complete	=> sub { ... },
 );

 # And there's a helper method for doing regular queries:
 $dbh->run_query(
 	sql		=> q{select * from something where id = ?},
	parameters	=> [1],
	on_row		=> sub { warn "Had " . $_[1]->{} },
	on_error	=> sub { warn "Error encountered" },
	on_complete	=> sub { warn "all done" }
 );

=head1 DESCRIPTION

The interface is provided by L<Net::Async::DBI>, which attempts to offer something close to
L<DBI> but with support for event-based request handling.

See L<Protocol::PostgreSQL> for more details.

=cut

use Socket qw(SOCK_STREAM);

=head1 METHODS

=cut

sub new {
	my $class = shift;
	my %args = @_;

# Clear any options that will cause the parent class to complain
	my $loop = delete $args{loop};

# Want the IO::Async::Protocol constructor, so SUPER is good enough for us here
	my $self = $class->SUPER::new( %args );

# Automatically add to the event loop if we were passed one
	$loop->add($self) if $loop;
	return $self;
}

=head2 configure

Apply callbacks and other parameters, preparing state for event loop start.

=cut

sub configure {
	my $self = shift;
	my %args = @_;

# Debug flag is used to control the copious amounts of data that we dump out when tracing
	if(exists $args{debug}) {
		$self->{debug} = delete $args{debug};
	}

	foreach (qw{host service user pass database ssl tls}) {
		$self->{$_} = delete $args{$_} if exists $args{$_};
	}

	Protocol::PostgreSQL::configure($self, %args);
	$self->SUPER::configure(%args);
}

=head2 on_connection_established

Prepare and activate a new transport.

=cut

sub on_connection_established {
	my $self = shift;
	my $sock = shift;
	my $transport = IO::Async::Stream->new(handle => $sock)
		or die "No transport?";
	$self->configure(transport => $transport);
	$self->debug("Have transport " . $self->transport);
}

=head2 on_starttls

Upgrade the underlying stream to use TLS.

=cut

sub on_starttls {
	my $self = shift;
	$self->debug("Upgrading to TLS");

	require IO::Async::SSLStream;

	$self->SSL_upgrade(
		on_upgraded => $self->_capture_weakself(sub {
			my ($self) = @_;
			$self->debug("TLS upgrade complete");

			$self->{tls_enabled} = 1;
			$self->initial_request;
		}),
		on_error => sub { die "error @_"; }
	);
}

=head2 connect

=cut

sub connect {
	my $self = shift;
	my %args = @_;

	my $on_connected = delete $args{on_connected};
	my $host = exists $args{host} ? delete $args{host} : $self->{host};
	$self->SUPER::connect(
		service		=> $args{service} || $self->{service} || 5432,
		%args,
		host		=> $host,
		socktype	=> SOCK_STREAM,
		on_resolve_error => sub {
			die "Resolution failed for $host";
		},
		on_connect_error => sub {
			die "Could not connect to $host";
		},
		on_connected => sub {
			my ($self, $sock) = @_;
			$self->initial_request;
			$on_connected->($self) if $on_connected;
		}
	);
}

=head2 on_send_request

Send data to the server.

=cut

sub on_send_request {
	my $self = shift;
	$self->write(@_);
}

=head2 on_read

Handle read requests by passing full packets back to the protocol handler.

=cut

sub on_read {
	my $self = shift;
	my ($buffref, $eof) = @_;
	return 0 unless length($$buffref) >= 5;
	my ($code, $size) = unpack('C1N1', $$buffref);
	if(length($$buffref) >= $size+1) {
		$self->handle_message(substr $$buffref, 0, $size+1, '');
		return 1;
	}
	return 0;
}

=head2 do


=cut

sub do {
	my $self = shift;
	my ($sql, $attrib, @param) = @_;
	$self->simple_query($sql);
	return $self;
}

sub on_password {
	my $self = shift;
	$self->send_message('PasswordMessage', password => $self->{pass});
}

=head2 terminate

Sends the Terminate message to the database server and closes the connection for a clean
shutdown.

=cut

sub terminate {
	my $self = shift;
	return unless $self->transport;

	my $transport = $self->transport;
	Scalar::Util::weaken(my $loop = $transport->get_loop);
	# TODO could just ->close_when_empty?
	$transport->configure(on_outgoing_empty => $self->_capture_weakself(sub {
		my $self = shift;
		$self->close;
		$loop->later(sub { $loop->loop_stop; });
	}));
	$self->send_message('Terminate');
	return $self;
}

1;

__END__

=head1 SEE ALSO

=over 4

=item * L<DBI> - the real database interface

=item * L<DBD::Gofer> - proxy request support for DBI

=back

=head1 AUTHOR

Tom Molesworth <cpan@entitymodel.com>

=head1 LICENSE

Copyright Tom Molesworth 2011. Licensed under the same terms as Perl itself.