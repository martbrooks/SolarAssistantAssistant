#!/usr/bin/env perl

use strict;
use warnings;
use Data::Dumper;
use DateTime;
use DateTime::Format::ISO8601;
use DBI;
use Net::MQTT::Simple;
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

my $dsn = "DBI:$plunge_db_driver:dbname=$plunge_db_name";
my $dbh = DBI->connect( $dsn, "$plunge_db_user", "$plunge_db_password", { RaiseError => 1 } ) or die $DBI::errstr;

my $mqtt = Net::MQTT::Simple->new("$sa_mqtt_server:$sa_mqtt_port");
$mqtt->subscribe( $sa_mqtt_topic_prefix . '/#', \&received );
$mqtt->tick();

while (1) {
    my $device_mode = $state{solar_assistant}{$inverter_id}{device_mode}{state} // '<Unknown>';
    my ( $plunge_start, $plunge_end, $plunge_price ) = in_plunge_window();
    _debug( "Device mode: $device_mode; Plunge Window: " . ( $plunge_price ? 'No' : 'Yes (' . $plunge_price . 'p)' ) );

    #    if ( $device_mode ne 'Unknown' && $device_mode ne 'Battery first' ) {
    #        change_inverter_node();
    #    }
    sleep($poll_interval);
    $mqtt->tick();
}

$mqtt->disconnect();
$dbh->disconnect();

sub in_plunge_window {
    my $sth    = $dbh->prepare("select * from plunges where plunge_start <= now() and plunge_end >= now();");
    my $rv     = $sth->execute() or die $DBI::errstr;
    my $result = $sth->fetchrow_hashref;
    if ($result) {
        return ( $result->{plunge_start}, $result->{plunge_end}, $result->{value_inc_vat} );
    }
}

sub change_inverter_mode {
    my $newmode = shift;
    $newmode = 'Battery first';
    my $topic = "/solar_assistant/$inverter_id/device_mode/state";
    $mqtt->publish( $topic => $newmode );
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
    my $message = shift;
    my $dt      = DateTime->now;
    my $ts      = $dt->iso8601;
    print "[$ts] $message\n";
}
