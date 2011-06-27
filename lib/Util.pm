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
    get_error_email_ids

    get_or_create_user

    update_bug_field_directly

    find_setter
    get_bug_for
    
    log_data
    
    get_default_component_owner
);

use Bugzilla::Util qw(generate_random_password datetime_from);
use Bugzilla::Config qw(:admin);
use Bugzilla::Mailer;
use Bugzilla::User qw(login_to_id);
use Bugzilla::Constants;

use File::Slurp;
use Cwd qw(realpath);

# General errors not specific to a particular bug
sub error {
    my ($error, $vars) = @_;

    my $msg = get_message("error", $error, $vars);

    record_error_message($msg);
}

# Call when a particular field cannot be synced but the rest of the bug is OK.
# Caller must eventually call $bug->update().
sub field_error {
    my ($error, $bug, $vars) = @_;

    $vars->{'bug'} = $bug;
    my $msg = get_message("field-error", $error, $vars);

    record_error_message($msg);

    my $dbh = Bugzilla->dbh;
    my $timestamp = $dbh->selectrow_array("SELECT LOCALTIMESTAMP(0)");

    $bug->add_comment($msg, { 'bug_when' => $timestamp });

    # Add keyword to prevent further syncing. Caller must eventually call
    # bug->update();
    $bug->modify_keywords('syncerror', 'add');
}

# Call when there is a problem exchanging data. Issues a warning or
# error depending on whether we've finally given up.
sub sync_problem {
    my ($error, $vars) = @_;

    if ($vars->{'job'}->failures + 1 >= $vars->{'worker'}->max_retries) {
        $vars->{'fatal'} = 1;

        if (!Bugzilla->params->{'sync_debug'}) {
            # Turn off all syncing
            SetParam('sync_enabled', 0);
            write_params();
        }
    }

    my $msg = get_message("sync-error", $error, $vars);

    record_error_message($msg);
}

sub get_message {
    my ($template_name, $error, $vars) = @_;

    my $template = Bugzilla->template;
    $vars->{'error'} = $error;
    my $msg;
    $template->process("sync/$template_name.txt.tmpl", $vars, \$msg);

    return $msg;
}

sub record_error_message {
    my ($msg) = @_;

    if (Bugzilla->params->{'sync_debug'}) {
        warn $msg;
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
}

sub get_error_email_ids {
    my @emails = split(/\s*,\s*/, Bugzilla->params->{'sync_error_email'});
    my @ids = ();
    foreach my $email (@emails) {
        push (@ids, login_to_id($email));
    }

    return @ids;
}

sub get_or_create_user {
    my %args = @_;
    # Inputs: hash, with 'name' or 'email' parameters, plus 'domain' 
    # parameter for domain to use for new invalid accounts.
    # Output: single user object - match, or newly-created user
    my $email = $args{'email'};
    my $name = $args{'name'};
    my $domain = $args{'domain'} || "invalid.invalid";

    my $users = Bugzilla::User::match($email || $name);
    my $user = $users->[0];
    if (!$user) {
        if (!$email) {
            $email = lc($name);
            $email =~ s/\s+/\./g;
            $email =~ s/[^a-z\.]//g;
            $email .= "\@$domain";
        }

        $user = Bugzilla::User->create({
            login_name      => $email,
            cryptpassword   => generate_random_password(),
            realname        => $name
        });

        $user->set_disable_mail(1);
    }

    return $user;
}

sub update_bug_field_directly {
    my ($bug_id, $field, $value) = @_;
    my $dbh = Bugzilla->dbh;
    $dbh->do("UPDATE bugs SET $field = ? WHERE bug_id = ?", undef,
             $value, $bug_id);
}

my $setters = {
    bug_severity => 'set_severity',
    rep_platform => 'set_platform',
    short_desc   => 'set_summary',
    bug_file_loc => 'set_url',
    product      => sub { return set_from_name($_[0], 'product', $_[1]) },
    component    => sub { return set_from_name($_[0], 'component', $_[1]) },
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
sub set_from_name {
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
        error("bad_field_value", { 'field' => $field, 'value' => $value });
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
    }
    else {
        # Sanity check that $ext_id is what we expect
        if ($ext_id ne $bug->{'cf_refnumber'}) {
            field_error('mismatched_external_id', $bug, { 
                ext_id       => $ext_id,
                cf_refnumber => $bug->{'cf_refnumber'} 
            });
            
            $bug->update();
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
    write_file($filename, { 'binmode' => 'utf8' }, $data);
    
    return $filename;
}

sub get_default_component_owner {
    my ($component_id) = @_;

    # Fill in from initial owner of selected component
    my $dbh = Bugzilla->dbh;
    my $io = $dbh->selectrow_arrayref("SELECT login_name, realname
                                       FROM profiles, components AS cmp
                                       WHERE profiles.userid = cmp.initialowner
                                       AND cmp.id = ?",
                                       undef, $component_id);
    # Every component has a default owner, so we will get an value returned.
    # But remember realname is optional.
    my %owner;
    tie (%owner, 'Tie::IxHash',
        'realname' => $io->[1] || $io->[0],
        'email'    => $io->[0]
    );

    return \%owner;
}

1;