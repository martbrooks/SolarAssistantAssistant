#!/usr/bin/env perl

use strict;
use warnings;

use Data::Dumper::Concise;
use DateTime;
use DBI;
use Net::MQTT::Simple;
use String::Pad qw(pad);
use Term::ANSIColor;
use Time::Piece;
use YAML::XS 'LoadFile';

my $debug  = 1;
my $config = LoadFile('SAA.yaml');
my %state  = ();

my $inverter_id          = 'inverter_' . $config->{inverter_id};
my $sqlite_file          = $config->{database_file} // 'period_rates.db';
my $poll_interval        = $config->{poll_interval} // ( $debug == 1 ? 5 : 60 );
my $sa_mqtt_port         = $config->{sa_mqtt_port};
my $sa_mqtt_server       = $config->{sa_mqtt_server};
my $sa_mqtt_topic_prefix = $config->{sa_mqtt_topic_prefix};

my $mqtt = Net::MQTT::Simple->new("$sa_mqtt_server:$sa_mqtt_port");
$mqtt->subscribe( $sa_mqtt_topic_prefix . '/#', \&received );
$mqtt->tick();

while (1) {
    my $device_mode    = $state{solar_assistant}{$inverter_id}{device_mode}{state} // '<Unknown>';
    my $preferred_mode = '<Unknown>';

    if ( $device_mode eq '<Unknown>' ) {
        sleep(1);
        $mqtt->tick();
        next;
    }

    my $battery_charge_pcent = $state{solar_assistant}{total}{battery_state_of_charge}{state} // 0;
    $battery_charge_pcent = colour_battery_pcent($battery_charge_pcent);
    my $current_rate = get_current_rate();

    _debug("$battery_charge_pcent Inverter mode: $device_mode; Current rate: $current_rate");

    sleep($poll_interval);
    $mqtt->tick();
}

$mqtt->disconnect();

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
    %state = ();
    my $ref  = \%state;
    for my $i ( 0 .. $#keys - 1 ) {
        my $k = $keys[$i];
        $ref->{$k} ||= {};
        $ref = $ref->{$k};
    }
    $ref->{ $keys[-1] } = $message;
}

sub get_current_rate {
    my $dbh = DBI->connect( "dbi:SQLite:$sqlite_file", "", "" );
    my $sth = $dbh->prepare("SELECT *  FROM period_rates WHERE period_start <= CURRENT_TIMESTAMP and period_end >= CURRENT_TIMESTAMP");
    $sth->execute();
    my $rate = $sth->fetchrow_hashref;
    $sth->finish();
    $dbh->disconnect();
    return sprintf( '%.2f', $rate->{rate} );
}

sub colour_battery_pcent {
    my $charge_pcent = shift;
    my ( $r, $g ) = ( 0, 0 );
    if ( $charge_pcent <= 50 ) {
        $r = 255;
        $g = int( 255 * ( $charge_pcent / 50 ) );
    } else {
        $r = int( 255 * ( ( 100 - $charge_pcent ) / 50 ) );
        $g = 255;
    }
    my $background = sprintf( "on_r%03dg%03db%03d", $r, $g, 0 );
    my $battery    = pad( "$charge_pcent%", 9, "c" );
    return color("black $background") . $battery . color('reset');
}

sub _debug {
    return unless $debug == 1;
    my $message      = shift;
    my $current_time = gmtime;
    my $dt           = DateTime->from_epoch( epoch => $current_time->epoch, time_zone => 'local' );
    my $ts           = $dt->strftime('%Y-%m-%dT%H:%M:%S%z');
    print "[$ts] $message\n";
}