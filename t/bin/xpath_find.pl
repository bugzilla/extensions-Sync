#!/usr/bin/perl -w

use Data::Dumper;
use File::Slurp;
use XML::LibXML;

usage() if !$ARGV[0] || !$ARGV[1];

my $xml = read_file($ARGV[0]);

my $parser = XML::LibXML->new();
my $doc = $parser->parse_string($xml);
        
my $xpc = XML::LibXML::XPathContext->new($doc);
my $export_date = $xpc->find($ARGV[1]);
if ($export_date) {
    print $export_date->string_value() . "\n";
}
else {
    print "Not found.\n";
}

exit(0);

sub usage {
    print "Usage: xpath_find.pl <XML doc> <XPATH>\n";
    exit(1);
}