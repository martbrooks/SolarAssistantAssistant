#!/usr/bin/env perl

use strict;
use warnings;
use Data::Dumper;
use Net::MQTT::Simple;
use YAML::XS 'LoadFile';

my $config = LoadFile('SAA.yaml');

print Dumper $config;

my %state = ();

my $sa_mqtt_server       = $config->{sa_mqtt_server};
my $sa_mqtt_port         = $config->{sa_mqtt_port};
my $sa_mqtt_topic_prefix = $config->{sa_mqtt_topic_prefix};

my $mqtt = Net::MQTT::Simple->new("$sa_mqtt_server:$sa_mqtt_port");
$mqtt->subscribe( $sa_mqtt_topic_prefix . "/#", \&received );

while (1) {
    $mqtt->tick();

    # Now do other stuff
    sleep(1);

    print "Load power: " . $state{solar_assistant}{inverter_1}{load_power}{state} . "\n";
}

$mqtt->disconnect();

sub received {
    my ( $topic, $message ) = @_;
    my @keys = split( '/', $topic );
    my $ref = \%state;
    for my $i ( 0 .. $#keys - 1 ) {
        my $k = $keys[$i];
        $ref->{$k} ||= {};
        $ref = $ref->{$k};
    }
    $ref->{ $keys[-1] } = $message;
}

