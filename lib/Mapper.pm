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

package Bugzilla::Extension::Sync::Mapper;
use strict;
use base qw(Exporter);

our $VERSION = '0.1';

our @EXPORT = qw(map_bug_to_external
                 map_external_to_bug);

use Bugzilla;
use Bugzilla::Extension::Sync::Util;

use Data::Visitor::Callback;
use Clone qw(clone);
use Data::Dumper;

###############################################################################
# Bug to external
# 
# Params: bug, map
# Return: data structure of external data, based on map with substitutions
###############################################################################
sub map_bug_to_external {
    my ($bug, $map) = @_;
    
    my $visitor = Data::Visitor::Callback->new(
        'Bugzilla::Extension::Sync::S' => sub {
            my ($visitor, $params) = @_;
    
            my $value = undef;

            if ($params->{'function'}) {
                my $fn = $params->{'function'};
                $value = &$fn($bug);
            }
            elsif ($params->{'literal'}) {
                $value = $params->{'literal'};
            }
            elsif ($params->{'sync_data_field'}) {
                my $sdf = $params->{'sync_data_field'};
                $value = ($bug->sync_data && $bug->sync_data->{$sdf}) 
                         || undef;
            }
            elsif ($params->{'field'}) {
                my $bzfield = $params->{'field'};
                my $bzvalue = $bug->$bzfield();
                
                if ($params->{'map'}) {
                    my $map = $params->{'map'};
                    
                    if (exists($map->{$bzvalue})) {
                        $value = $map->{$bzvalue};
                    }
                    elsif (exists($map->{'_default'})) {
                        $value = $map->{'_default'};
                    }
                    elsif (exists($map->{'_error'})) {
                        $value = $map->{'_error'};
                        
                        field_error("unknown_bzvalue", $bug, {
                            bzfield => $bzfield,
                            bzvalue => $bzvalue,
                            value   => $value
                        });
                    }
                    else {
                        # Coding error = no _default or _error defined in hash
                        field_error("unknown_bzvalue_bad_map", $bug, {
                            bzfield => $bzfield,
                            value   => $bzvalue
                        });
                    }
                }
                else {
                    # No mapping; direct value transfer.
                    $value = $bzvalue;
                }
            }
            else {
                # Coding error - unknown instructions in Mapping.pm
                error("no_instruction", { 
                    params   => Dumper($params),
                    map_name => $map->{'-name'} 
                });
            }
            
            if ($value && $value eq '---') {
                # '---' is the default, non-removable value for custom fields.
                # However, it usually isn't a valid value in the external
                # system.
                $value = undef;
            }
    
            $_ = $value;
        },
    );

    my $ext = clone($map);
    
    $visitor->visit($ext);
    
    # Delete hash keys with undefine values. This is how a map indicates that
    # a value should be removed entirely. If you want a blank value, use "".
    $visitor = Data::Visitor::Callback->new(
        'hash' => sub {
            my ($visitor, $data) = @_;
            foreach my $key (keys %$data) {
                delete $data->{$key} if !defined($data->{$key});
            }
        }
    );

    $visitor->visit($ext);
    
    return $ext;
}

