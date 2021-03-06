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

package Bugzilla::Extension::Sync;
use strict;

use constant NAME => 'Sync';

use constant REQUIRED_MODULES => [
    {
        package => 'Tie-IxHash',
        module  => 'Tie::IxHash',
        version => 0,
    },
    {
        package => 'Clone',
        module  => 'Clone',
        version => 0,
    },
    {
        package => 'Data-Visitor',
        module  => 'Data::Visitor',
        version => 0,
    },
    {
        package => 'DateTime-Format',
        module  => 'DateTime::Format::XSD',
        version => 0,
    },
    {
        package => 'DateTime-Format',
        module  => 'DateTime::Format::MySQL',
        version => 0,
    },
    {
        package => 'XML-LibXML',
        module  => 'XML::LibXML',
        version => 0,
    },
    {
        package => 'XML-LibXML-XPathContext',
        module  => 'XML::LibXML::XPathContext',
        version => 0,
    },
    {
        package => 'TheSchwartz',
        module  => 'TheSchwartz',
        version => "1.10",
        feature => ['jobqueue'],
    },
    {
        package => 'Test-Exception',
        module  => 'Test::Exception',
        version => 0,
    },
];

use constant OPTIONAL_MODULES => [
    {
        package => 'LWP',
        module  => 'LWP::UserAgent',
        version => 0,
        feature => ["sync_test"]
    },
    {
        package => 'Test-Deep',
        module  => 'Test::Deep',
        version => 0,
        feature => ["sync_test"]
    },
    {
        package => 'Test-XML',
        module  => 'Test::XML',
        version => 0,
        feature => ["sync_test"]
    },
];

__PACKAGE__->NAME;
