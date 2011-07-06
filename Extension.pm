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
use base qw(Bugzilla::Extension);

use Bugzilla::Extension::Sync::Util;
use Bugzilla::Extension::Sync::API qw(dispatch_sync_event);
use Bugzilla::Constants;
use Bugzilla::Util qw(lsearch);

our $VERSION = '1.0';

###############################################################################
# Extra bug fields
#
# cf_sync_mode: NULL if issue is not synced. Otherwise is sync system, 
# optionally followed by a colon and then sync mode. 
# E.g. "FooSystem: Read Only".
#
# cf_sync_data: Blob interpretable only by a sync plugin, containing the last 
# sync data sent by remote system regarding this bug. Each plugin should 
# register a sync handler to parse it into a structure for us.
#
# cf_sync_delta_ts: the last time we received data from the remote system.
###############################################################################
sub install_update_db {
    my ($self, $args) = @_;

    my $dbh = Bugzilla->dbh;

    my $extra_fields = [
        {
            name        => 'cf_sync_mode',
            description => 'Sync Mode',
            type        => FIELD_TYPE_SINGLE_SELECT,
            buglist     => 0
        },
        {
            name        => 'cf_sync_data',
            description => 'Last Sync Data',
            type        => FIELD_TYPE_TEXTAREA,
            buglist     => 0
        },
        {
            name        => 'cf_sync_delta_ts',
            description => 'Last Sync Time',
            type        => FIELD_TYPE_DATETIME,
            buglist     => 0
        },
    ];

    # Migration from old system - has to be done before new things are created
    # so it can't be in the relevant sync plugin.
    if ($dbh->bz_column_info('bugs', 'cf_dante_mode')) {
        foreach my $field (@{ $extra_fields }) {
            my $oldname = $field->{'name'};
            $oldname =~ s/sync/dante/;

            $dbh->bz_rename_column('bugs', $oldname,
                                           $field->{'name'});
            $dbh->do("UPDATE fielddefs SET name = '" . $field->{'name'} .
                     "', description = '" . $field->{'description'} .
                     "' WHERE name = '$oldname'");
        }

        $dbh->bz_rename_table('cf_dante_mode', 'cf_sync_mode');

        # Migrate dantesyncers to syncers
        my $group = new Bugzilla::Group({name => 'dantesyncers'});
        $group->set_name("syncers");
        $group->update();

        # Migrate dantesyncerror to syncerror
        my $keyword = new Bugzilla::Keyword({name => 'dantesyncerror'});
        $keyword->set_name("syncerror");
        $keyword->update();

        # Change field values
        foreach my $mode ("IRP", "Read Only") {
            my $field =
                    Bugzilla::Field::Choice->type('cf_sync_mode')->check($mode);
            $field->set_name("DanTe: $mode");
            $field->update();

            $dbh->do("UPDATE bugs
                      SET cf_sync_mode='DanTe: $mode'
                      WHERE cf_sync_mode='$mode'");
        }
    }
    # End migration code

    foreach my $extra (@$extra_fields) {
        # Only create them once...
        my $field = new Bugzilla::Field({ name => $extra->{'name'} });
        next if $field;

        $field = Bugzilla::Field->create({
            name        => $extra->{'name'},
            description => $extra->{'description'},
            type        => $extra->{'type'},
            enter_bug   => 0,
            buglist     => $extra->{'buglist'},
            custom      => 1,
        });
    }

    # Add group to restrict changing cf_sync_mode to (see
    # check_can_change_field)
    my $group = Bugzilla::Group->match({ name => 'syncers' });

    if (!scalar(@{$group})) {
        $group = Bugzilla::Group->create({
            name        => 'syncers',
            description => 'Those who can trigger syncing with remote systems',
            isbuggroup  => 0,
        });
    }

    # Add keyword to add to bugs if there's a sync error; suppresses sync
    my $keyword = new Bugzilla::Keyword({ name => 'syncerror' });

    if (!$keyword) {
        $keyword = Bugzilla::Keyword->create({
            name => 'syncerror',
            description => 'Bug has a sync error syncing to remote system; ' .
                           'sync will not be attempted again until this ' .
                           'keyword is removed.'
        });
    }
}

###############################################################################
# Hooks which trigger sync events
#
# Currently, there is no bug_created event, because the model is that bugs have
# to be explicitly set to sync, and obviously that requires them to exist 
# first.
###############################################################################
# Bug updated
sub bug_end_of_update {
    my ($self, $args) = @_;
    my $bug     = $args->{'bug'};
    my $changes = $args->{'changes'};
    
    return if !$bug->is_syncing;
    
    # If any changes occurred...
    if (scalar(keys %$changes) || $bug->{added_comments}) {
        my $is_first_sync = (defined($changes->{'cf_sync_mode'}) &&
                            $changes->{'cf_sync_mode'}->[0] eq '---' &&
                            $changes->{'cf_sync_mode'}->[1] ne '---') ? 1 : 0;

        dispatch_sync_event('bug_updated', $bug->sync_system(), {
            bug           => $bug,
            changes       => $changes,
            timestamp     => $args->{'timestamp'},
            is_first_sync => $is_first_sync,
        });
    }
}

# Attachment created
sub object_end_of_create {
    my ($self, $args) = @_;
    my $class = $args->{'class'};

    if ($class->isa('Bugzilla::Attachment')) {
        my $attachment = $args->{'object'};

        return if !$attachment->bug->is_syncing;
        
        # There is a risk of loops here because this hook will be called for 
        # attachments which originate on the remote system as well as ones
        # which originate here. Event handlers need to be careful.
        #
        # One way of determining whether the attachment originated remotely is
        # looking to see if the attacher is your sync user.
        dispatch_sync_event('attachment_created',
                            $attachment->bug->sync_system(),
                            { attachment => $attachment });
    }
}

# Attachment updated
sub object_end_of_update {
    my ($self, $args) = @_;
    my $object = $args->{'object'};

    if ($object->isa('Bugzilla::Attachment')) {
        my $attachment = $object;

        return if !$attachment->bug->is_syncing;
        return if $attachment->{'suppress_sync'};

        dispatch_sync_event('attachment_updated',
                            $attachment->bug->sync_system(), { 
                                attachment => $attachment,
                                changes    => $args->{'changes'}
                            });
    }
}

###############################################################################
# New method for Bug objects
###############################################################################
BEGIN {
    *Bugzilla::Bug::is_syncing  = \&_bug_is_syncing;
    *Bugzilla::Bug::sync_system = \&_bug_sync_system;
    *Bugzilla::Bug::sync_data   = \&_bug_sync_data;
}

# Tell if the bug should be synced
sub _bug_is_syncing {
    my ($self) = @_;

    my $sync_system = lc($self->sync_system());
    
    if ($self->{'cf_sync_mode'} eq '---') {
        return 0;
    }
    elsif ($self->{'suppress_sync'}) {
        # We can suppress sync for a particular object, if we are updating it
        # but we don't want to trigger an update. This could be e.g.
        # an error comment, or setting values which have arrived due to a sync.
        return 0;
    }
    elsif (!Bugzilla->params->{'sync_enabled'}) {
        if (Bugzilla->params->{'sync_debug'}) {
            warn "Not syncing bug " . $self->id . " - sync globally disabled.";
        }

        return 0;
    }
    elsif (defined(Bugzilla->params->{$sync_system . '_sync_enabled'}) &&
           !Bugzilla->params->{$sync_system . '_sync_enabled'}) 
    {
        if (Bugzilla->params->{'sync_debug'}) {
            warn "Not syncing bug " . $self->id . 
                 " - $sync_system sync disabled.";
        }

        return 0;
    }
    elsif (grep { $_->name eq 'syncerror' } @{ $self->keyword_objects }) {
        if (Bugzilla->params->{'sync_debug'}) {
            warn "Not syncing bug " . $self->id . " - bug has had sync error.";
        }

        return 0;
    }

    return 1;
}

# Returns the name of the system the bug is syncing to, if any, or ""
sub _bug_sync_system {
    my ($self) = @_;
    $self->{'cf_sync_mode'} =~ /^([^:]+)(:.*)?$/;
    my $retval = $1;
    if (!defined($retval) || $retval eq "---") {
        $retval = "";
    }

    return $retval;
}

# Return the bug's opaque sync data as a useful structure, using the 
# appropriate registered handler.
sub _bug_sync_data {
    my ($self) = @_;

    my $system = $self->sync_system();
    return undef if (!$system);

    return $self->{'_sync_data'} if ($self->{'_sync_data'});

    my $parser = $Bugzilla::Bug::_sync_data_parsers->{$system};
    if (!$parser) {
        warn "No data parser registered for system $system";
        return undef;
    }

    $self->{'_sync_data'} = $parser->($self);

    return $self->{'_sync_data'};
}

###############################################################################
# Add configuration panel for Sync values
###############################################################################
sub config_add_panels {
    my ($self, $args) = @_;

    my $modules = $args->{'panel_modules'};
    $modules->{'Sync'} = "Bugzilla::Extension::Sync::ParamPanel";
}

###############################################################################
# Make sure only the right people can change the Sync fields
###############################################################################
sub bug_check_can_change_field {
    my ($self, $args) = @_;
    my $bug = $args->{'bug'};
    my $field = $args->{'field'};
    my $new_value = $args->{'new_value'};
    my $priv_results = $args->{'priv_results'};
    
    my @syncuseremails = ();   
    while (my ($key, $value) = each %{ Bugzilla->params() }) {
        if ($key =~ /_user_email$/) {
            push(@syncuseremails, $value);
        }
    }
    
    if (lsearch(\@syncuseremails, Bugzilla->user->email) == -1) {
        # Only 'syncers' are allowed to set sync state, and no-one can unset
        # it.
        if ($field eq 'cf_sync_mode') { 
            if (!Bugzilla->user->in_group('syncers')) {
                push(@$priv_results, PRIVILEGES_REQUIRED_EMPOWERED);
            }
            elsif ($new_value eq '---') {
                push(@$priv_results, PRIVILEGES_REQUIRED_EMPOWERED);
            }
        }
        
        # No-one can change cf_refnumber if we are syncing
        if ($field eq 'cf_refnumber' && $bug->{'cf_sync_mode'} ne '---') { 
            push(@$priv_results, PRIVILEGES_REQUIRED_EMPOWERED);
        }
        
        # No-one can change cf_dante_data or cf_sync_delta_ts ever -
        # internal use only.
        if ($field =~ /^cf_sync_data|cf_sync_delta_ts$/) { 
            push(@$priv_results, PRIVILEGES_REQUIRED_EMPOWERED);
        }
    }
}

###############################################################################
# Generic display system for sync data, based on page.cgi and Template
# Toolkit's data structure walker.
###############################################################################
sub page_before_template {
    my ($self, $args) = @_;
    my $page_id = $args->{'page_id'};
    my $vars = $args->{'vars'};

    if ($page_id eq "sync/data.html") {
        my $cgi = Bugzilla->cgi;
        my $bug_id = $cgi->param('bug_id');

        my $bug = new Bugzilla::Bug($bug_id);
        $bug->{'error'} && ThrowUserError("improper_bug_id_field_value",
                                                      { "bug_id" => $bug_id });

        # Allow us to find out the type of variables in a template
        $vars->{'ref'} = sub { return ref($_[0]) };

        $vars->{'bug'} = $bug;
    }
}

__PACKAGE__->NAME;

__END__

=head1 NAME

Bugzilla::Extension::Sync - a Bugzilla extension which provides a framework for 
                            syncing of data between Bugzilla and another system.

=head1 SYNOPSIS

See the individual modules which provide the helper APIs.

=head1 DESCRIPTION

This package provides a framework and services for asynchronous synchronization
of Bugzilla data with remote systems. Developers write additional extensions,
which to avoid overloading the word "extension" we will call "Sync plugins", 
which use those services to implement syncing with a particular remote system 
or type of system.

The name of the Sync plugin must sort later in the alphabet than the name of
this extension - "Sync" - in order for Bugzilla to load them in the right order.
It is suggested you call your extension C<SyncFoo>, where Foo is the name of 
the remote system.

=head1 SYNC OVERVIEW

This section details the steps in the syncing process, and the support that the
Sync extension provides at each stage for the code in your Sync plugin.

=head2 Incoming Data

This section is about getting data from the remote system into Bugzilla.

=over

=item 1. Acquire data

Acquire the data from the remote system.

No help provided. Use e.g. L<LWP::UserAgent> 
for web services, and a cron job if you need to get data on a regular basis.
The Bugzilla JobQueue system is helpful here; use cron to run a a small stub 
.pl file which inserts a job into the queue, and the queue then manages 
retries etc.
You should allow users to specify configuration parameters, e.g. login details
on the remote system, by creating a param panel. See the docs for the
C<config_add_panels> hook.

=item 2. Log data

Keep a copy of the data for later debugging.

See the C<log_data> function in L<Bugzilla::Extension::Sync::Util>.

=item 3. Parse data

Turn the data stream into a Perl data structure.

No help provided. Perl modules exist to parse most formats (XML, JSON etc.).

=item 4. Validate data (optional)

Validate the data against a schema.

You may want to do this, if you have a schema such as an XML Schema, to make 
sure the data matches what you expected to receive. No help provided, but Perl 
modules exist for e.g. XMLSchema or DTD validation.

=item 5. Simplify data (optional)

This step is for when the format of data sent is complicated and verbose. One 
wants to extract the important values to a simpler structure for storage and 
display.

This step is usually only necessary for XML. Help is provided for XML using 
XPath helper, which turns a LibXML DOM tree into an ordinary hash/array 
structure. See L<Bugzilla::Extension::Sync::XML> for helper functions for 
working with XML.

=item 6. Apply values to bugs

Help provided: C<map_external_to_bug> in L<Bugzilla::Extension::Sync::Mapper>.
This function uses declarative syntax to define how the values in your data 
structure are mapped to bug values, with optional processing on the way.

=item 7. Store data

For each bug, the data sent by the remote system relating to that bug must be 
stored in the database in the C<cf_sync_data> custom field. Call 
C<store_sync_data> to do that; this function will also update the sync 
timestamp for the bug.

We provide a 
registration mechanism so you can register an interpreter function which will 
teach the system how to get the original data back, and then a generic display 
system to display the data on a web page linked from that bug. So don't make
this structure too complicated.

You can either store the data directly as it was sent, or e.g. use 
L<Storable> to C<freeze> and C<thaw> it.

=back

=head2 Outgoing Data

This section is about getting data from Bugzilla into the remote system.

=over

=item 1. Notice bug events

Help provided: the event registration system in 
L<Bugzilla::Extension::Sync::API> allows you to register for bug and attachment
change events and take action.

=item 2. Get values from bugs/attachments into data structure

Help provided: C<map bug_to_external> in L<Bugzilla::Extension::Sync::Mapper>, 
which uses declarative syntax to define how fields in a structure should be 
filled with bug data. The structure can be arbitrarily complicated if you like;
this function uses a visitor pattern to visit your data map and replace 
placeholder instructions with actual data.

=item 3. Upgrade data structure to something more complex (optional)

This step is optional, and depends on how you are validating and/or serializing. 
L<Bugzilla::Extension::Sync::XML> provides functions, if you are working with
XML, to use XPath to take a simple hash of keys and values and insert the values
into arbitrary places in an XML document.

=item 4. Serialize data structure

No help provided - use XML::Simple's XMLout() or LibXML's abilities.

=item 5. Log data

See the C<log_data> function in L<Bugzilla::Extension::Sync::Util>.

=item 6. Validate data (optional)

You may want to validate the data against a schema to make sure it's what you 
should be sending and catch bugs in your code. No help provided, but Perl 
modules exist for e.g. XMLSchema or DTD validation.

This is done after serialization and logging so your error messages can tell
the user where to find a copy of the invalid data.

=item 7. Send data

No help provided - use LWP::UserAgent or custom code. See 1. in the section 
above. You may want to use the Bugzilla job queue to make the work asynchronous 
and prevent connections to a remote system causing UI slowness.

=back

=head1 WRITING A SYNC PLUGIN

There are various things you have to do when writing your Sync plugin in order
for all of the services the Sync extension provides you to work correctly.

First, define a short name for the remote system - in the following, we'll use
the example name "Initech".

=over

=item * Provide a Bugzilla parameter called C<initech_user_email>, which is
the email address of the Bugzilla user in whose name actions prompted by the
remote system are done. If you don't define this, the user you try and use 
will be forbidden from modifying certain sync fields in the database, and you'll
get errors.

=item * Provide a boolean Bugzilla parameter called C<initech_sync_enabled>, 
which will switch your extension's syncing on and off.

=item * In the C<install_update_db> hook, call C<add_sync_mode("Initech")> 
to add the name
of the system you want to sync with to the Bugzilla UI. If there are multiple
ways of syncing with the system, call it multiple times with the same first
parameter, and a different second parameter, e.g.:

  add_sync_mode("Initech", "Read Only");
  add_sync_mode("Initech", "Shared");

In your extension, your code will only be called for bugs which are syncing
with your system. You can get details of the sync mode for a bug by calling 
C<$bug-&gt;sync_system>.

=item * You can suppress sync for a particular bug object by setting a member
variable called C<suppress_sync>. 

=back

=head1 LICENSE

This software is available under the Mozilla Public License 1.1.

=cut