###############################################################################
# External to bug
###############################################################################
sub map_external_to_bug {
    my ($ext, $bug, $map, $ext_id) = @_;

    my $is_new_bug = !$bug->id;
    
    if (!$is_new_bug) {
        if (grep { $_->name eq 'syncerror' } 
                  @{ $bug->keyword_objects }) 
        {
            if (Bugzilla->params->{'sync_debug'}) {
                warn "Not syncing bug " . $bug->id . 
                     " - bug has had sync error.";
            }
            
            return;
        }
        
        if (!defined($bug->{'cf_sync_mode'}) ||
            $bug->{'cf_sync_mode'} eq '---') 
        {
            error('got_update_for_unsynced_bug', { 
                bug_id => $bug->id,
                ext_id => $ext_id
            });
            
            return;
        }        
    }
    
    foreach my $field (keys %$map) {
        # Skip over annotations, which begin with a hyphen
        next if $field =~ /^-/;
        
        my $params = $map->{$field};
        
        next if !defined($params);
        next if !$is_new_bug && $params->{'newbugonly'};

        # Get the field value to map.
        # Note: $value is not necessarily a scalar
        my $value = $ext->{$field};

        # Some values are optional
        next if !defined($value);
        
        if ($params->{'function'}) {
            my $fn = $params->{'function'};
            eval {
                &$fn($bug, $value);
            };

            if ($@) {
                field_error('invalid_bzvalue', $bug, {
                    ext_id => $ext_id,
                    field  => $field,
                    value  => $value,
                    msg    => $@
                });
            }                
        }
        elsif ($params->{'field'}) {
            my $bzfield = $params->{'field'};
            my $old_value = $bug->{$bzfield};
            my $setter = find_setter($bug, $bzfield);
            my $newvalue = $value;
            
            if ($params->{'map'}) {
                my $map = $params->{'map'};
                
                if (exists($map->{$value})) {
                    $newvalue = $map->{$value};
                }
                elsif (exists($map->{'_default'})) {
                    $newvalue = $map->{'_default'};
                }
                elsif (exists($map->{'_error'})) {
                    $newvalue = $map->{'_error'};
                    
                    field_error('unknown_value', $bug, {
                        ext_id   => $ext_id,
                        field    => $field,
                        value    => $value,
                        bzvalue  => $map->{'_error'}
                    });
                }
                else {
                    # Coding error = no _default or _error defined in 
                    # hash
                    field_error('unknown_value_bad_map', $bug, {
                        ext_id => $ext_id,
                        field  => $field,
                        value  => $value
                    });
                    
                    # So we just ignore the value which was sent
                    $newvalue = undef;
                }
            }
            
            if (defined($newvalue)) {
                eval {
                    $setter->($newvalue);
                };
                
                if ($@) {
                    field_error('invalid_bzvalue', $bug, {
                        ext_id   => $ext_id,
                        field    => $field,
                        bzfield  => $bzfield,
                        value    => $value,
                        newvalue => $newvalue,
                        msg      => $@
                    });
                }                
            }
            
            if ($params->{'collisionwarning'} && 
                $bug->{$bzfield} && 
                $old_value &&
                ($bug->{$bzfield} ne $old_value)) 
            {
                maybe_collision_warning($bug, $bzfield, $value);
            }
        }                
        else {
            # Error - unknown instructions in Mapping.pm
            error("no_instruction", { 
                params   => Dumper($params),
                map_name => $map->{'-name'} 
            });
            
            # So we just ignore the value which was sent
        }
        
    }
    
    # If bug has no ID, it is a shell, and needs creating
    if ($is_new_bug) {
        my @added_comments = @{ $bug->{'added_comments'} || [] };
        # XXX Ideally, we would reorder comments here in some saner way...

        # Move initial comment into comment and commentprivacy fields
        # because that's what create() wants.
        my $first_comment = shift(@added_comments);
        $bug->{'comment'} = $first_comment->{'thetext'};
        
        # Version check because name of param changed
        Bugzilla::Constants::BUGZILLA_VERSION =~ /^(\d+\.\d+)/;
        if ($1 > 4.0 || !defined($1)) {
            $bug->{'comment_is_private'} = $first_comment->{'isprivate'};
            $bug->{'comment_bug_when'} = $first_comment->{'bug_when'};
        }
        else {
            $bug->{'commentprivacy'} = $first_comment->{'isprivate'};
        }
        
        # Version is compulsory in Bugzilla, but can't be set until product
        # and component are set (even if the value is present everywhere).
        # So we default it here.
        $bug->{'version'} ||= "Unspecified";

        # create() doesn't like additional hash members, so remove them.
        foreach my $field ("component_obj",
                           "product_obj",
                           "keyword_objects",
                           "added_comments",
                           "_multi_selects",
                           "status",
                           "dup_id")
        {
            delete $bug->{$field};
        }
        
        # We use the shell bug as the params hash for the create call,
        # and get back a proper new bug, with an ID and everything.
        eval {
            $bug = Bugzilla::Bug->create($bug);
        };
        if ($@) {
            error("cant_create_bug", { 'bug' => $bug, 'msg' => $@ });
            return;
        }
        
        # Insert comments from $bug beyond the first, if any
        if (scalar @added_comments) {
            foreach my $comment (@added_comments) {
                $comment->{'bug_id'} = $bug->id;
            }
            
            $bug->{'added_comments'} = \@added_comments;
        }
    }
    
    return $bug;
}

