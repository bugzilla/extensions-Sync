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

test_job_limits();

done_testing();

###############################################################################
# Multiple jobs
###############################################################################
sub test_job_limits {
    my $queue = Bugzilla->job_queue();
    my $jobname = "send_mail";
    
    Bugzilla->dbh->do("DELETE FROM ts_job");
    
    $queue->insert($jobname, { 'max_job_count' => 1 });
    $queue->insert($jobname, { 'max_job_count' => 1 });
    $queue->insert($jobname, { 'max_job_count' => 1 });

    my @jobs = $queue->list_jobs({ funcname => $queue->job_map()->{$jobname},
                                   limit => 9999 
                                 });
    is(scalar(@jobs), 1, "Max one job in the queue at once");

    $queue->insert($jobname, { 'max_job_count' => 2 });
    $queue->insert($jobname, { 'max_job_count' => 2 });

    my @jobs = $queue->list_jobs({ funcname => $queue->job_map()->{$jobname},
                                   limit => 9999 
                                 });
    is(scalar(@jobs), 2, "Max two jobs in the queue at once");
}
