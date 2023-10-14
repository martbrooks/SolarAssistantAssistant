#!/usr/bin/env perl

use strict;
use warnings;
use Data::Dumper;
use DateTime;
use DateTime::Format::ISO8601;
use Net::MQTT::Simple;
use YAML::XS 'LoadFile';

my $debug  = 1;
my $config = LoadFile('SAA.yaml');
my %state  = ();

my $sa_mqtt_server       = $config->{sa_mqtt_server};
my $sa_mqtt_port         = $config->{sa_mqtt_port};
my $sa_mqtt_topic_prefix = $config->{sa_mqtt_topic_prefix};
my $inverter_id          = 'inverter_' . $config->{inverter_id};

my $mqtt = Net::MQTT::Simple->new("$sa_mqtt_server:$sa_mqtt_port");
$mqtt->subscribe( $sa_mqtt_topic_prefix . "/#", \&received );

while (1) {
    $mqtt->tick();

    # Now do other stuff
    sleep(10);

    _debug( "Load power: " . $state{solar_assistant}{$inverter_id}{load_power}{state} // '<Unknown>' );
}

$mqtt->disconnect();

sub received {
    my ( $topic, $message ) = @_;
    my @keys = split( '/', $topic );
    my $ref  = \%state;
    for my $i ( 0 .. $#keys - 1 ) {
        my $k = $keys[$i];
        $ref->{$k} ||= {};
        $ref = $ref->{$k};
    }
    $ref->{ $keys[-1] } = $message;
}

sub _debug {
    return unless $debug == 1;
    my $message = shift;
    my $dt      = DateTime->now;
    my $ts      = $dt->iso8601;
    print "[$ts] $message\n";
}
