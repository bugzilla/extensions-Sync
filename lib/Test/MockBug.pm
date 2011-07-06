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

package Bugzilla::Extension::Sync::Test::MockBug;

our $AUTOLOAD;

sub new {
    my $class = shift;
    my $self = shift;
    bless $self, $class;
    return $self;
}

sub AUTOLOAD {
    my $self = $_[0];
    my $name = $AUTOLOAD;
    $name =~ s/.*://;
    
    if (exists $self->{$name}) {
        if (ref($self->{$name}) eq "CODE") {
            # Call a coderef
            *$AUTOLOAD = $self->{$name};
            goto &$AUTOLOAD;
        }
        else {
            # Return a variable or other thing
            return $self->{$name};
        }
    }
    
    return undef;
}

1;
