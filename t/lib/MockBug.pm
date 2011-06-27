package MockBug;

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