sub maybe_collision_warning {
    my ($bug, $field_name, $value) = @_;
    
    # Find out last time $field_name was changed in history table. If that 
    # time is after the last sync time, then add comment with both older 
    # values and the new value from the remote system.
    my $field = new Bugzilla::Field({name => $field_name});
    
    my $dbh = Bugzilla->dbh;
    my $result = $dbh->selectrow_arrayref("SELECT removed, added 
                                           FROM bugs_activity, bugs 
                                           WHERE bugs.bug_id = ? 
                                            AND bugs_activity.bug_id = ?
                                            AND fieldid = ? 
                                            AND bug_when > bugs.cf_sync_delta_ts
                                            AND added != ?
                                           ORDER BY bug_when DESC 
                                           LIMIT 1", 
                                          undef, $bug->id, $bug->id, 
                                          $field->id, $value);

    if (defined($result)) {
        field_error('collision_warning', $bug, {
            field  => $field_name,
            old_bz => $result->[0],
            new_bz => $result->[1],
            value  => $value
        });            
    }
}

1;

=head1 NAME

Bugzilla::Extension::Sync::Mapper - maps bugs to and from other data structures.

=head1 DESCRIPTION

This class has functions for generically mapping bugs to and from other
arbitrary data structures (which can then be serialized and sent to a remote
system).

=head1 SYNOPSIS

  my $bug = get_bug_for($bug_id, $SYSTEM, $remote_id);
  
  $bug = map_external_to_bug($extdata, $bug, $map, $remote_id);

  ...
  
  my $bug = new Bugzilla::Bug(1);
  
  map_bug_to_external($bug, $map);
    
=head1 DESCRIPTION

=head2 Mapping

The two main functions in this package take as one of their arguments a map,
which defines how the mapping is to be done from bug fields to external 
structure fields, or vice versa.

The map is a hash. The keys are the "names" for each field, and the values
are either C<undef>, which means "do nothing with this field", or some 
commands. The two functions in this case are not quite identical, because
map_bug_to_external uses Bugzilla::Util::Sync::S objects to contain its 
commands, while map_external_to_bug uses plain hashes. This anomaly may be
rectified in the future.

Within the hash or object, particular keys and values trigger particular 
behaviours:

=over

=item C<field =E<lt> 'foo'>

This means "copy the value to/from field foo".

=item C<map =E<lt> { ... }>

This means "...and, when doing so, use this value mapping". Within the map:

=over

=item * A normal key/value pair does exactly what you would expect

=item * C<_default> means "use this value if none is supplied"

=item * C<_error> means "use this value if none is supplied, but that's something 
which shouldn't happen, so record the fact"

=back

=item C<literal => 'foo'>

This means "use the value 'foo', literally, every time".

=item C<newbugonly =E<lt> 1>

This means "do this action only for bugs we are seeing for the first time."

=item C<collisionwarning =E<lt> 1>

This means "Work out if the sync delays mean this value has been updated on 
both sides simultaneously, and if so, warn the Bugzilla users by adding a 
comment"

=item C<function =E<lt> \&foo>

This means "call this function because we need special processing which is 
more complicated than any of the set options". The callback functions have a 
set interface, which is different for the two different maps. 
 
map_external_to_bug's callback functions work as follows: 
  Params - bug
         - value of appropriate field in the external data 
  Return - nothing; function should update the bug
  
map_bug_to_external's callback functions work as follows: 
  Params - bug
  Return - the value which should be placed in the field to which the function
           relates.

=back

=head2 Methods

=over

=item C<map_external_to_bug>

This function maps external data to bug fields. 

Parameters: the external data, the bug, the map (a data structure which 
defines how the mapping is done, as explained above) and the external issue ID.

It returns a bug object (not necessarily the same one passed in) or C<undef> 
if the bug is not being synced. You must call C<$bug-E<lt>update()> on the 
returned bug.

=item C<map_bug_to_external>

This function maps bug fields to external data; you get back a data structure
which is like the map you sent in, but with all the instruction objects replaced
with the bit of data which those instructions ferreted out from the bug.

=back

=head1 LICENSE

This software is available under the Mozilla Public License 1.1.

=cut
