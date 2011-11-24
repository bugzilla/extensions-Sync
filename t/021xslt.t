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

use lib ("../../..", "../../../lib", "$Bin/lib", "lib");

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
use Bugzilla::Constants;
use Test::XML;

my $map = {
    'TicketNo Supplier'   => 'COMPANY-ISSUE-INFOS/COMPANY-ISSUE-INFO[@SI="database id"][COMPANY-REF="WernhamHogg"]/ISSUE-ID',
    'TicketNo'            => 'COMPANY-ISSUE-INFOS/COMPANY-ISSUE-INFO[@SI="database id"][COMPANY-REF="Initech"]/ISSUE-ID',
    'Title'               => 'LONG-NAME',
    'Error Description'   => 'ISSUE-DESC/P[@SI="description"]',
    'Recorded By'         => 'COMPANY-ISSUE-INFOS/COMPANY-ISSUE-INFO[@SI="role"]/TEAM-MEMBER-REF[@SI="recorder"]',
    'Recorded Date'       => 'ISSUE-DESC/P[@SI="recorded-date"]',
    'Problem Finder'      => 'COMPANY-ISSUE-INFOS/COMPANY-ISSUE-INFO[@SI="role"]/TEAM-MEMBER-REF[@SI="finder"]',
    'Model Involved'      => 'ISSUE-ENVIRONMENT/PROJECT-IDS/PROJECT-ID[@SI="model involved"]',
    'Assigned ECU'        => 'ISSUE-ENVIRONMENT/ENGINEERING-OBJECTS/ENGINEERING-OBJECT[CATEGORY="assigned ecu"]/SHORT-LABEL',
    'Error Occurrence'    => 'ISSUE-DESC/P[@SI="error-occurrence"]',
    'Status Initech'      => 'ISSUE-PLANNING-INFOS/ISSUE-CURRENT-STATE/ISSUE-STATE[@SI="status-Initech"]',
    'Problem Severity'    => 'ISSUE-PLANNING-INFOS/ISSUE-SEVERITY',
    'System Stability'    => 'ISSUE-PLANNING-INFOS/ISSUE-SEVERITY/@SI',
    'Involved I-Step'     => 'ISSUE-DESC/P[@SI="occurrence-milestone"]',
    'Problem Category 1'  => 'ISSUE-DESC/P[@SI="category-1"]',
    'Problem Category 2'  => 'ISSUE-DESC/P[@SI="category-2"]',
    'Problem Category 3'  => 'ISSUE-DESC/P[@SI="category-3"]',
    'Affected ECU'        => 'ISSUE-ENVIRONMENT/ENGINEERING-OBJECTS/ENGINEERING-OBJECT[CATEGORY="affected ecu"]/SHORT-LABEL',
    'Variant'             => 'ISSUE-ENVIRONMENT/ENGINEERING-OBJECTS/ENGINEERING-OBJECT/SDGS/SDG[@GID="variants"]/SD[@GID="ECU variant"]',
    'ECU HW'              => 'ISSUE-ENVIRONMENT/ENGINEERING-OBJECTS/ENGINEERING-OBJECT[CATEGORY="assigned ecu"]/SDGS/SDG/SD[@GID="hw version"]',
    'ECU SW'              => 'ISSUE-ENVIRONMENT/ENGINEERING-OBJECTS/ENGINEERING-OBJECT[CATEGORY="assigned ecu"]/SDGS/SDG/SD[@GID="sw version"]',
    'Status Supplier'     => 'ISSUE-SOLUTIONS/ISSUE-SOLUTION/ISSUE-SOLUTION-DESC/P[@SI="status"]',
    'Analysis Team'       => 'COMPANY-ISSUE-INFOS/COMPANY-ISSUE-INFO[@SI="role"]/TEAM-MEMBER-REF[@SI="analysis"]',
    'Target I-Step'       => 'ISSUE-PLANNING-INFOS/DELIVERY-MILESTONE',
    'Initech Responsible' => 'COMPANY-ISSUE-INFOS/COMPANY-ISSUE-INFO[@SI="role"][COMPANY-REF="Initech"]/TEAM-MEMBER-REF[@SI="responsible"]',
    'Planned Closing Version'              => 'ISSUE-SOLUTIONS/ISSUE-SOLUTION/ISSUE-SOLUTION-DESC/P[@SI="planned-closing-version"]',
    'Required Release Date'                => 'ISSUE-PLANNING-INFOS/DELIVERY-DATE',
    'Feedback Supplier'                    => 'ISSUE-SOLUTIONS/ISSUE-SOLUTION/ISSUE-SOLUTION-DESC/P[@SI="feedback"]',
    'Committed Solution Availability Date' => 'ISSUE-SOLUTIONS/ISSUE-SOLUTION/ISSUE-SOLUTION-DESC/P[@SI="committed-date"]',
    'Supplier Responsible'                 => 'COMPANY-ISSUE-INFOS/COMPANY-ISSUE-INFO[@SI="role"][COMPANY-REF="WernhamHogg"]/TEAM-MEMBER-REF[@SI="responsible"]',
    'Initech Comments'    => 'ISSUE-DESC/P[@SI="Initech-comments"]',
    'Supplier Tracking'   => 'ISSUE-DESC/P[@SI="supplierTracking"]',
    'Closed In Version'   => 'ISSUE-SOLUTIONS/ISSUE-SOLUTION/ISSUE-SOLUTION-DESC/P[@SI="closed-in-version"]',
    'Modified'            => 'ISSUE-PLANNING-INFOS/ISSUE-CURRENT-STATE/DATE',
    'Attachments'         => 'ISSUE-DESC/P[@SI="attachment"]',
};

