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

package Bugzilla::Extension::Sync::Util;
use strict;

use base qw(Exporter);
our @EXPORT = qw(
    error
    field_error
    sync_problem
    log_data
        
    store_sync_data
    find_setter
    get_bug_for
    get_or_create_user
    get_default_component_owner
    
    merge_hashrefs
);

use Bugzilla::Util qw(generate_random_password datetime_from);
use Bugzilla::Config qw(:admin);
use Bugzilla::Mailer;
use Bugzilla::User qw(login_to_id);
use Bugzilla::Constants;

use Cwd qw(realpath);
use File::Slurp;
use Carp;

# General errors not specific to a particular bug
sub error {
    my ($error, $vars) = @_;

    my $msg = _get_message("error", $error, $vars);

    _record_error_message($msg);
}

# Call when a particular field cannot be synced but the rest of the bug is OK.
# Caller must eventually call $bug->update().
sub field_error {
    my ($error, $bug, $vars) = @_;

    $vars->{'bug'} = $bug;
    my $msg = _get_message("field-error", $error, $vars);

    _record_error_message($msg);

    my $dbh = Bugzilla->dbh;
    my $timestamp = $dbh->selectrow_array("SELECT LOCALTIMESTAMP(0)");

    $bug->add_comment($msg, { 'bug_when' => $timestamp });

    if (!$vars->{'keep_trying'}) {
        # Add keyword to prevent further syncing. Caller must eventually call
        # bug->update();
        $bug->modify_keywords('syncerror', 'add');
    }    
}

# Call when there is a problem exchanging data. Issues a warning or
# error depending on whether we've finally given up.
sub sync_problem {
    my ($error, $vars) = @_;

    # Used if this sync attempt is a JobQueue job
    if ($vars->{'job'} && 
        $vars->{'job'}->failures + 1 >= $vars->{'worker'}->max_retries) {
        $vars->{'fatal'} = 1;
    }
    
    if ($vars->{'fatal'} && !Bugzilla->params->{'sync_debug'}) {
        # Turn off all syncing
        SetParam('sync_enabled', 0);
        write_params();
    }

    my $msg = _get_message("sync-error", $error, $vars);

    _record_error_message($msg);
}

sub _get_message {
    my ($template_name, $error, $vars) = @_;

    my $template = Bugzilla->template;
    $vars->{'error'} = $error;
    $vars->{'ref'} = sub { return ref($_[0]) };
    my $msg;
    $template->process("sync/$template_name.txt.tmpl", $vars, \$msg);

    return $msg;
}

sub _record_error_message {
    my ($msg) = @_;

    if (Bugzilla->params->{'sync_debug'}) {
        carp $msg;
    }

    my $recipients = Bugzilla->params->{'sync_error_email'};
    return if !$recipients;

    my $email;
    my $vars = {
        to      => $recipients,
        subject => "Sync Error",
        body    => $msg
    };

    my $template = Bugzilla->template;
    $template->process("sync/email.txt.tmpl", $vars, \$email);

    MessageToMTA($email);
   
    # Mail is not being delivered, so also write to a file
    my $dir = bz_locations()->{'extensionsdir'} . '/Sync/log';
    my $filename = "$dir/error_email_log.txt";
    $filename = realpath($filename);
    write_file($filename, { 'binmode' => 'utf8' }, $email . "\n\n");    
}

sub get_or_create_user {
    my %args = @_;
    # Inputs: hash, with 'name' or 'email' parameters, plus 'domain' 
    # parameter for domain to use for new invalid accounts.
    # Output: single user object - match, or newly-created user
    my $email = $args{'email'};
    my $name = $args{'name'};
    my $domain = $args{'domain'} || "invalid.invalid";

    if (!$email) {
        $email = lc($name);
        $email =~ s/\s+/\./g;
        $email =~ s/[^a-z\.]//g;
        $email .= "\@$domain";
    }

    # Second parameter is max number of results to return
    my $users = Bugzilla::User::match($email, 1);
    my $user = $users->[0];
    if (!$user) {
        $user = Bugzilla::User->create({
            login_name      => $email,
            cryptpassword   => generate_random_password(),
            realname        => $name
        });

        $user->set_disable_mail(1);
        $user->update();
    }

    return $user;
}

