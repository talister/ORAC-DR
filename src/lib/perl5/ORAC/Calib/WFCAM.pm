package ORAC::Calib::WFCAM;

=head1 NAME

ORAC::Calib::WFCAM;

=head1 SYNOPSIS

  use ORAC::Calib::WFCAM;

  $Cal = new ORAC::Calib::WFCAM;

  $dark = $Cal->dark;
  $Cal->dark("darkname");

  $Cal->standard(undef);
  $standard = $Cal->standard;
  $readnoise = $Cal->readnoise;

=head1 DESCRIPTION

This module contains methods for specifying WFCAM-specific calibration
objects. It provides a class derived from ORAC::Calib.  All the
methods available to ORAC::Calib objects are available to
ORAC::Calib::WFCAM objects.

=cut

use ORAC::Calib;			# use base class
use ORAC::Print;

use base qw/ORAC::Calib/;

use vars qw/$VERSION/;
'$Revision$ ' =~ /.*:\s(.*)\s\$/ && ($VERSION = $1);

# @ORAC::Calib::WFCAM::ISA = qw/ORAC::Calib/; # set up inheritance

# standard error module and turn on strict
use Carp;
use strict;

=head1 METHODS

The following methods are available:

=head2 Constructor

=over 4

=item B<new>

Sub-classed constructor. Adds knowledge of linearity and confidence maps.

  my $Cal = new ORAC::Calib::WFCAM;

=cut

sub new {
    my $self = shift;
    my $obj = $self->SUPER::new(@_);

    # Assumes we have a hash object

    $obj->{CPM} = undef;
    $obj->{CPMIndex} = undef;
    $obj->{CPMNoUpdate} = 0;
    $obj->{Lintab} = undef;
    $obj->{LintabIndex} = undef;
    $obj->{LintabNoUpdate} = 0;
  
    return $obj;

}


=back

=head2 Accessors

=over 4

=item B<lintabname>

Return (or set) the name of the current linearity curve

  $mask = $Cal->lintabname;

The C<lintab()> method should be used if a test for suitability of the
linearity table is required.

=cut


sub lintabname {
    my $self = shift;
    if (@_) { $self->{Lintab} = shift unless $self->lintabnoupdate; }
    return $self->{Lintab}; 
};


=item B<lintabindex>

Return or set the index object associated with the linearity table

  $index = $Cal->lintabindex;

An index object is created automatically the first time this method
is run.

=cut

sub lintabindex {

    my $self = shift;
    if (@_) { $self->{LintabIndex} = shift; }
    unless (defined $self->{LintabIndex}) {
        my $indexfile = $ENV{ORAC_DATA_OUT}."/index.lintab";
        my $rulesfile = $ENV{ORAC_DATA_CAL}."/rules.lintab";
        $self->{LintabIndex} = new ORAC::Index($indexfile,$rulesfile);
    };

    return $self->{LintabIndex};

};

=item B<lintabnoupdate>

Stops object from updating itself with more recent data.
Used when overrding the linearity table from the command-line.

=cut

sub lintabnoupdate {

    my $self = shift;
    if (@_) { $self->{LintabNoUpdate} = shift; }
    return $self->{LintabNoUpdate};

}

=item B<CPMname>

Return (or set) the name of the current confidence map.

  $mask = $Cal->CPMname;

The C<CPM()> method should be used if a test for suitability of the
confidence map is required.

=cut


sub CPMname {
    my $self = shift;
    if (@_) { $self->{CPM} = shift unless $self->CPMnoupdate; }
    return $self->{CPM}; 
};


=item B<CPMindex>

Return or set the index object associated with the confidence map

  $index = $Cal->CPMindex;

An index object is created automatically the first time this method
is run.

=cut

sub CPMindex {

    my $self = shift;
    if (@_) { $self->{CPMIndex} = shift; }
    unless (defined $self->{CPMIndex}) {
        my $indexfile = $ENV{ORAC_DATA_OUT}."/index.cpm";
        my $rulesfile = $ENV{ORAC_DATA_CAL}."/rules.cpm";
        $self->{CPMIndex} = new ORAC::Index($indexfile,$rulesfile);
    };

    return $self->{CPMIndex};

};

=item B<CPMnoupdate>

