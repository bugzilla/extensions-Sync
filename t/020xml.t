# -*- Mode: perl; indent-tabs-mode: nil -*-
#
# The contents of this file are subject to the Mozilla Public
# License Version 1.1 (the "License"); you may not use this file
# except in compliance with the License. You may obtain a copy of
# the License at http://www.mozilla.org/MPL/
#
# Software distributed under the License is distributed on an "AS
# IS" basis, WITHOUT WARRANTY OF ANY KIND, either express or
# implied. See the License for the specific language governing
# rights and limitations under the License.
#
# The Original Code is the Sync Bugzilla Extension.
#
# The Initial Developer of the Original Code is Gervase Markham.
# Portions created by the Initial Developer are Copyright (C) 2011 the
# Initial Developer. All Rights Reserved.
#
# Contributor(s):
#   Written to the Glory of God by Gervase Markham <gerv@gerv.net>.

use strict;
use FindBin '$Bin';

use lib ("../../..", "../../../lib", "$Bin/lib");

use File::Spec::Functions;
use Data::Dumper;
use Test::More;

BEGIN {
    use Bugzilla;
    Bugzilla->extensions;
}

###############################################################################

use Bugzilla::Extension::Sync::XML;
use File::Slurp;
use XML::LibXML;

my @tests = (
  { 'name'   => 'empty',
    'struct' => {},
    'xml'    => '<R/>'
  },
  { 'name'   => 'Simple key/value',
    'struct' => { 'A' => 'B' },
    'xml'    => '<R A="B"/>'
  },
  { 'name'   => 'Simple nesting',
    'struct' => { 'A' => ['B'] },
    'xml'    => '<R><A>B</A></R>'
  },
  { 'name'   => 'Simple subhash',
    'struct' => { 'A' => { 'B' => 'C' } },
    'xml'    => '<R><A B="C"/></R>'
  },
  { 'name'   => 'Simple array',
    'struct' => { 'A' => ['B', 'C'] },
    'xml'    => '<R><A>B</A><A>C</A></R>'
  },
  { 'name'   => 'Complex hash',
    'struct' => { 'A' => ['B', { 'C' => 'D' }, { 'E' => ['F'] } ], 
                  'G' => 'H' },
    'xml'    => '<R G="H"><A>B</A><A C="D"/><A><E>F</E></A></R>'
  },
  { 'name'   => 'Very complex',
    'struct' => { 'A' => ['B', { 'C' => 'D', 'content' => 'E' }, { 'E' => { 'G' => 'H', 'content' => 'F' } }, {} ], 
                  'G' => 'H' },
    'xml'    => '<R G="H"><A>B</A><A C="D">E</A><A><E G="H">F</E></A><A/></R>'
  },
  { 'name'   => 'Attachments structure',
    'struct' => { 'X' => [ { 'L' => ['M'], 'S' => ['N'] }, { 'L' => ['O'], 'S' => ['P'] } ] },
    'xml'    => '<R><X><S>N</S><L>M</L></X><X><S>P</S><L>O</L></X></R>'
  },
);

###############################################################################
# structure_to_libxml
###############################################################################
sub test_structure_to_libxml {
    foreach my $test (@tests) {
        my $root = XML::LibXML::Element->new("R");
        structure_to_libxml($test->{'struct'}, $root);
        my $xml = $root->toString();
        is($xml, $test->{'xml'}, "S to LI - " . $test->{'name'});
    }    
}

###############################################################################
# libxml_to_structure
###############################################################################
sub test_libxml_to_structure {
    my $parser = XML::LibXML->new();
    
    foreach my $test (@tests) {
        my $doc = $parser->parse_string($test->{'xml'});
        is($@, "", "XML parsing succeeded for " . $test->{'xml'});
        
        my $result = libxml_to_structure($doc);
        $result = $result->{'R'};
        is_deeply($result, $test->{'struct'}, "LI to S: " . $test->{'name'});
    }
}

###############################################################################

test_structure_to_libxml();
test_libxml_to_structure();

done_testing();