# Store sync data and update timestamp. This happens every update, so we do it 
# directly to avoid regular mid-airs. Users cannot change this field, so that's
# OK.
sub store_sync_data {
    my ($bug_id, $data) = @_;
    my $dbh = Bugzilla->dbh;
    $dbh->do("UPDATE bugs 
              SET cf_sync_data = ?, 
                  cf_sync_delta_ts = NOW() 
              WHERE bug_id = ?", 
              undef, $data, $bug_id);
}

my $setters = {
    bug_severity => 'set_severity',
    rep_platform => 'set_platform',
    short_desc   => 'set_summary',
    bug_file_loc => 'set_url',
    bug_status   => sub { $_[0]->{'bug_status'} = $_[1]; },
    product      => sub { return _set_from_name($_[0], 'product', $_[1]) },
    component    => sub { return _set_from_name($_[0], 'component', $_[1]) },
};

# Work out which function to call to set a particular value on a bug, and
# return it.
sub find_setter {
    my ($bug, $field) = @_;
    my $setter;

    if ($setters->{$field}) {
        # Special cases are handled by the 'setters' array above, which can
        # contain either names of functions, or anonymous subs.
        my $fn = $setters->{$field};
        if (ref($fn)) {
            $setter = sub { $fn->($bug, $_[0]) };
        }
        else {
            $setter = sub { $bug->$fn($_[0]) };
        }
    }
    elsif ($field =~ /^cf_/) {
        # There's a single function for updating custom fields
        my $fieldobj = new Bugzilla::Field({ name => $field });
        $setter = sub { $bug->set_custom_field($fieldobj, $_[0]) };
    }
    else {
        # Generic support; most fields have a setter like this
        my $fn = "set_" . $field;
        $setter = sub { $bug->$fn($_[0]) };
    }

    return $setter;
}

# Find the ID of the product or component ($field) with value $value.
sub _set_from_name {
    my ($bug, $field, $value) = @_;
    my $dbh = Bugzilla->dbh;
    
    # Minor hack
    my $extra = "-- ?";
    if ($field eq "component") {
        if ($bug->{'product_id'}) {
            $extra = "AND product_id = ?",
        }
        else {
            error("component_without_product", { 'value' => $value });
        }
    }
    
    my $id = $dbh->selectrow_arrayref("SELECT id
                                       FROM " . $field . "s
                                       WHERE name = ? $extra", 
                                       undef, 
                                       $value, $bug->{'product_id'});
    if ($id) {
        $bug->{$field . '_id'} = $id->[0];
        # Get the value of this field. As a side effect, this creates the
        # internal Bugzilla::Product or Bugzilla::Component object. We need to
        # do this as create() requires it.
        my $dummy = $bug->$field;
    }
    else {
        # We need a product, so this is fatal
        error("bad_device_name", { 
            'field'  => $field, 
            'value'  => $value,
            'bug'    => $bug
        });
    }
}

sub get_bug_for {
    my ($bug_id, $system, $ext_id) = @_;

    my $new_bug = !$bug_id;
            
    # See if the external ID is already in use
    my $dbh = Bugzilla->dbh;
    my $db_bug_id = $dbh->selectrow_array("SELECT bug_id 
                                           FROM bugs
                                           WHERE cf_refnumber = ?
                                           AND cf_sync_mode LIKE ?",
                                           undef, $ext_id, $system . '%');
    
    if ($new_bug && $db_bug_id) {
        # We've received an update for an external issue whose external ID is
        # marked on a bug we have, but they haven't sent us the relevant bug ID
        # of ours. Perhaps we weren't able to tell them yet? This is not a good
        # situation - but we certainly shouldn't create a new bug! Update the
        # old one with the data instead.
        $bug_id = $db_bug_id;
    }
        
    # Get bug for $bug_id (even if there isn't one)
    my $bug = new Bugzilla::Bug($bug_id);

    if ($new_bug) {
        # $bug_id is blank. So we have created a new Bug object with a
        # non-existent bug number. This sets an error flag.
        #
        # Remove the error flag. We now have a 'shell' Bug we can use,
        # which allows us to make a whole lot of other code common.
        delete($bug->{'error'});
        
        # Setting the status requires there to be an existing status, so we
        # hack one in. This makes $bug->set_status(...) just work.
        $bug->{'bug_status'} = "NEW";
        
        my $cf_rn_field = new Bugzilla::Field({ name => 'cf_refnumber' });
        $bug->set_custom_field($cf_rn_field, $ext_id);
    }
    else {
        # Sanity check that $ext_id is what we expect
        if (!defined($bug->{'cf_refnumber'}) ||
            $ext_id ne $bug->{'cf_refnumber'}) 
        {
            error('mismatched_ids', { 
                bug    => $bug,
                ext_id => $ext_id || ""
            });
            
            return;
        }
    }
    
    return $bug;
}

