#!/usr/bin/env perl

use strict;
use warnings;

use Data::Dumper::Concise;
use DateTime;
use DBI;
use JSON;
use LWP::UserAgent;
use Net::MQTT::Simple;
use String::Pad qw(pad);
use Term::ANSIColor;
use Time::Duration;
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

unless ( -e $sqlite_file ) {
    create_database();
    refresh_period_data();
}

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
    my $current_rate   = get_current_rate();
    my $period_expires = period_data_expiration();

    _debug("$battery_charge_pcent Inverter mode: $device_mode; Current rate: $current_rate; Rate period data expires in $period_expires");

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

sub period_data_expiration {
    my $dbh = DBI->connect( "dbi:SQLite:$sqlite_file", "", "" );
    my $sth = $dbh->prepare("SELECT MAX(period_end) FROM period_rates");
    $sth->execute();
    my $last_period = $sth->fetchrow_array;
    $sth->finish();
    $dbh->disconnect();
    my $now = Time::Piece->new;
    $last_period = Time::Piece->strptime( $last_period, '%Y-%m-%d %H:%M:%S' );
    my $age = $last_period - $now;

    if ( $age < 60 * 60 * 6 ) {
        _debug("Refreshing period data.");
        refresh_period_data();
    }
    return $age;
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

sub refresh_period_data {
    my $OCTOPUS_API = "https://api.octopus.energy/v1";
    my $PRODUCT     = 'AGILE-FLEX-22-11-25/electricity-tariffs/E-1R-AGILE-FLEX-22-11-25-A';
    my $url         = "$OCTOPUS_API/products/$PRODUCT/standard-unit-rates/";
    my $check_pages = 3;
    my $ua          = LWP::UserAgent->new;
    $ua->agent("OctopusPlungeDetector/0.1");
    my $dbh = DBI->connect( "dbi:SQLite:$sqlite_file", "", "" );
    my $sth = $dbh->prepare("INSERT INTO period_rates (period_start,period_end,rate) VALUES ( ?, ?, ?)");

    while (1) {
        my $req = HTTP::Request->new( GET => "$url" );
        my $res = $ua->request($req);

        unless ( $res->is_success ) {
            print $res->status_line, "\n";
            exit 1;
        }

        my $data = JSON->new->utf8->decode( $res->content );
        foreach my $period ( @{ $data->{results} } ) {
            my $period_start = _to_sqlite_time( $period->{valid_from} );
            my $period_end   = _to_sqlite_time( $period->{valid_to} );
            my $rate         = $period->{value_inc_vat};
            $sth->execute( $period_start, $period_end, $rate );
        }

        $url = $data->{next} // '';
        last if $url eq '' || $check_pages == 0;
        $check_pages--;
    }

    $sth = $dbh->prepare("DELETE FROM period_rates WHERE period_end <= datetime()");
    $sth->execute();
    $dbh->disconnect();
}

sub create_database {
    my $dbh = DBI->connect( "dbi:SQLite:$sqlite_file", "", "" );
    $dbh->do("CREATE TABLE period_rates (period_start TIMESTAMP, period_end TIMESTAMP, rate REAL)");
    $dbh->disconnect();
}

sub _to_sqlite_time {
    my $time = shift;
    my $t    = Time::Piece->strptime( $time, "%Y-%m-%dT%H:%M:%SZ" );
    return $t->strftime("%Y-%m-%d %H:%M:%S");
}

sub _debug {
    return unless $debug == 1;
    my $message = shift;
    my $now     = DateTime->now->strftime('%Y-%m-%dT%H:%M:%S%z');
    print "[$now] $message\n";
}
