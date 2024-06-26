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
use Time::Duration;
use Time::Piece;
use YAML::XS 'LoadFile';

my $config = LoadFile('SAA.yaml');
my %state  = ();

my $inverter_id          = 'inverter_' . $config->{inverter_id};
my $default_work_mode    = $config->{default_work_mode} // 'Load first';
my $sqlite_file          = $config->{database_file}     // 'period_rates.db';
my $poll_interval        = $config->{poll_interval}     // 60;
my $sa_mqtt_port         = $config->{sa_mqtt_port};
my $sa_mqtt_server       = $config->{sa_mqtt_server};
my $sa_mqtt_topic_prefix = $config->{sa_mqtt_topic_prefix};

unless ( -e $sqlite_file ) {
    create_database();
    refresh_period_data();
}

my $current_work_mode = '<Unknown>';
my $mqtt              = Net::MQTT::Simple->new("$sa_mqtt_server:$sa_mqtt_port");
$mqtt->subscribe( $sa_mqtt_topic_prefix . '/#', \&received );
$mqtt->tick();

while (1) {
    print "Waiting for SolarAssistant data....\n";
    $current_work_mode   = $state{solar_assistant}{$inverter_id}{device_mode}{state} // '<Unknown>';
    if ( $current_work_mode eq '<Unknown>' ) {
        sleep(5);
        $mqtt->tick();
    } else {
        print "SolarAssistant data received.\n";
        last;
    }
}

my $preferred_work_mode = $default_work_mode;

if ( $current_work_mode eq '<Unknown>' ) {
    sleep(1);
    $mqtt->tick();
    next;
}

my $battery_charge_pcent = $state{solar_assistant}{total}{battery_state_of_charge}{state} // 0;
my ( $winning_rule, $preferred_work_mode ) = consult_the_rules($battery_charge_pcent);

my $current_rate = get_current_rate();

my $period_expires = period_data_expiration();
if ( $period_expires < 0 ) {
    refresh_period_data();
    $period_expires = period_data_expiration();
}

my $infoline = "Batt: $battery_charge_pcent\%; ";
$infoline .= " Curr mode: $current_work_mode; ";
$infoline .= "Pref mode: $preferred_work_mode; ";
$infoline .= "Curr rate: $current_rate; ";
$infoline .= "Winning rule: \'$winning_rule\'";

if ( $current_work_mode ne $preferred_work_mode ) {
    change_inverter_mode( $current_work_mode, $preferred_work_mode );
}

_debug($infoline);

sub consult_the_rules {
    my $battery_charge_pcent = shift;
    my $ruleset              = LoadFile('rules.yaml');
    my %results              = ();
    foreach my $rule ( @{ $ruleset->{rules} } ) {
        my $rulename     = $rule->{Name};
        my $rule_matches = 0;
        foreach my $conditions ( @{ $rule->{Conditions} } ) {
            my %conditions = %{$conditions};
            $results{$rulename}{Priority}   = $rule->{Priority};
            $results{$rulename}{ModeIfTrue} = $rule->{ModeIfTrue};
            foreach my $condition ( sort keys %conditions ) {
                my $wanted = $conditions{$condition};
                if ( $condition eq 'NotBefore' )       { $results{$rulename}{conditions}{$condition} = check_hhmm_notbefore($wanted); }
                if ( $condition eq 'NotAfter' )        { $results{$rulename}{conditions}{$condition} = check_hhmm_notafter($wanted); }
                if ( $condition eq 'BatteryLessThan' ) { $results{$rulename}{conditions}{$condition} = check_battery_lessthan( $wanted, $battery_charge_pcent ); }
                if ( $condition eq 'BatteryMoreThan' ) { $results{$rulename}{conditions}{$condition} = check_battery_morethan( $wanted, $battery_charge_pcent ); }
                if ( $condition eq 'RateLessThan' )    { $results{$rulename}{conditions}{$condition} = check_rate_lessthan( $wanted, get_current_rate() ); }
            }
        }
    }
    my $priority            = 9999;
    my $preferred_work_mode = $default_work_mode;
    my $winning_rule        = 'Fallback rule';
    foreach my $rulename ( keys %results ) {
        next unless ( keys %{ $results{$rulename}{conditions} } ) > 0;
        my $failed = grep { $_ == 0 } values %{ $results{$rulename}{conditions} };
        unless ($failed) {
            if ( $results{$rulename}{Priority} < $priority ) {
                $winning_rule        = $rulename;
                $priority            = $results{$rulename}{Priority};
                $preferred_work_mode = $results{$rulename}{ModeIfTrue};
            }
        }
    }
    return ( $winning_rule, $preferred_work_mode );
}

sub check_hhmm_notbefore {
    my $wanted = shift;
    $wanted = parse_hour_to_datetime($wanted);
    my $now = DateTime->now( time_zone => 'local' );
    if ( $now > $wanted ) {
        return 1;
    } else {
        return 0;
    }
}

sub check_hhmm_notafter {
    my $wanted = shift;
    $wanted = parse_hour_to_datetime($wanted);
    my $now = DateTime->now( time_zone => 'local' );
    if ( $now < $wanted ) {
        return 1;
    } else {
        return 0;
    }
}

sub check_battery_lessthan {
    my $wanted = shift;
    my $actual = shift;
    if ( $actual <= $wanted ) {
        return 1;
    } else {
        return 0;
    }
}

sub check_battery_morethan {
    my $wanted = shift;
    my $actual = shift;
    if ( $actual >= $wanted ) {
        return 1;
    } else {
        return 0;
    }
}

sub check_rate_lessthan {
    my $wanted = shift;
    my $rate   = shift;
    if ( $rate <= $wanted ) {
        return 1;
    } else {
        return 0;
    }
}

sub parse_hour_to_datetime {
    my $given_time = shift;
    my ( $given_hour, $given_minute ) = split( ':', $given_time );
    my $dt_now             = DateTime->now( time_zone => 'local' );
    my $dt_with_given_time = DateTime->new(
        year      => $dt_now->year,
        month     => $dt_now->month,
        day       => $dt_now->day,
        hour      => $given_hour,
        minute    => $given_minute,
        second    => 0,
        time_zone => 'local',
    );
    return $dt_with_given_time;
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
    $ref->{LastUpdate} = DateTime->now( time_zone => 'local' );
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
    $rate = $rate->{rate} // 0;
    return sprintf( '%.2f', $rate );
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

sub _datetime_diff {
    my ( $dt1, $dt2 ) = @_;
    return $dt1->epoch - $dt2->epoch;
}

sub _to_sqlite_time {
    my $time = shift;
    my $t    = Time::Piece->strptime( $time, "%Y-%m-%dT%H:%M:%SZ" );
    return $t->strftime("%Y-%m-%d %H:%M:%S");
}

sub _debug {
    my $message = shift;
    my $now     = DateTime->now( time_zone => 'local' )->strftime('%Y-%m-%dT%H:%M:%S%z');
    print "[$now] $message\n";
}
