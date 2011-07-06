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
use Bugzilla::Extension::Sync::Mapper;
use Bugzilla::Extension::Sync::S;
use Bugzilla::Extension::Sync::Test::MockBug;
use Tie::IxHash;
use Test::Exception;

# Have to monkey-patch these in the Mapper package as they have already
# been imported. Who'da thought?
local *Bugzilla::Extension::Sync::Mapper::field_error = sub { die $_[0]; };
local *Bugzilla::Extension::Sync::Mapper::error = sub { die $_[0]; };

# Magic incantations so we can use a short name
*S:: = \*Bugzilla::Extension::Sync::S::;
*MockBug:: = \*Bugzilla::Extension::Sync::Test::MockBug::;

test_map_bug_to_external();
test_map_external_to_bug();

done_testing();

###############################################################################
# map_bug_to_external
###############################################################################
sub test_map_bug_to_external {
    my $bug1 = new MockBug({ 
        priority => "P1",
        is_first_sync => 1,
        severity => 'blocker'
    });

    my $bug2 = new MockBug({ 
        is_first_sync => 0,
        severity => 'notinlist'
    });

    my $map;
    tie(%$map, "Tie::IxHash",
        "Key1"  => new S( literal => 'Value1' ),
        "Key2"  => new S( field   => 'priority' ),
        "Key3"  => undef,
        "Key5"  => new S( field   => 'severity',
                          map     => {
                              "blocker" => "extreme",
                              "critical" => "rad",
                              "major" => "serious",
                              "normal" => "cool",
                              "minor" => "easy",
                              "trivial" => "dull",
                              "_default" => "serious"
                          }
                        )
    );

    # First bug
    my $ext1 = map_bug_to_external($bug1, $map);

    is($ext1->{'Key1'}, 'Value1', "literal processed");
    is($ext1->{'Key2'}, 'P1', "field processed");
    ok(!exists($ext1->{'Key3'}), "undef removed");
    ok(!defined($ext1->{'Key4'}), "oldbugonly skipped");
    is($ext1->{'Key5'}, 'extreme', "map mapped");

    # Second bug
    my $ext2 = map_bug_to_external($bug2, $map);

    is($ext2->{'Key5'}, 'serious');

    # Errors
    my %errors_to_bad_maps = (
      'unknown_bzvalue' => { "Key1" => new S( 
                               field => 'priority', 
                               'map' => {
                                 '_error' => 'serious'
                               }
                             )
                           },
      'unknown_bzvalue_bad_map' => { "Key1" => new S(
                                     field => 'priority', 
                                     'map' => {}
                                    )
                                  },
      'no_instruction' => { "Key1" => new S( 'foopy' => 'glurpy' ) },
    );

    foreach my $error (keys %errors_to_bad_maps) {
        throws_ok(sub { 
                    map_bug_to_external($bug1, $errors_to_bad_maps{$error}) 
                  },
                  qr/^$error/,
                  "$error hit");
    }
}

###############################################################################
# map_external_to_bug
###############################################################################
sub test_map_external_to_bug {
    my $ext_id = "Test";
    my $ext = {};
    my $map = {};  
    my $bug;
    my $newbug;
  
    # Sync error bug
    $bug = new MockBug({ 
        id => 1, 
        keyword_objects => [new Bugzilla::Keyword({ name => 'syncerror' })], 
    });
  
    Bugzilla->params->{'sync_debug'} = 0; # Suppress warning
    $newbug = map_external_to_bug($ext, $bug, $map, $ext_id);
    Bugzilla->params->{'sync_debug'} = 1;
    is($newbug, undef, "Sync error causes undef return");
  
    # Bug which isn't syncing
    $bug = new MockBug({ 
        'id' => 1, 
        'keyword_objects' => [], 
        'cf_sync_mode' => "---",
    });
  
    throws_ok(sub { map_external_to_bug($ext, $bug, $map, $ext_id); },
              qr/^got_update_for_unsynced_bug/,
              "got_update_for_unsynced_bug hit");

    # With an ID (i.e. not new bug)
    $map = {
        "-Key0" => "Value0",
        "Key1"  => undef,
        "Key2"  => { newbugonly => 1,
                     field => 'priority' },
        "Key3"  => { field => 'bug_severity' },
        "Key4"  => { function => sub { $_[0]->{'bug_file_loc'} = $_[1] } },
        "Key5"  => { field => 'rep_platform', 
                     map => {
                        "Foo" => "Bar",
                        "_default" => "Baz"
                     }
                   },
        "Key6"  => { field => 'version', 
                     map => {
                        "Fred" => "Barney",
                        "_default" => "Wilma"
                     }
                   },
    };
  
    $ext = {
        "Key0" => 0,
        "Key1" => 1,
        "Key2" => "P1",
        "Key3" => "blocker",
        "Key4" => "http://www.foo.com/",
        "Key5" => "Foo",
        "Key6" => "NotPresent",
    };
  
    $bug = new MockBug({ 
        id => 1, 
        keyword_objects => [],
        set_severity => sub { $_[0]->{'severity'} = $_[1] },
        set_op_sys => sub { $_[0]->{'op_sys'} = $_[1] },
        set_platform => sub { $_[0]->{'platform'} = $_[1] },
        set_version => sub { $_[0]->{'version'} = $_[1] },
        'cf_sync_mode' => "Yes",
    });
  
    $newbug = map_external_to_bug($ext, $bug, $map, $ext_id);

    is($bug, $newbug, "Same object returned");
    is($bug->{'priority'}, undef, "newbugonly command avoided OK");
    is($bug->{'severity'}, "blocker", "Field extracted OK");
    is($bug->{'bug_file_loc'}, "http://www.foo.com/", "Function run OK");
    is($bug->{'platform'}, "Bar", "Map applied OK");
    is($bug->{'version'}, "Wilma", "Default chosen OK");
  
    # Without an ID
    *Bugzilla::Bug::create = sub { return $_[1]; };
    
    $bug = new MockBug({ id => undef });  
    $newbug = map_external_to_bug($ext, $bug, $map, $ext_id);

    # Our hack means we should get the same object back
    isa($newbug, $bug);
  
    # Errors
    my %errors_to_bad_maps = (
        'unknown_value_bad_map' => { "Key1" => { 
                                        field => 'priority', 
                                        'map' => {}
                                      }
                                  },
        'no_instruction_bad_map' => { "Key1" => { 'foopy' => 'glurpy' } },
    );

    foreach my $error (keys %errors_to_bad_maps) {
        throws_ok(sub { map_external_to_bug($ext, 
                                            $bug, 
                                            $errors_to_bad_maps{$error}, 
                                            $ext_id)
                      },
                  qr/^$error/,
                  "$error hit");
    }  
}
