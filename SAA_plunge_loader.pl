#!/usr/bin/env perl

use strict;
use warnings;
use DateTime::Format::Strptime;
use DBI;
use JSON;
use LWP::UserAgent;
use YAML::XS 'LoadFile';

my $config = LoadFile('SAA.yaml');

my $plunge_db_driver   = $config->{plunge_db_driver}   // 'Pg';
my $plunge_db_password = $config->{plunge_db_password} // '';
my $plunge_db_host     = $config->{plunge_db_host}     // '';
my $plunge_db_name     = $config->{plunge_db_name}     // '';
my $plunge_db_user     = $config->{plunge_db_user}     // '';
my $plunge_threshold   = $config->{plunge_threshold}   // 0;

my $OCTOPUS_API = "https://api.octopus.energy/v1";
my $PRODUCT     = 'AGILE-FLEX-22-11-25/electricity-tariffs/E-1R-AGILE-FLEX-22-11-25-A';
my $ua          = LWP::UserAgent->new;
my $url         = "$OCTOPUS_API/products/$PRODUCT/standard-unit-rates/";
my $check_pages = 3;
my %plunge      = ();

$ua->agent("OctopusPlungeDetector/0.1");

while (1) {
    my $req = HTTP::Request->new( GET => "$url" );
    my $res = $ua->request($req);

    unless ( $res->is_success ) {
        print $res->status_line, "\n";
        exit 1;
    }

    my $data = JSON->new->utf8->decode( $res->content );

    foreach my $period ( @{ $data->{results} } ) {
        if ( $period->{value_inc_vat} <= $plunge_threshold ) {
            my $key           = $period->{valid_from};
            my $format        = DateTime::Format::Strptime->new( pattern => '%FT%T%z' );
            my $dt            = $format->parse_datetime($key);
            my $value_inc_vat = $period->{value_inc_vat};
            next if $dt < DateTime->now;
            $plunge{$key}{value_inc_vat} = sprintf( "%.3f", $value_inc_vat );
            $plunge{$key}{valid_to}      = $period->{valid_to};
        }
    }

    $url = $data->{next} // '';
    last if $url eq '' || $check_pages == 0;
    $check_pages--;
}

if ( scalar keys %plunge == 0 ) {
    exit 0;
}

my $dsn = "DBI:$plunge_db_driver:dbname=$plunge_db_name";
my $dbh = DBI->connect( $dsn, "$plunge_db_user", "$plunge_db_password", { RaiseError => 1 } ) or die $DBI::errstr;
my $sth = $dbh->prepare("INSERT INTO plunges VALUES ( ?, ?, ?)");
foreach my $key ( keys %plunge ) {
    my $rv = $sth->execute( $key, $plunge{$key}{valid_to}, $plunge{$key}{value_inc_vat} ) or die $DBI::errstr;
}
$dbh->disconnect();
