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

use Bugzilla::Extension::Sync::Test::MockBug;
*MockBug:: = \*Bugzilla::Extension::Sync::Test::MockBug::;

test__set_from_name();
test_find_setter();
test_field_error();
test_sync_problem();
test_warning();
test_get_bug_for();
test_set_status_directly();
test__record_error_message();
test_is_bug_updated_in_db();

done_testing();

# XXXValeo-specific
###############################################################################
# _set_from_name
###############################################################################
sub test__set_from_name {
    my $bug = new MockBug({ product => "doesntmatter" });
    Bugzilla::Extension::Sync::Util::_set_from_name($bug, 
                                                   "product", 
                                                   "DAG RVC 2.0");
    is($bug->{'product_id'}, 3);

    Bugzilla::Extension::Sync::Util::_set_from_name($bug, "component", "HW");
    is($bug->{'component_id'}, 7);

    $bug = new MockBug({ product => "doesntmatter" });
    local *Bugzilla::Extension::Sync::Util::error = sub { return; };
    Bugzilla::Extension::Sync::Util::_set_from_name($bug, 
                                                   "product", 
                                                   "Doesn'tExist");
    is($bug->{'product_id'}, undef);

    Bugzilla::Extension::Sync::Util::_set_from_name($bug, 
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
    local *Bugzilla::Extension::Sync::Util::_record_error_message = sub { };

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
# sync_problem
###############################################################################
sub test_sync_problem {
    local *Bugzilla::Extension::Sync::Util::_record_error_message = sub {
        my ($message, $bug_id, $subject) = @_;
        
        is($bug_id, 42, "Bug ID is 42");
    };
    
    my $bug = new MockBug({
        id => 42,
    });

    Bugzilla::Extension::Sync::Util::sync_problem("test", 
                                                  { bug => $bug });

    Bugzilla::Extension::Sync::Util::sync_problem("test", 
                                                  { bug_id => 42 });
}

###############################################################################
# warning
###############################################################################
sub test_warning {
    local *Bugzilla::Extension::Sync::Util::_record_error_message = sub {
        my ($message, $bug_id, $subject) = @_;
        
        like($message, qr/SendUpdate executed/, "Message starts OK");
        is($subject, "Sync Warning", "Title is correct");
        is($bug_id, 42, "Bug ID is 42");
    };

    my $bug = new MockBug({
        id           => 42,
        cf_sync_mode => "Foopy: Doopy",
        delta_ts     => "2012-02-24 14:45:51"
    });

    my $vars = { 'bug' => $bug, 'timestamp' => '2012-03-31 16:20:18' };
    Bugzilla::Extension::Sync::Util::warning("bug_not_updated", $vars);
}

###############################################################################
# get_bug_for
###############################################################################
sub test_get_bug_for {    
    local *Bugzilla::Extension::Sync::Util::_record_error_message = sub { };
    
    my $bug;
    
    # Have to be logged in as a special sync user to be able to change
    # cf_refnumber
    Bugzilla->set_user(new Bugzilla::User({ 
        name => Bugzilla->params->{'bmw_user_email'} 
    }));
    
    # Bug ID exists in DB and Ext ID matches
    # (normal case)
    $bug = get_bug_for(333, "BMW", 73);
    isnt($bug, undef, "A: Bug returned");
    is($bug->id, 333, "A: Bug ID OK");
    is($bug->{'cf_refnumber'}, 73, "A: Ext ID OK");
    
    # Bug ID exists in DB and Ext ID does not match and does not exist in DB
    # (They have sent us a bogus Bug ID; new bug)
    $bug = get_bug_for(333, "BMW", 999999);
    isnt($bug, undef, "B: Bug returned");
    is($bug->id, 0, "B: New Bug ID is 0 - OK");
    is($bug->{'cf_refnumber'}, 999999, "B: Ext ID OK");

    # Bug ID exists in DB and Ext ID does not match and exists in DB
    # (They have sent us a bogus Bug ID; existing bug)
    $bug = get_bug_for(333, "BMW", 1000);
    is($bug->id, 516, "C: Bug ID OK");
    is($bug->{'cf_refnumber'}, 1000, "C: Ext ID OK");

    # Bug ID non-zero and does not exist in DB and Ext ID exists in DB
    # (They have sent us a bogus Bug ID; existing bug)
    $bug = get_bug_for(999999, "BMW", 73);
    isnt($bug, undef, "D: Bug returned");
    is($bug->id, 333, "D: Bug ID OK");
    is($bug->{'cf_refnumber'}, 73, "D: Ext ID OK");

    # Bug ID non-zero and does not exist in DB and Ext ID does not exist in DB
    # (They have sent us a bogus Bug ID; new bug)
    $bug = get_bug_for(999999, "BMW", 987);
    isnt($bug, undef, "E: Bug returned");
    is($bug->id, 0, "E: New Bug ID is 0 - OK");
    is($bug->{'cf_refnumber'}, 987, "E: Ext ID OK");

    # Bug ID is 0 and Ext ID exists in DB
    # (Reasonably new bug; they have not started to send us a Bug ID yet)
    $bug = get_bug_for(0, "BMW", 73);
    isnt($bug, undef, "F: Bug returned");
    is($bug->id, 333, "F: Bug ID OK");
    is($bug->{'cf_refnumber'}, 73, "F: Ext ID OK");
    
    # Bug ID is 0 and Ext ID does not exist in DB
    # (New bug)
    $bug = get_bug_for(0, "BMW", 987);
    isnt($bug, undef, "G: Bug returned");
    is($bug->id, 0, "G: New Bug ID is 0 - OK");
    is($bug->{'cf_refnumber'}, 987, "G: Ext ID OK");

    # Ext ID is 0 
    # (Bad call)
    $bug = get_bug_for(333, "BMW", 0);
    is(undef, $bug, "H: No bug returned");
}

###############################################################################
# set_status_directly
###############################################################################
sub test_set_status_directly {
    my $bug = new Bugzilla::Bug(764);
    is($bug->status->name, "RESOLVED", "Bug status starts as RESOLVED");
    is($bug->resolution, "FIXED", "Bug resolution starts as FIXED");

    set_status_directly($bug, "NEW");
    is($bug->resolution, "", "Bug resolution cleared");

    set_status_directly($bug, "CLOSED");
    is($bug->status->name, "CLOSED", "Bug set to CLOSED");
    isnt($bug->resolution, "", "Bug resolution set to something");
}

###############################################################################
# _record_error_message
###############################################################################
sub test__record_error_message {
    # Turn off carping
    Bugzilla->params->{'sync_debug'} = 0;

    # Capture message write to run tests
    local *Bugzilla::Extension::Sync::Util::MessageToMTA = sub {
        my ($email) = @_;
        like($email, qr/Untitled Error/, "Blank error correctly titled");
        like($email, qr/utils\.t/, "Error contains stack trace");
    };
    
    my $msg = "";
    my $bug_id = undef;
    my $subject = undef;
    Bugzilla::Extension::Sync::Util::_record_error_message($msg,
                                                           $bug_id,
                                                           $subject);
}

###############################################################################
# is_bug_updated_in_db
###############################################################################
sub test_is_bug_updated_in_db {
    my $bug = new Bugzilla::Bug(765);
    
    my $result = Bugzilla::Extension::Sync::Util::is_bug_updated_in_db($bug,
                                                        "2012-04-17 06:28:42");
    is($result, 1, "Matched timestamps - bug is updated");

    my $result = Bugzilla::Extension::Sync::Util::is_bug_updated_in_db($bug,
                                                        "2012-04-17 06:28:41");
    is($result, 1, "delta_ts is +1 second - bug is updated");

    my $result = Bugzilla::Extension::Sync::Util::is_bug_updated_in_db($bug,
                                                        "2012-04-17 06:28:43");
    is($result, 1, "delta_ts is -1 second - bug is updated");

    my $result = Bugzilla::Extension::Sync::Util::is_bug_updated_in_db($bug,
                                                        "2012-04-17 06:28:44");
    is($result, "", "delta_ts is -2 seconds - bug is not updated");

    my $result = Bugzilla::Extension::Sync::Util::is_bug_updated_in_db($bug,
                                                        "2012-05-23 19:41:10");
    is($result, "", "delta_ts is wildly behind - bug is not updated");
}
