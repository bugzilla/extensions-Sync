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

# This file specifies the parameters necessary for configuring the Sync, along 
# with their types, default values and functions to validate the entered values
# (in some cases). Bugzilla uses this file, plus a template which defines the 
# textual descriptions, to generate a param screen.

package Bugzilla::Extension::Sync::ParamPanel;

use strict;

use Bugzilla::Config::Common;

# XXXDoc The sortkey for Sync plugins should be 1800 + the index of the first
# letter of its name (e.g. 4 for D).
our $sortkey = 1800;

use constant get_param_list => (
    {
        name    => 'sync_enabled',
        type    => 'b',
        default => '0'
    },
    {
        name    => 'sync_error_email',
        type    => 't',
        default => '',
        checker => \&check_users
    },
    {
        name    => 'sync_debug',
        type    => 'b',
        default => '0'
    },
);

sub check_user {
    my ($value) = (@_);
    my $user = new Bugzilla::User({ name => $value });

    return $user ? '' : 'must be a valid Bugzilla user';
}

sub check_users {
    my ($value) = (@_);
    foreach my $name (split(/\s*,\s*/, $value)) {
        next if !$name;

        my $retval = check_user($name);
        if ($retval) {
            return "must all be valid Bugzilla users. $name is not one";
        }
    }

    return '';
}

1;
