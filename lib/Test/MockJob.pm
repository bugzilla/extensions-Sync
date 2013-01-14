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

package Bugzilla::Extension::Sync::Test::MockJob;

sub new {
    my $class = shift;
    my $self = {};
    bless $self, $class;
    $self->set_arg($_[0]);
    return $self;
}

sub failed {
    my ($self) = shift;
    $self->{'exit_status'} = $_[0] || 1;
}

sub completed {
    my ($self) = shift;
    $self->{'exit_status'} = 0;
}

sub declined {
    my ($self) = shift;
    $self->{'was_declined'} = 1;
    $self->{'exit_status'} = 0;
}
sub exit_status {
    my ($self) = shift;
    return $self->{'exit_status'};
}

sub set_arg {
    my ($self) = shift;
    $self->{'arg'} = shift;
}

sub arg {
    my ($self) = shift;
    return $self->{'arg'};
}

1;
