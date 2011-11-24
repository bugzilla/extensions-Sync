#!/usr/bin/perl -w
use XML::Validator::Schema;
use XML::SAX::ParserFactory;
use File::Slurp;

my $schema = $ARGV[0];
my $xml = read_file($ARGV[1]);

my $validator = XML::Validator::Schema->new(file  => $schema,
                                            cache => 1);
my $parser = XML::SAX::ParserFactory->parser(Handler => $validator);

eval { $parser->parse_string($xml) };

if ($@) {
    warn "Validation failed";
}