Stops object from updating itself with more recent data.
Used when overrding the confidence map from the command-line.

=cut

sub CPMnoupdate {

    my $self = shift;
    if (@_) { $self->{CPMNoUpdate} = shift; }
    return $self->{CPMNoUpdate};

}

=back

=head2 General Methods

=over 4

=item B<lintab>

Return (or set) the name of the current linearity table. If a table is to be 
returned every effort is made to guarantee that it is suitable for use.

  $lintab = $Cal->lintab;
  $Cal->lintab($newlintab);

=cut


sub lintab {

    my $self = shift;

    if (@_) {
        return $self->lintabname(shift);
    };

    my $ok = $self->lintabindex->verify($self->lintabname,$self->thing);

    # happy ending

    return $self->lintabname if $ok;

    croak ("Override linearity table is not suitable! Giving up") 
        if $self->lintabnoupdate;

    if (defined $ok) {
        my $lintab = $self->lintabindex->choosebydt('ORACTIME',$self->thing);
        if (! defined $lintab) {
            croak "No suitable linearity table was found in index file";
        }

        # Store the good value

        $self->lintabname($lintab);

    } else {

        # All fall down....

        croak("Error in determining linearity table - giving up");
    }
}

=item B<CPM>

Return (or set) the name of the current confidence map. If a map is to be 
returned every effort is made to guarantee that it is suitable for use.

  $cpm = $Cal->CPM;
  $Cal->CPM($newCPM);

=cut


sub CPM {

    my $self = shift;

    if (@_) {
        return $self->CPMname(shift);
    };

    my $ok = $self->CPMindex->verify($self->CPMname,$self->thing,0);

    # happy ending

    return $self->CPMname if $ok;

    croak ("Override confidence map is not suitable! Giving up") 
        if $self->CPMnoupdate;

    if (defined $ok) {
        my $cpm = $self->CPMindex->choosebydt('ORACTIME',$self->thing,0);
        if (! defined $cpm) {
            croak "No suitable confidence map was found in index file";
        }

        # Store the good value

        $self->CPMname($cpm);

    } else {

        # All fall down....

        croak("Error in determining confidence map - giving up");
    }
}

=item B<flat>

Return (or set) the name of the current flat.

  $flat = $Cal->flat;

Stolen from the base class soley in order to get rid of the boring warning
messages every time you need to change flats because you are doing a different
chip...

=cut


sub flat {
    my $self = shift;
    if (@_) {

        # if we are setting, accept the value and return

        return $self->flatname(shift);
    };

    my $ok = $self->flatindex->verify($self->flatname,$self->thing,0);

    # happy ending - frame is ok

    if ($ok) {return $self->flatname};

    croak("Override flat is not suitable! Giving up") if $self->flatnoupdate;

    # not so good

    if (defined $ok) {
        my $flat = $self->flatindex->choosebydt('ORACTIME',$self->thing,0);
        croak "No suitable flat was found in index file" unless defined $flat;
        $self->flatname($flat);
    } else {
        croak("Error in flat calibration checking - giving up");
    };
};


=item B<dark>

Return (or set) the name of the current dark - checks suitability on return.

Stolen from the base class soley in order to get rid of the boring warning
messages every time you need to change darks because you are doing a different
chip...

=cut

sub dark {
    my $self = shift;
    if (@_) {

        # if we are setting, accept the value and return

        return $self->darkname(shift);
    };

    my $ok = $self->darkindex->verify($self->darkname,$self->thing,0);

    # happy ending - frame is ok

    if ($ok) {return $self->darkname};
    croak("Override dark is not suitable! Giving up") if $self->darknoupdate;

    # not so good

    if (defined $ok) {
        my $dark = $self->darkindex->choosebydt('ORACTIME',$self->thing,0);
        croak "No suitable dark calibration was found in index file"
            unless defined $dark;
        $self->darkname($dark);
    } else {
        croak("Error in dark calibration checking - giving up");
    };
};

=back

=head1 REVISION

$Id$

=head1 AUTHORS

Jim Lewis (jrl@ast.cam.ac.uk)

=head1 COPYRIGHT

Copyright (C) 2002-2003 Cambridge Astronomy Survey Unit
All Rights Reserved.

=cut


1;
