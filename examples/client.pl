#!/usr/bin/perl
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
#$client->init;

my @query_list = (
	q{begin work},
	q{create schema nap_test},
	q{create table nap_test.nap_1 (id serial primary key, name varchar, creation timestamp)},
	q{insert into nap_test.nap_1 (name, creation) values ('test', 'now')},
	q{insert into nap_test.nap_1 (name, creation) values ('test2', 'now')},
	q{select * from nap_test.nap_1},
);
my $init = 0;
my $finished = 0;
my %status;
$client->attach_event(
	error	=> sub {
		my ($self, %args) = @_;
		print "Received error\n";
		my $err = $args{error};
		warn "$_ => " . $err->{$_} . "\n" for sort keys %$err;
	},
	command_complete => sub {
		my $self = shift;
		print "Command complete\n";
		warn $finished;
		$loop->loop_stop if $finished == 2;
	},
	copy_in_response => sub {
		my ($self, %args) = @_;
		print "Copy in response\n";
		$self->copy_data("some name\t2010-01-01 00:00:00");
		++$finished;
		$self->copy_done;
	},
	ready_for_query => sub {
		my $self = shift;
		print "Ready for query\n";
		unless($init) {
			print "Server version " . $status{server_version} . "\n";
			++$init;
		}
		my $q = shift(@query_list);
		if($finished == 1) {
			print "run query\n";
			$self->simple_query(q{select * from nap_test.nap_1});
			++$finished;
			return;
		} elsif($finished == 2) {
			$loop->loop_stop;
		}

		if($q) {
			$self->simple_query($q);
		} else {
			$self->simple_query(q{copy nap_test.nap_1 (name,creation) from stdin});
		}
	},
	parameter_status => sub {
		my $self = shift;
		print "Parameter status\n";
		my %args = @_;
		$status{$_} = $args{status}->{$_} for sort keys %{$args{status}};
	},
	row_description => sub {
		my $self = shift;
		print "Row description\n";
		my %args = @_;
		print '[' . join(' ', map { $_->{name} } @{$args{description}{field}}) . "]\n";
	},
	data_row => sub {
		my $self = shift;
		print "Data row\n";
		my %args = @_;
		print '[' . join(',', map { $_->{data} } @{$args{row}}) . "]\n";
	}
);
$loop->add($client);
$client->connect;
$loop->loop_forever;
exit 0;
