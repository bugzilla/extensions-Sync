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
use TestUtils;

pre_testing();

###############################################################################

use Bugzilla;
use Bugzilla::Extension::Sync::Util;
use MockBug;

test_set_from_name();
test_find_setter();
test_field_error();
test_get_bug_for();

done_testing();

# XXXValeo-specific
###############################################################################
# set_from_name
###############################################################################
sub test_set_from_name {
    my $bug = new MockBug({ product => "doesntmatter" });
    Bugzilla::Extension::Sync::Util::set_from_name($bug, 
                                                   "product", 
                                                   "DAG RVC 2.0");
    is($bug->{'product_id'}, 3);

    Bugzilla::Extension::Sync::Util::set_from_name($bug, "component", "HW");
    is($bug->{'component_id'}, 7);

    $bug = new MockBug({ product => "doesntmatter" });
    local *Bugzilla::Extension::Sync::Util::error = sub { return; };
    Bugzilla::Extension::Sync::Util::set_from_name($bug, 
                                                   "product", 
                                                   "Doesn'tExist");
    is($bug->{'product_id'}, undef);

    Bugzilla::Extension::Sync::Util::set_from_name($bug, 
                                                   "component", 
                                                   "Doesn'tExist");
    is($bug->{'component_id'}, undef);
}

###############################################################################
# find_setter
###############################################################################
sub test_find_setter {
    my $bug = new MockBug({ 
        set_severity => sub { return "set_severity retval"; },
        set_url => sub { return "set_url retval"; },
        product => sub { $_[0]->{'product_accessed'} = 1; }
    });

    my $setter = find_setter($bug, "bug_severity");
    my $result = $setter->("extreme");
    is($result, "set_severity retval");

    $setter = find_setter($bug, "product");
    $result = $setter->("DAG RVC 2.0");
    is($bug->{'product_id'}, 3);

    $setter = find_setter($bug, "component");
    $result = $setter->("HW");
    is($bug->{'component_id'}, 7);
}

###############################################################################
# field_error
###############################################################################
sub test_field_error {
    local *Bugzilla::Extension::Sync::Util::record_error_message = sub { };

    my $bug = new MockBug({
        add_comment     => sub { $_[0]->{'comments'} = [$_[1]]; },
        modify_keywords => sub { $_[0]->{'keywords'} = [$_[1]]; }
    });

    my $vars = { 'bzvalue' => 'foo', 'field' => 'bar' };
    Bugzilla::Extension::Sync::Util::field_error("unknown_bzvalue", 
                                                 $bug, 
                                                 $vars);
    isnt($bug->{'comments'}->[0], undef);
    is($bug->{'keywords'}->[0], "syncerror");
}

###############################################################################
# get_bug_for
###############################################################################
sub test_get_bug_for {
    # get_bug_for($bug, $system, $ext_id);
}