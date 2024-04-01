#!/usr/bin/env perl

use strict;
use warnings;

use Data::Dumper::Concise;
use GraphQL::Client;
use YAML::XS qw(LoadFile);

my $config                 = LoadFile('octopus_account.yaml');
my $octopus_account_number = $config->{octopus_account_number};
my $octopus_api_key        = $config->{octopus_api_key};

my $query = qq(mutation { obtainKrakenToken(input: {APIKey: "$octopus_api_key"}){ token } });
my $operation_name    = 'obtainKrakenToken';
my $transport_options = {};

#my $query = <<'EOF';
#query ListSavingSessions {
#  savingSessions(accountNumber: "$octopus_account_number") {
#    events {
#      status
#    }
#  }
#}
#EOF
#my $operation_name    = 'ListSavingSessions';
#my $variables         = { octopus_account_number => $octopus_account_number, };
#my $transport_options = {
#    headers => {
#        authorization => "$octopus_api_key",
#    },
#};

my $graphql_client = GraphQL::Client->new( url => 'https://api.octopus.energy/v1/graphql/', );
print Dumper $graphql_client;
my $response       = $graphql_client->execute( $query );

print Dumper($response);
