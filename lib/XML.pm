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

package Bugzilla::Extension::Sync::XML;
use strict;

use base qw(Exporter);
our @EXPORT = qw(
    datetime_to_xsd
    xsd_to_datetime
    extract_with_xpath
    populate_with_xpath
    structure_to_libxml
    libxml_to_structure
);

use Bugzilla::Util qw(datetime_from trim);
use Bugzilla::Extension::Sync::Util;
use Tie::IxHash;
use XML::LibXML;

# Can take a string or a DateTime object
sub datetime_to_xsd {
    my ($dt) = @_;
    
    if (!ref $dt) {
        $dt = datetime_from($dt);
    }
    
    my $xsddt = DateTime::Format::XSD->format_datetime($dt);
    return $xsddt;
}

# Returns string only
sub xsd_to_datetime {
    my ($xsddt) = @_;
    my $dt_obj = DateTime::Format::XSD->parse_datetime($xsddt);
    my $sqldt = DateTime::Format::MySQL->format_datetime($dt_obj);
    return $sqldt;
}

# Note: single node/attribute targets only
sub extract_with_xpath {
    my ($doc, $map) = @_;
    
    my $data = {};
    
    my $xpc = XML::LibXML::XPathContext->new($doc);
    
    foreach my $key (keys %$map) {
        if (!$map->{$key}) {
            error("no_xpath_for_key", { key => $key });
            next;
        }
        my @nodes = $xpc->findnodes($map->{$key});
        
        if (@nodes) {
            my $structure = libxml_to_structure($nodes[0]);
            
            # If we get back a simple element (no sub-elements) with a "content" 
            # member, use the content; anything more complex we keep as-is.
            if (ref($structure) eq "HASH") {
                my $complex = 0;
                
                foreach my $value (values(%$structure)) {
                    if (ref($value)) {
                        $complex = 1;
                        last;
                    }
                }
                
                if (!$complex && exists($structure->{'content'})) {
                    $structure = $structure->{'content'};
                }
            }
                    
            $data->{$key} = $structure;
        }
        else {
            # We can't assume that every field is always present, so we 
            # just ignore this.
            next;
        }
    }

    return $data;
}

sub populate_with_xpath {
    my ($doc, $map, $data) = @_;
    
    my $xpc = XML::LibXML::XPathContext->new($doc);
    
    # Foreach value in $data, stick it at the location in $doc defined by the 
    # XPath in $map with the same key.    
    foreach my $key (keys %$data) {
        next if $key =~ /^-/;
        
        if (!$map->{$key}) {
            error("no_xpath_for_key", { key => $key });
            next;
        }
        
        my @nodes = $xpc->findnodes($map->{$key});
        
        if (@nodes) {
            if (defined($data->{$key})) {
                $nodes[0]->removeChildNodes();
                structure_to_libxml($data->{$key}, $nodes[0]);
            }
            else {
                # 'undef' for data value means: 'remove this bit entirely'
                if ($nodes[0]->nodeType == XML_ATTRIBUTE_NODE) {
                    my $parent = $nodes[0]->getOwnerElement();
                    $parent->removeAttribute($nodes[0]->nodeName);
                }
                else {
                    $nodes[0]->parentNode->removeChild($nodes[0]);
                }
            }
        }
    }
}

sub structure_to_libxml {
    my ($struct, $parent) = @_;
    
    my $ref = ref($struct);
    if ($ref eq "HASH") {
        foreach my $key (keys %$struct) {
            if (ref($struct->{$key}) eq "HASH") {
                my $new = XML::LibXML::Element->new($key);
                structure_to_libxml($struct->{$key}, $new);
                $parent->appendChild($new);
            }
            elsif (ref($struct->{$key}) eq "ARRAY") {
                foreach my $value (@{ $struct->{$key} }) {
                    my $new = XML::LibXML::Element->new($key);
                    structure_to_libxml($value, $new);
                    $parent->appendChild($new);
                }
            }
            elsif ($key eq "content") {
                $parent->appendChild(XML::LibXML::Text->new($struct->{$key}));
            }
            else {
                $parent->setAttribute($key, $struct->{$key});
            }
        }
    }
    elsif (!$ref) {
        $parent->appendChild(XML::LibXML::Text->new($struct));
    }
    elsif ($ref eq "ARRAY") {
        # Doubly-nested or top-level array - not allowed
    }
    else {
        # Only hashes, arrays and scalars allowed
    }
}

