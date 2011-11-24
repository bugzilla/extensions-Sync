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

package Bugzilla::Extension::Sync::Test::Util;
use strict;
use warnings;
use base 'Exporter';

use Test::Deep;
use LWP::UserAgent;

BEGIN {
    use Bugzilla;
    Bugzilla->extensions;
}

use Bugzilla;
use Bugzilla::Constants;
use Bugzilla::Extension::Sync::Util;
use File::Spec::Functions;
use File::Slurp;

use vars qw($VERSION @ISA @EXPORT @EXPORT_OK);

@EXPORT = qw(run_jobqueue
             run_jobqueue_until_empty
             clean_bug
             get_bug_as_struct
             cmp_bugs
             );

$VERSION = '0.01';

my $jobqueue_noisy = 1;

sub run_jobqueue {
    my $cmd = catfile(bz_locations()->{'libpath'}, 
                      'jobqueue.pl') . " -f once ";

    # You can pass a parameter to this function to get it to be noisy, for
    # test debugging purposes.
    if (!$_[0] && !$jobqueue_noisy) {
        $cmd .= "> /dev/null 2>&1";
    }

    my $output = system($cmd);
    return $output;
}

sub run_jobqueue_until_empty {
    my $dbh = Bugzilla->dbh;

    # Run the jobs
    while (scalar($dbh->selectrow_array("SELECT COUNT(*) from ts_job"))) {
      run_jobqueue();
    }
}

# Take a bug and make sure it's in a good state for a test
sub clean_bug {
    my ($bug_id, $will_be_first_sync) = @_;

    my $bug = new Bugzilla::Bug($bug_id);
    $bug->modify_keywords('syncerror', 'delete');

    if ($will_be_first_sync) {
        my $cf_rn_field = new Bugzilla::Field({ name => 'cf_refnumber' });
        $bug->set_custom_field($cf_rn_field, '');

        my $cf_sm_field = new Bugzilla::Field({ name => 'cf_sync_mode' });
        $bug->set_custom_field($cf_sm_field, '---');

        my $cf_sd_field = new Bugzilla::Field({ name => 'cf_sync_data' });
        $bug->set_custom_field($cf_sd_field, undef);

        my $cf_sdt_field = new Bugzilla::Field({ name => 'cf_sync_delta_ts' });
        $bug->set_custom_field($cf_sdt_field, "");
    }

    $bug->update();
}

sub _parse_xml {
    my ($xml) = @_;
    
    my $xs = XML::Simple->new(
        ForceArray => ["long_desc", "attachment"],
        KeepRoot => 1
    );

    my $struct = eval { $xs->XMLin($xml) };

    if ($@) {
        return "XML PARSING FAILED: $@";
    }

    return $struct;
}

sub get_bug_as_struct {
    my ($bug_id) = shift;

    return "ASKED FOR STRUCT FOR BUG 0" if !$bug_id;

    my $ua = new LWP::UserAgent();
    
    my $username = 'superuser@example.com';
    my $password = 'superuser';

    my $url = Bugzilla->params->{'urlbase'} .
              "show_bug.cgi?Bugzilla_login=$username&" .
              "Bugzilla_password=$password&ctype=xml&id=" . $bug_id;
    my $response = $ua->get($url);
    if ($response->content =~ /Bugzilla &ndash; Invalid Username Or Password/) {
        return "CAN'T GET BUG $bug_id; please set up superuser\@example.com";
    }
    elsif ($response->is_success) {
        return _parse_xml($response->content);
    }
    else {
        return "CAN'T GET BUG $bug_id";
    }
}

sub _clean_struct_bug {
    my $bug = shift;

    $bug = $bug->{'bugzilla'};
    delete($bug->{'exporter'});
    delete($bug->{'urlbase'});

    $bug = $bug->{'bug'};

    foreach my $delfield qw(bug_id creation_ts delta_ts token cf_sync_data
                            cf_sync_delta_ts) 
    {
        delete($bug->{$delfield});
    }
    
    my @long_descs = ();
    if (ref($bug->{'long_desc'}) eq "ARRAY") {
        @long_descs = @{$bug->{'long_desc'}};
    }
    elsif (ref($bug->{'long_desc'}) eq "HASH") {
        @long_descs = ($bug->{'long_desc'});
        # Force array
        $bug->{'long_desc'} = \@long_descs;
    }
    
    foreach my $long_desc (@long_descs) {
        foreach my $delfield qw(bug_when commentid) {
            delete($long_desc->{$delfield});
        }
    }

    foreach my $attachment (@{ $bug->{'attachment'} || [] }) {
        foreach my $delfield qw(date delta_ts token attachid) {
            delete($attachment->{$delfield});
        }
    }
}

sub cmp_bugs {
    my ($got_bug_id, $xml, $name) = @_;
    my $got = get_bug_as_struct($got_bug_id);
    _clean_struct_bug($got);

    my $expected = _parse_xml($xml);
    _clean_struct_bug($expected);

    # Attachments added at the same time are added in non-deterministic order,
    # so sort them.
    my $gotbug = $got->{'bugzilla'}->{'bug'};
    if (exists($gotbug->{'attachment'})) {
        my @sorted = sort { $a->{'filename'} cmp $b->{'filename'} }
                          @{ $gotbug->{'attachment'} };
        $gotbug->{'attachment'} = \@sorted;
    }

    cmp_deeply($got, $expected, $name);
}

1;

__END__

=head1 NAME

Bugzilla::Extension::Sync::Test::Util - utilities for testing Sync plugins.

=head1 SYNOPSIS


=head1 DESCRIPTION

This package provides code to help write tests for Sync plugins.

If you are to use some of the functions, your test database needs a Bugzilla
user C<superuser@example.com> with password C<superuser>.

=head1 LICENSE

This software is available under the Mozilla Public License 1.1.

=cut
