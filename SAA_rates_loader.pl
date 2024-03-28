#!/usr/bin/env perl

use strict;
use warnings;

use DBI;
use JSON;
use LWP::UserAgent;
use Time::Piece;
use YAML::XS 'LoadFile';

my $config      = LoadFile('SAA.yaml');
my $sqlite_file = $config->{database_file} // 'period_rates.db';

unless ( -e $sqlite_file ) {
    create_database();
}

my $OCTOPUS_API = "https://api.octopus.energy/v1";
my $PRODUCT     = 'AGILE-FLEX-22-11-25/electricity-tariffs/E-1R-AGILE-FLEX-22-11-25-A';
my $ua          = LWP::UserAgent->new;
my $url         = "$OCTOPUS_API/products/$PRODUCT/standard-unit-rates/";
my $check_pages = 3;
my %plunge      = ();

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