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
        dispatch_sync_event('bug_updated', $bug->sync_system(), {
            bug       => $bug,
            changes   => $changes,
            timestamp => $args->{'timestamp'}
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
        #
        # XXXAdd sync suppression system to attachments
        dispatch_sync_event('attachment_created',
                            $attachment->bug->sync_system(),
                            { attachment => $attachment });
    }
}

# Attachment updated
#XXXCode not tested
sub object_end_of_update {
    my ($self, $args) = @_;
    my $object = $args->{'object'};

    if ($object->isa('Bugzilla::Attachment')) {
        my $attachment = $object;

        return if !$attachment->bug->is_syncing;

        # XXX Risk of loops here; event handlers need to be careful
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
