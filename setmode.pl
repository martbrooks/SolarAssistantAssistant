#!/usr/bin/env perl

use strict;
use warnings;
use Data::Dumper;
use DateTime;
use DateTime::Format::ISO8601;
use DBI;
use Net::MQTT::Simple;
use Time::Piece;
use YAML::XS 'LoadFile';

my $debug  = 1;
my $config = LoadFile('SAA.yaml');
my %state  = ();

my $inverter_id          = 'inverter_' . $config->{inverter_id};
my $plunge_db_driver     = $config->{plunge_db_driver}   // 'Pg';
my $plunge_db_password   = $config->{plunge_db_password} // '';
my $plunge_db_host       = $config->{plunge_db_host}     // '';
my $plunge_db_name       = $config->{plunge_db_name}     // '';
my $plunge_db_user       = $config->{plunge_db_user}     // '';
my $poll_interval        = $config->{poll_interval}      // ( $debug == 1 ? 5 : 60 );
my $sa_mqtt_port         = $config->{sa_mqtt_port};
my $sa_mqtt_server       = $config->{sa_mqtt_server};
my $sa_mqtt_topic_prefix = $config->{sa_mqtt_topic_prefix};

my $mqtt = Net::MQTT::Simple->new("$sa_mqtt_server:$sa_mqtt_port");
$mqtt->subscribe( $sa_mqtt_topic_prefix . '/#', \&received );
$mqtt->tick();

while (1) {
    change_inverter_mode('Grid first');
}

$mqtt->disconnect();

sub change_inverter_mode {
    my ($newmode) = @_;
    my $topic = "solar_assistant/$inverter_id/work_mode_priority/set";
    _debug("Changing inverter to '$newmode'.");
    $mqtt->publish( $topic => $newmode );
    sleep(3);
}

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
    my $message      = shift;
    my $current_time = gmtime;
    my $dt           = DateTime->from_epoch( epoch => $current_time->epoch, time_zone => 'local' );
    my $ts           = $dt->strftime('%Y-%m-%dT%H:%M:%S%z');
    print "[$ts] $message\n";
}
