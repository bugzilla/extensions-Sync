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

package Bugzilla::Extension::Sync::API;
use strict;
use base qw(Exporter);

our $VERSION = '0.1';

our @EXPORT    = qw(register_sync_event_handler
                    add_sync_mode
                    register_sync_data_parser);
our @EXPORT_OK = qw(dispatch_sync_event);

my $handlers = {};

# Call this function to register for sync-relevant events.
#
# Valid $events are:
# bug_updated, attachment_created, attachment_updated
#
# $system is the value that $bug->sync_system() will return for
# bugs you are interested in.
#
# $func is the function to call. It will be called with a single
# param, a hash, with contents depending on what the event is.
# Read the code :-)

sub register_sync_event_handler {
    my ($event, $system, $func) = @_;
    $handlers->{$event}->{$system} = $func;
}

sub dispatch_sync_event {
    my ($event, $system, $params) = @_;
    if ($handlers->{$event} &&
        $handlers->{$event}->{$system})
    {
        $handlers->{$event}->{$system}->($params);
    }
}

sub add_sync_mode {
    my ($system, $name) = @_;
    my $value = $system;
    if ($name) {
        $value .= ": $name";
    }

    my $field = new Bugzilla::Field({name => 'cf_sync_mode'});
    my $matches = Bugzilla::Field::Choice->type($field)->match({
                                                             value => $value });
    if (!scalar(@$matches)) {
        my $created_value = Bugzilla::Field::Choice->type($field)->create({
            value => $value
        });
    }
}

sub register_sync_data_parser {
    my ($system, $fn) = @_;
    if (!$Bugzilla::Bug::_sync_data_parsers) {
        $Bugzilla::Bug::_sync_data_parsers = {};
    }

    $Bugzilla::Bug::_sync_data_parsers->{$system} = $fn;
}

1;
