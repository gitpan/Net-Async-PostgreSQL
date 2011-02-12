use strict;
use warnings;

use IO::Async::Loop;
use Net::Async::PostgreSQL::Client;

my $loop = IO::Async::Loop->new;
my $client = Net::Async::PostgreSQL::Client->new(
	debug			=> 0,
	host			=> $ENV{NET_ASYNC_POSTGRESQL_SERVER} || 'localhost',
	service			=> $ENV{NET_ASYNC_POSTGRESQL_PORT} || 5432,
	database		=> $ENV{NET_ASYNC_POSTGRESQL_DATABASE},
	user			=> $ENV{NET_ASYNC_POSTGRESQL_USER},
	pass			=> $ENV{NET_ASYNC_POSTGRESQL_PASS},
);
$client->init;

my @query_list = (
	q{begin work},
	q{create schema nap_test},
	q{create table nap_test.nap_1 (id serial primary key, name varchar, creation timestamp)},
	q{insert into nap_test.nap_1 (name, creation) values ('test', 'now')},
	q{insert into nap_test.nap_1 (name, creation) values ('test2', 'now')},
	q{select * from nap_test.nap_1},
	q{rollback},
);
my $init = 0;
my %status;
$client->attach_event(
	error	=> sub {
		my ($self, %args) = @_;
		warn "had error";
		my $err = $args{error};
		warn "$_ => " . $err->{$_} . "\n" for sort keys %$err;
	},
	ready_for_query => sub {
		my $self = shift;
		unless($init) {
			print "Server version " . $status{server_version} . "\n";
			++$init;
		}
		my $q = shift(@query_list) or return $loop->loop_stop;
		$self->simple_query($q);
	},
	parameter_status => sub {
		my $self = shift;
		my %args = @_;
		$status{$_} = $args{status}->{$_} for sort keys %{$args{status}};
	},
	row_description => sub {
		my $self = shift;
		my %args = @_;
		print '[' . join(' ', map { $_->{name} } @{$args{description}{field}}) . "]\n";
	},
	data_row => sub {
		my $self = shift;
		my %args = @_;
		print '[' . join(',', map { $_->{data} } @{$args{row}}) . "]\n";
	}
);
$loop->add($client);
$client->connect;
$loop->loop_forever;
exit 0;