sub log_data {
    my $data = shift;
    my $ext = shift;

    my $stem = join("-", @_);
        
    my $now = DateTime->now->iso8601();
    my $dir = bz_locations()->{'extensionsdir'} . '/Sync/log';
    my $filename .= "$dir/$stem-$now.$ext";
    $filename = realpath($filename);
    open LOGFILE, ">:utf8", $filename;
    print LOGFILE $data;
    close(LOGFILE);
    
    return $filename;
}

sub get_default_component_owner {
    my ($component_id) = @_;

    # Fill in from initial owner of selected component
    my $dbh = Bugzilla->dbh;
    my $io_id = $dbh->selectrow_array("SELECT initialowner
                                       FROM components 
                                       WHERE components.id = ?",
                                       undef, $component_id);
    my $user = new Bugzilla::User($io_id);

    return $user;
}

sub merge_hashrefs {
    my ($a, $b) = @_;
    my %merged = (%$a, %$b);
    return \%merged;
}

1;

__END__

=head1 NAME

Bugzilla::Extension::Sync::Util - a grab-bag of useful functions for 
                                  implementing Sync plugins.

=head1 SYNOPSIS

None yet.
  
=head1 DESCRIPTION

This package provides a load of useful functions for implementing Sync
plugins. This documentation is currently just an overview; you'll need to 
read the code to see exact parameters and return values.

=head2 error

Call this if you have a general error.

You can add additional error tags and corresponding messages using template 
hooks.

=head2 field_error

Call this if you have an error syncing a particular field. It will post a
comment to the bug, but the sync can continue.

Note that you must call $bug->update() at some point after calling this 
function, if you hadn't planned to do so anyway. We don't do it for you, because
you may be in the middle of updating your Bug object.

You can add additional error tags and corresponding messages using template 
hooks.

=head2 sync_problem

Call this if you have a general problem exchanging data with a remote system.
It will issue a warning, and eventually give up and disable sync. This function
is designed for people using the JobQueue API to make their communications
asynchronous, and uses its inbuilt retry support to decide when to give up 
and disable sync.

=head2 get_or_create_user

Pass in either "name" or "email" parameters and this function will try and
find a matching user. If it can't find one, it will create one - with a made-up
invalid email address if necessary. (Pass in a 'domain' parameter to pick the
invalid domain that it will use.) Either way, it returns a L<Bugzilla::User>
object.

This is useful if you want to use a model of changes in Bugzilla appearing to
be made by the same people who actually made them in the remote system, and so
need an account for each user of the remote system which makes such a change,
but don't want to have to create them all in advance.

=head2 store_sync_data

Call this after you've finished a sync, with the sync data - it'll store it,
and update the sync timestamp. The sync data will then be available as a 
structure from C<$bug-E<lt>sync_data()>, and can be viewed by clicking a link
on the bug page.

=head2 find_setter

This function tells you what function to call to set a particular field on a 
bug. It knows about custom fields, and about some special cases where the setter
function is not named after the field.

=head2 get_bug_for

Given a bug ID and an external ID, returns a Bug object. If the bug ID already
exists, it'll be an object for that ID. If it doesn't, it'll be a "shell" 
object, with $bug->id == 0, but which can be used in place of a normal bug
object in functions which update and change bugs. Eventually, you can pass it
as a parameter to Bug->create() and you'll get a real bug back, with an ID
and an entry in the database.

This is useful to make a lot of code common between the cases where it's the
first time you've seen a bug coming from the remote system, and subsequent
times.
    
=head2 log_data

A convenience function to log some sync data to a file with a sensible name.
Data goes to $BUGZILLA_HOME/extensions/Sync/log. 

=head2 get_default_component_owner

Returns a L<Bugzilla::User> object representing the owner of the given 
component.

=head1 LICENSE

This software is available under the Mozilla Public License 1.1.

=cut