my $data = {
    'Problem Category 3' => 'Cat3',
    'Involved I-Step' => 'E060-03-12-500',
    'Status Supplier' => 'Status',
    'Problem Finder' => 'Finding Person',
    'Error Occurrence' => '01-single event',
    'Planned Closing Version' => 'PCV',
    'Initech Comments' => 'Initech Comments',
    'Initech Responsible' => 'team2',
    'Closed In Version' => 'CIV',
    'Affected ECU' => 'HUBBA HUBBA',
    'ECU SW' => 'sw ecu2',
    'Assigned ECU' => 'HU BB',
    'System Stability' => 'PrSS1',
    'TicketNo Supplier' => '123456',
    'Required Release Date' => '2012-03-01',
    'Model Involved' => 'X60,X61,X62,X63,X64',
    'Problem Category 1' => 'Software',
    'Status Initech' => '04-Under work',
    'Variant' => 'ECU Variant',
    'Recorded By' => 'Recording Team',
    'Problem Category 2' => 'Application',
    'Feedback Supplier' => 'Feedback',
    'Target I-Step' => 'Milestone',
    'Title' => 'Long Name',
    'Error Description' => 'This is the description.',
    'Modified' => '2006-01-31T17:51:01',
    'ECU HW' => 'hw ecu2',
    'Problem Severity' => '03-permanent unsatisfactory',
    'Committed Solution Availability Date' => 'CD',
    'Recorded Date' => '2004-11-23T00:00:00',
    'Supplier Tracking' => 'Yes',
    'TicketNo' => '34',
    'Analysis Team' => 'team3',
    'Supplier Responsible' => 'team4',
    'Attachments' => { 'SI' => 'attachment', 'XFILE' => [
                     {
                       'ID' => 'ATTACH-1',
                       'SHORT-NAME' => [ 'att-1.dat' ],
                       'LONG-NAME-1' => [ 'BUG_34_notification.log' ]
                     },
                     {
                       'ID' => 'ATTACH-2',
                       'SHORT-NAME' => [ 'att-2.dat' ],
                       'LONG-NAME-1' => [ 'BUG_34_chars1.csv' ]
                     }
                   ]
    }
};

###############################################################################
# extract_with_xpath
###############################################################################
sub test_extract_with_xpath {
    my $extdir = Bugzilla::Constants::bz_locations()->{'extensionsdir'};
    my $xml = read_file($extdir . "/Sync/t/xml/xslt-test.xml");

    # Parse XML
    my $parser = XML::LibXML->new();
    my $doc;
    
    eval {
        $doc = $parser->parse_string($xml);
    };
    is("", $@, "Parse succeeded");
    
    my $issuelist = $doc->getElementsByTagName("ISSUE");
    
    foreach my $xmlissue (@$issuelist) {
        # Use XPath to reduce to sensible struct
        my $issue = extract_with_xpath($xmlissue, $map);
        isnt(undef, $issue);
        
        foreach my $key (keys %$data) {
            is_deeply($issue->{$key}, $data->{$key}, "$key extract correct");
        }
    }
}

###############################################################################
# populate_with_xpath
###############################################################################
sub test_populate_with_xpath {
    my $parser = XML::LibXML->new();
    my $orig;
    my $extdir = Bugzilla::Constants::bz_locations()->{'extensionsdir'};
    my $xml = read_file($extdir . "/Sync/t/xml/xslt-test.xml");
    
    eval {
        $orig = $parser->parse_string($xml);
    };
    is("", $@, "Parse succeeded");
        
    # First test is idempotency; second is population
    my @files = ('xslt-test.xml', 'xslt-bare.xml');
    
    foreach my $file (@files) {
        my $xml = read_file($extdir . "/Sync/t/xml/" . $file);
        my $doc;
        
        eval {
            $doc = $parser->parse_string($xml);
        };
        is("", $@, "Parse succeeded");
        
        my $issuelist = $doc->getElementsByTagName("ISSUE");
        
        populate_with_xpath($issuelist->[0], $map, $data);
        
        is_xml($doc->toString(), 
               $orig->toString(), 
               "XML OK for file $file");
    }
}

test_extract_with_xpath();
test_populate_with_xpath();

done_testing();
