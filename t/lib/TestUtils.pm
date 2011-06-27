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
use warnings;
use base 'Exporter';

use Test::More;
use Test::Deep;
use Data::Dumper;
use FindBin '$Bin';
use File::Slurp;

BEGIN {
    use Bugzilla;
    Bugzilla->extensions;
}

use Bugzilla;
use Bugzilla::Constants;
use Bugzilla::Extension::Sync::Util;

use vars qw($VERSION @ISA @EXPORT @EXPORT_OK);

@EXPORT = qw(pre_testing);

$VERSION = '0.01';

# Do all the checks and setup necessary for a testing run
sub pre_testing {
    login_as_test_user();
}

sub login_as_test_user {
}

1;