# No mixed content! :-)
sub libxml_to_structure {
    my ($doc) = @_;

    my $retval;
    
    if ($doc->isa('XML::LibXML::Attr')) {
        $retval = $doc->value;
    }
    elsif ($doc->isa('XML::LibXML::Text')) {
        $retval = $doc->nodeValue;
    }
    else {
        # Hashes have to be ordered for round-trippability
        my %hash;
        tie(%hash, 'Tie::IxHash');
        $retval = \%hash;
        
        foreach my $attr ($doc->attributes()) {
            $retval->{$attr->nodeName} = $attr->value;
        }
        
        foreach my $node ($doc->childNodes()) {
            if ($node->isa('XML::LibXML::Text')) {
                if (trim($node->nodeValue)) {
                    $retval->{'content'} = trim($node->nodeValue);
                }
            }
            elsif ($node->isa('XML::LibXML::Element')) {
                my $value = libxml_to_structure($node);
                
                my $nn = $node->nodeName;
                if (!$retval->{$nn}) {
                    # Simple values coming back must be text, so they need to
                    # be wrapped in arrayref so they don't look like attrs.
                    if (!ref($value)) {
                        $value = [$value];
                    }
                
                    $retval->{$nn} = $value;
                }
                else {
                    # Use array if there's more than one tag of the same name
                    if (!(ref($retval->{$nn}) eq "ARRAY")) {
                        $retval->{$nn} = [$retval->{$nn}];
                    }

                    push(@{ $retval->{$nn} }, $value);
                }
            }
        }
        
        # Collapse "content" if possible
        if (scalar(keys(%$retval)) == 1 && defined($retval->{'content'})) {
            $retval = $retval->{'content'};
        }
    }
    
    return $retval;
}

1;

__END__

=head1 NAME

Bugzilla::Extension::Sync::XML - a grab-bag of XML-related functions for 
                                  implementing Sync plugins.

=head1 SYNOPSIS

None yet.
  
=head1 DESCRIPTION

This package provides a load of useful functions for implementing Sync
plugins where those extensions are communicating with the remote system
in XML format. This documentation is currently just an overview; you'll need to 
read the code to see exact parameters and return values.

=head2 datetime_to_xsd

Converts a timestamp string (e.g. creation_ts or delta_ts) to an XML Schema
date.

=head2 xsd_to_datetime

Converts an XML Schema date to an SQL timestamp string.

=head2 extract_with_xpath

Pass this function a LibXML XML document, and a hash where the key is a name
of some sort and the value is an XPath expression, and it'll return you another
hash where the keys are the same, and the values are the data at the end of
that expression.

This is great for simplifying complex XML into a set of key-value pairs.

=head2 populate_with_xpath

This function is the reverse of the above, and can use the same map. Give it
a skeleton LibXML document, a map, and some data, and it will insert the data
back into the document at the appropriate place according to the XPaths.

=head2 structure_to_libxml

Sometimes you need to work with an XML-based data structure, but it's much 
easier to do it as a Perl data structure, and convert it to LibXML objects
later. This function allows you to turn a Perl data structure into a LibXML 
structure. In other words, this function works a bit like L<XML::Simple>.

  {
      Element => { AttrName => AttrValue,
                   SubTag1 => [ SubTag1Text ],
                   SubTag2 => [ SubTag2Text1, SubTag2Text2 ],
                   SubTag3 => { SubAttrName => SubAttrValue 
                                content => SubTag3Text }
  }
  
  => the LibXML equivalent of:
  
  <Element AttrName="AttrValue">
    <SubTag1>SubTag1Text</SubTag1>
    <SubTag2>SubTag2Text1</SubTag2>
    <SubTag2>SubTag2Text2</SubTag2>
    <SubTag3 SubAttrName="SubAttrValue">SubTag3Text</SubTag3>
  </Element>

Nest as much as you want. Rules: hashes, arrays and scalars only; no arrays 
directly inside arrays (that makes no sense) and the top-level structure must 
be a hash.

Node text content is normally just a scalar, but if an element has both
attributes and text content, represent it as a hash, with the text content 
being the value of a key called "content".

=head2 libxml_to_structure

The reverse of the above. Takes a LibXML object and turns it into a sensible
Perl data structure.

=over

=item * Text nodes => their text
=item * Attribute nodes => the attribute value
=item * Element nodes => a hash as above, with content and attributes

Note that the returned value does not include the nodeName of the top-level
element passed in - it'll be the hash representing that element's contents
and attributes.

=head1 LICENSE

This software is available under the Mozilla Public License 1.1.

=cut
