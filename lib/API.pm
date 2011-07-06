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
        value => $value
    });
    
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

=head1 NAME

Bugzilla::Extension::Sync::API - the Bugzilla::Extension::Sync API.

=head1 DESCRIPTION

This package provides basic services for syncing. It allows Syncing extensions
to register for events, and register a data parser for the opaque sync data
blob.

=head1 SYNOPSIS

  package Bugzilla::Extension::SyncFoo;
  use base qw(Bugzilla::Extension);
  
  use Bugzilla::Extension::Sync::API;
  
  our $SYSTEM = "Foo";
  
  sub install_update_db {
      add_sync_mode($SYSTEM, "Shared");
  }
  
  sub _bug_updated {
      my ($args) = @_;
      my $bug = $args->{'bug'};
      ...
  }
  
  register_sync_event_handler("bug_updated", $SYSTEM, \&_bug_updated);
  
  sub _parse_foo_data {
      return thaw(@_[0]->{'cf_sync_data'});
  }
  
  register_sync_data_parser($SYSTEM, \&_parse_foo_data);

=head1 DESCRIPTION

=head2 Methods

=over

=item C<add_sync_mode>

There may be multiple ways of syncing with a remote system - e.g. one way
could be that the bug is read-only there, and mastered here, and another way
might be the reverse. The cf_sync_mode custom field stores both the name of
the remote system and, optionally, the mode.

The first, mandatory argument is the UI name of the remote system. We suggest
something short and with no spaces, and we also suggest using a $SYSTEM variable
(see Synopsis) to make sure you don't misspell it anywhere.

The second, optional argument is used when there is more than one way of syncing
with a system. This argument disambiguates the ways. So you might have:

  sub install_update_db {
      add_sync_mode($SYSTEM, "Shared");
      add_sync_mode($SYSTEM, "Read Only");
  }

As shown, this function should be called from the C<install_update_db> hook. 

=item C<register_sync_event_handler>

There are currently 3 sync events - C<bug_updated>, C<attachment_created> and
C<attachment_updated>. (There is no C<bug_created> event because the model is
that bugs need to exist before they can be set to sync.) This function allows 
you to register a callback function to be called when one of those events
happens.

The first parameter is the name of the event, the second is the name of the
remote system (your function will only be called for bugs set to sync with that
system) and the third is a reference to the callback function.

Users need to be careful - if their C<bug_updated> handler updates a bug, the 
C<bug_updated> handler might be called again. Always set $bug->{'suppress_sync'} 
to 1 on any bug objects where you don't want calling $bug->update() to trigger
another event. The same applies for updated attachments.

For newly-created attachments, it's more complicated. When your code to receive 
attachments
creates a new attachment object, the C<attachment_created> handler will get
called. One way of filtering out these bogus calls is to have new attachments
created by a dedicated sync user, and to check whether the attachment was
created by that user before proceeding in the handler.

The callback function receives a single argument, a hash, with named parameters
in it. Currently-available parameters are as follows:

=over

=item C<bug_updated>

Arguments are: 
C<bug> - the Bug object; 
C<timestamp> - the timestamp of the change;
C<changes> - a structure giving the 'before' and 'after' values of changed
fields.

=item C<attachment_created>

Arguments are: C<attachment> - the new Attachment object.

=item C<attachment_updated>

Arguments are: C<attachment> - the updated Attachment object.

=back

=item C<register_sync_data_parser>

The Sync system stores the last data received from the remote system for a 
particular bug. It can store this in any form, including the form it was
received in, but implementations should register a sync data parser to turn it
into a Perl structure. This is used, among other things, for the generic
"last sync data display" system - bugs have a link which shows the data. (This
prevents implementations from having to map every synced field to a Bugzilla
field - users can just look at the separate page showing what was sent.)

The first argument is the System name, the second is a reference to the callback
function. The callback function receives one argument - the bug. 
C<$bug-<gt>{cf_sync_data}> has the data necessary, and you should return a
Perl hash (as complex in structure as you like).

=back

=head1 LICENSE

This software is available under the Mozilla Public License 1.1.

=cut