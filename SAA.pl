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

my $dsn = "DBI:$plunge_db_driver:dbname=$plunge_db_name";
my $dbh = DBI->connect( $dsn, "$plunge_db_user", "$plunge_db_password", { RaiseError => 1 } ) or die $DBI::errstr;

my $mqtt = Net::MQTT::Simple->new("$sa_mqtt_server:$sa_mqtt_port");
$mqtt->subscribe( $sa_mqtt_topic_prefix . '/#', \&received );
$mqtt->tick();

while (1) {
    my $device_mode    = $state{solar_assistant}{$inverter_id}{device_mode}{state} // '<Unknown>';
    my $preferred_mode = preferred_mode();
    my ( $plunge_start, $plunge_end, $plunge_price ) = in_plunge_window();
    my $plunge_info      = 'No';
    my $is_plunge_window = 0;
    if ( defined $plunge_price ) {
        $plunge_info      = 'Yes (' . $plunge_price . 'p)';
        $is_plunge_window = 1;
    }
    _debug("Inverter mode: $device_mode; Preferred mode: $preferred_mode; Plunge Window: $plunge_info");

    if ( $device_mode eq '<Unknown>' ) {
        sleep($poll_interval);
        $mqtt->tick();
        next;
    }

    if ( $is_plunge_window && $device_mode ne 'Battery first' ) {
        change_inverter_mode( $device_mode, 'Battery first' );
    }

    if ( !$is_plunge_window && $device_mode ne 'Load first' ) {
        change_inverter_mode( $device_mode, 'Load first' );
    }

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

sub preferred_mode {
    my $sth    = $dbh->prepare("select inverter_mode from preferred_mode_times where start_time <= now()::time and finish_time >= now()::time;");
    my $rv     = $sth->execute() or die $DBI::errstr;
    my $result = $sth->fetchrow_hashref;
    if ($result) {
        return ( $result->{inverter_mode} );
    }
}

sub change_inverter_mode {
    my ( $curmode, $newmode ) = @_;
    my $topic = "solar_assistant/$inverter_id/work_mode_priority/set";
    _debug("Changing inverter from '$curmode' to '$newmode'.");
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
