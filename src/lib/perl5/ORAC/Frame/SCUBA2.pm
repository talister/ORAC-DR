package ORAC::Frame::SCUBA2;

=head1 NAME

ORAC::Frame::SCUBA2 - SCUBA-2 class for dealing with observation files in ORACDR

=head1 SYNOPSIS

  use ORAC::Frame::SCUBA2;

  $Frm = new ORAC::Frame::SCUBA2("filename");
  $Frm = new ORAC::Frame::SCUBA2(@files);
  $Frm->file("file")
  $Frm->readhdr;
  $Frm->configure;
  $value = $Frm->hdr("KEYWORD");

=head1 DESCRIPTION

This module provides methods for handling Frame objects that
are specific to SCUBA-2. It provides a class derived from B<ORAC::Frame>.
All the methods available to B<ORAC::Frame> objects are available
to B<ORAC::Frame::SCUBA2> objects. Some additional methods are supplied.

=cut

# A package to describe a JCMT frame object for the
# ORAC pipeline

use 5.006;
use warnings;
use strict;
use Carp;

use ORAC::Frame::NDF;
use ORAC::Constants;
use ORAC::Print;

use NDF;
use Starlink::HDSPACK qw/ retrieve_locs copobj /;
use Starlink::AST;

use vars qw/$VERSION/;

# Let the object know that it is derived from ORAC::Frame;
use base qw/ ORAC::Frame::NDF /;

# Use base doesn't seem to work...
#use base qw/ ORAC::Frame /;

'$Revision$ ' =~ /.*:\s(.*)\s\$/ && ($VERSION = $1);

=head1 PUBLIC METHODS

The following are modifications to standard ORAC::Frame methods.

=head2 Constructors

=over 4

=item B<new>

Create a new instance of a B<ORAC::Frame::SCUBA2> object.  This method
also takes optional arguments: if 1 argument is supplied it is assumed
to be the name of the raw file associated with the observation but if
a reference to an array is supplied, each file listed in the array is
used. If 2 arguments are supplied they are assumed to be the raw file
prefix and observation number. In any case, all arguments are passed
to the configure() method which is run in addition to new() when
arguments are supplied.  The object identifier is returned.

   $Frm = new ORAC::Frame::SCUBA2;
   $Frm = new ORAC::Frame::SCUBA2("file_name");
   $Frm = new ORAC::Frame::SCUBA2(\@files);
   $Frm = new ORAC::Frame::SCUBA2("UT","number");

This method runs the base class constructor and then modifies
the rawsuffix and rawfixedpart to be '.sdf' and 's4' or 's8'
(depending on instrument designation) respectively.

=cut

sub new {

  my $proto = shift;
  my $class = ref($proto) || $proto;

  # Run the base class constructor with a hash reference
  # defining additions to the class
  # Do not supply user-arguments yet.
  # This is because if we do run configure via the constructor
  # the rawfixedpart and rawsuffix will be undefined.
  my $self = $class->SUPER::new();

  # Configure initial state - could pass these in with
  # the class initialisation hash - this assumes that I know
  # the hash member name
  $self->rawfixedpart('s' . $self->_wavelength_prefix );
  $self->rawsuffix('.sdf');
  $self->rawformat('NDF');
  $self->format('NDF');

  # If arguments are supplied then we can configure the object
  # Currently the argument will be the filename.
  # If there are two args this becomes a prefix and number
  $self->configure(@_) if @_;

  return $self;
}

=back

=head2 Subclassed methods

The following methods are provided for manipulating
B<ORAC::Frame::SCUBA2> objects. These methods override those
provided by B<ORAC::Frame>.

=over 4

=item B<configure>

Configure the frame object. Usually called from the constructor.

Can be called either with a single filename or a reference to an
array of filenames

  $Frm->configure( \@files );
  $Frm->configure( $file );

=cut

sub configure {
  my $self = shift;

  my @fnames;
  if ( scalar( @_ ) == 1 ) {
    my $fnamesref = shift;
    @fnames = ( ref($fnamesref) ? @$fnamesref : $fnamesref );
  } elsif ( scalar( @_ ) == 2 ) {

    # SCUBA-2 configure() cannot take 2 arguments.
    croak "configure() for SCUBA-2 cannot take two arguments";

  } else {
    croak "Wrong number of arguments to configure: 1 or 2 args only";
  }

  # Set the raw files.
  $self->raw( @fnames );

  # Read the fits headers from all the raw files (since they should all have
  # .FITS)
  my %rfits;
  for my $f (@fnames) {
    my $fits;
    eval {
      $fits = new Astro::FITS::Header::NDF( File => $f );
      $fits->tiereturnsref(1);
    };
    if ($@) {
      # should not happen in real data but may happen in simulated
      # data
      $fits = new Astro::FITS::Header( Cards => []);
    }
    $rfits{$f}->{PRIMARY} = $fits;
  }

  # Set the filenames. Replace with processed images where appropriate
  my @paths;
  for my $f (@fnames) {
    my @internal = $self->_find_processed_images( $f );
    if (@internal) {

      push(@paths, @internal );
      # and read the FITS headers
      my @hdrs;
      for my $i (@internal) {

        my $fits;
        eval {
          $fits = new Astro::FITS::Header::NDF( File => $i );
          $fits->tiereturnsref(1);
        };
        if ($@) {
          # should not happen in real data but may happen in simulated
          # data
          $fits = new Astro::FITS::Header( Cards => []);
        }

        # Just store each one in turn. We can not index by a unique
        # name since I1 can be reused between files in the same frame
        push(@hdrs, $fits);
	
      }

      $rfits{$f}->{SECONDARY} = \@hdrs;

    } else {
      push(@paths, $f );
    }
  }

  # first thing we need to do is find which keys differ
  # between the .I1 and .IN processed images
  for my $f (keys %rfits) {

    # Rather than finding the unique keys of the primary and all the
    # secondary headers (Which may result in no headers that are
    # shared between primary and child) we first remove duplicate keys
    # from the child header and move them to the primary. In general
    # the secondary headers will either be completely unique keys
    # (otherwise they would be in the primary) or a complete copy
    # of the primary plus the unique keys.

    # in the former case, there will be no identical keys and so
    # nothing to merge into the PRIMARY header. In the latter, 95%
    # will probably be identical and that will probably be identical
    # to the bulk of the primary header.

    if (exists $rfits{$f}->{SECONDARY}) {
      # make sure we always return an entry in @different
      my ($secfirst, @secrest) = @{ $rfits{$f}->{SECONDARY} };
      my ($same, @different) = $secfirst->merge_primary( { force_return_diffs => 1},
                                                         @secrest );

      # differences should now be written to the SECONDARY array
      # since those are now the unique headers.
      $rfits{$f}->{SECONDARY} = \@different;

      # and merge the matching keys into the parent header
      # in this case, headers that are not present in either the child
      # or the primary header should be included in the merged header.
      my ($merged, $funique, $cunique) = $rfits{$f}->{PRIMARY}->merge_primary(
                                                                              {
                                                                               merge_unique => 1},
                                                                              $same );

      # Since we have merged unique keys into the primary header, anything
      # that is present in the "different" headers will be problematic since
      # it implies that we have headers that are present in both the .I
      # components and the primary header but that are identical between
      # the .I components yet different to the primary header. This is a 
      # problem and we need to issue a warning
      if (defined $funique || defined $cunique) {
        orac_warn("Headers are present in the primary FITS header of $f that clash with different values that are fixed amongst the processed components. This is not allowed.\n");
	
        orac_warn("Primary header:\n". $funique ."\n")
          if defined $funique;
        orac_warn("Component header:\n". $cunique ."\n")
          if defined $cunique;
      }

      # Now reset the PRIMARY header to be the merge
      $rfits{$f}->{PRIMARY} = $merged;
    }
  }

  # Now we need to merge the primary headers into a single
  # global header. We do not merge unique headers (there should not be
  # any anyway) as those should be pushed back down

  # merge in the original filename order
  my ($preference, @pheaders) = map { $rfits{$_}->{PRIMARY} } @fnames;
  my ($primary, @different) = $preference->merge_primary( @pheaders );

  # The leftovers have to be stored back into the subheaders
  # but we also need to extract subheaders
  my $stored_good;
  my @subhdrs;
  for my $i (0..$#fnames) {
    my $f = $fnames[$i];
    my $diff = $different[$i];

    if (exists $rfits{$f}->{SECONDARY}) {


      # merge with the child FITS headers if required
      if (defined $diff) {
        $stored_good = 1;

        # if a header in the difference already exists in the SECONDARY
        # component we just drop it on the floor and ignore it. This
        # can happen if multiple subscans are combined each of which
        # has a DATE-OBS from the .I1 which differs from .I2 .. .In
        # The DATE-OBS in the primary header will differ in each subscan
        # but the .In value is the important value. Similarly for airmass,
        # elevation start/end values.
        for my $sec (@{$rfits{$f}->{SECONDARY}}) {
          for my $di ($diff->allitems) {
            # see if the keyword is present
            my $keyword = $di->keyword;
            my $index = $sec->index($keyword);

            if (!defined $index) { # index can be 0
              # take a local copy so that we do not get action at a distance
              my $copy = $di->copy;
              $sec->insert( -1, $copy );
            }
          }
          push(@subhdrs, $sec);
        }

      } else {
        # just store what we have (which may be empty)
        for my $h (@{$rfits{$f}->{SECONDARY}}) {
          $stored_good = 1 if $h->sizeof > -1;
          push(@subhdrs, $h);
        }
      }

    } else {
      # we only had a primary header so this is only defined if we have
      # a difference
      if (defined $diff) {
        $stored_good = 1; # indicate that we have at least one valid subhdr
        push(@subhdrs, $diff);
      } else {
        # store blank header
        push(@subhdrs, new Astro::FITS::Header( Cards => []));
      }
    }

  }

  # do we really have a subhdr?
  if ($stored_good) {
    if (@subhdrs != @paths) {
      orac_err("Error forming sub-headers from FITS information. The number of subheaders does not equal the number of file paths (".
               scalar(@subhdrs) . " != " . scalar(@paths).")\n");
    }
    $_->tiereturnsref(1) for @subhdrs;
    $primary->subhdrs( @subhdrs );
  }

  # Now make sure that the header is populated
  $primary->tiereturnsref(1);
  $self->fits( $primary );
  $self->calc_orac_headers;

  # register these files
  for my $i (1..scalar(@paths) ) {
    $self->file($i, $paths[$i-1]);
  }

  # Find the group name and set it.
  $self->findgroup;

  # Find the recipe name.
  $self->findrecipe;

  # Find nsubs.
  $self->findnsubs;

  # Just return true.
  return 1;
}

=item B<data_detection_tasks>

Returns the names of the DRAMA tasks that should be queried for new
raw data.

  @tasks = $Frm->data_detection_tasks();

These tasks must be registered with the C<ORAC::Inst::Defn> module.

The task list can be overridden using the $ORAC_REMOTE_TASK
environment variable.

=cut

sub data_detection_tasks {
  my $self = shift;
  my @override = ORAC::Inst::Defn::orac_remote_task();
  return @override if @override;
  return ("QLSIM");
  my $pre = $self->_wavelength_prefix();
  my @codes = $self->_dacodes();

  # The task names will depend on the wavelength
  return map { "SCU2_$pre" . uc($_) } @codes;
}

=item B<file_from_bits>

Determine the raw data filename given the variable component
parts. A prefix (usually UT) and observation number should
be supplied.

  $fname = $Frm->file_from_bits($prefix, $obsnum);

Not implemented for SCUBA-2 because of the multiple files
that can be associated with a particular UT date and observation number:
the multiple sub-arrays (a to d) and the multiple subscans.

=cut

sub file_from_bits {
  my $self = shift;
  croak "file_from_bits Method not supported since the number of files per observation is not predictable.\n";
}

=item B<file_from_bits_extra>

Method to return C<extra> information to be used in the file name. For
SCUBA-2 this is a string representing the wavelength.

  my $extra = $Frm->file_from_bits_extra;

=cut

sub file_from_bits_extra {
  my $self = shift;

  return ( $self->hdr("FILTER") =~ /^8/ ) ? "850" : "450";
}

=item B<pattern_from_bits>

Determine the pattern for the raw filename given the variable component
parts. A prefix (usually UT) and observation number should be supplied.

  $pattern = $Frm->pattern_from_bits( $prefix, $obsnum );

Returns a regular expression object.

=cut

sub pattern_from_bits {
  my $self = shift;

  my $prefix = shift;
  my $obsnum = shift;

  my $padnum = $self->_padnum( $obsnum );

  my $letters = '['.$self->_dacodes.']';

  my $pattern = $self->rawfixedpart . $letters . '_'. $prefix . "_" . 
    $padnum . '_\d\d\d\d\d' . $self->rawsuffix;

  return qr/$pattern/;
}


=item B<number>

Method to return the number of the observation. The number is
determined by looking for a number after the UT date in the
filename. This method is subclassed for SCUBA-2 to deal with
SCUBA-2-specific filenames.

The return value is -1 if no number can be determined.

=cut

sub number {
  my $self = shift;
  my $number;

  my $raw = $self->raw;

  if ( defined( $raw ) ) {
    if ( ( $raw =~ /(\d+)_(\d{4})(\.\w+)?$/ ) ||
         ( $raw =~ /(\d+)\.ok$/ ) ) {
      # Drop leading zeroes.
      $number = $1 * 1;
    } else {
      $number = -1;
    }
  } else {
    # No match so set to -1.
    $number = -1;
  }
  return $number;
}

=item B<flag_from_bits>

Determine the flag filename given the variable component
parts. A prefix (usually UT) and observation number should
be supplied.

  @fnames = $Frm->file_from_bits($prefix, $obsnum);

Returns multiple file names (one for each array) and
throws an exception if called in a scalar context. The filename
returned will include the path relative to ORAC_DATA_IN, where
ORAC_DATA_IN is the directory containing the flag files.

The format is "swxYYYYMMDD_NNNNN.ok", where "w" is the wavelength
signifier ('8' for 850 or '4' for 450) and "x" a letter from
'a' to 'd'.

=cut

sub flag_from_bits {
  my $self = shift;

  my $prefix = shift;
  my $obsnum = shift;

  croak "flag_from_bits returns more than one flag file name and does not support scalar context (For debugging reasons)" unless wantarray;

  # pad with leading zeroes
  my $padnum = $self->_padnum( $obsnum );

  # get prefix
  my $fixed = $self->rawfixedpart();

  my @flags = map {
    $fixed . $_ . $prefix . "_$padnum" . ".ok"
  } ( $self->_dacodes );

  # SCUBA naming
  return @flags;
}

=item B<findgroup>

Return the group associated with the Frame. This group is constructed
from header information. The group name is automatically updated in
the object via the group() method.

=cut

# Supply a new method for finding a group

sub findgroup {

  my $self = shift;
  my $group;

  # Hash to store relevant parameters
  my %state;

  # Use value in header if present 
  if (exists $self->hdr->{DRGROUP} && $self->hdr->{DRGROUP} ne 'UNKNOWN'
      && $self->hdr->{DRGROUP} =~ /\w/) {
    $group = $self->hdr->{DRGROUP};
  } else {
    # Create our own DRGROUP string
    # Retrieve WCS
    my $wcs = $self->read_wcs( $self->file );
    my $domain = $wcs->Get("Domain");
    my $skyref = undef;
    if ( $domain =~ /SKY/ ) {
      $skyref = $wcs->Get("SkyRef");
    }

    # If we don't have a useful skyref at this point, re-create the
    # WCS from the FITS header
    if ( !defined $skyref && ($self->hdr('SAM_MODE') ne "SCAN") ) {
      my $fits = Astro::FITS::Header::NDF->new( File => $self->file );
      my @cards = $fits->cards;
      my $fchan = Starlink::AST::FitsChan->new();
      foreach my $c (@cards) {
        $fchan->PutFits("$c", 0);
      }
      $fchan->Clear("Card");
      $wcs = $fchan->Read();
      # The WCS may not be present in the FITS file
      if (defined $wcs) {
        $skyref = $wcs->Get("SkyRef");
      }
    }

    # If skyref is really not defined then the raw JCMTSTATE will have
    # to be accessed. Note that if an error occurs while attempting to
    # read the state structure, the pipeline will abort.
    if ( defined $skyref ) {
      $state{TCS_TR_SYS} = $wcs->Get("System");
      ($state{TCS_TR_BC1}, $state{TCS_TR_BC2}) = split( /,/, $skyref, 2);
      # Unformat SkyRef into radians - assumes RA is axis 1 and Dec is axis 2
      $state{TCS_TR_BC1} = $wcs->Unformat(1, $state{TCS_TR_BC1});
      $state{TCS_TR_BC2} = $wcs->Unformat(2, $state{TCS_TR_BC2});
    } else {
      # Read JCMTSTATE
      my $status = &NDF::SAI__OK;
      err_begin($status);
      # Open file with HDS
      hds_open( $self->file, "READ", my $loc, $status);
      dat_find( $loc, "MORE", my $mloc, $status);
      dat_find( $mloc, "JCMTSTATE", my $jloc, $status);
      dat_annul( $mloc, $status);

      # Get Tracking system, and RA/Dec of BASE posn
      for my $item (qw/ TCS_TR_SYS TCS_TR_BC1 TCS_TR_BC2 /) {
        dat_there( $jloc, $item, my $isthere, $status );
        if ($isthere) {
          dat_find($jloc, $item, my $sloc, $status );
          # Retrieve first value only - use an array slice
          my @subscript = ( 1 ); # Fortran
          dat_cell( $sloc, scalar(@subscript), @subscript, my $cloc, $status );
          dat_get0c( $cloc, my $value, $status );
          # Store in state hash
          $state{$item} = $value;
          dat_annul( $cloc, $status );
          dat_annul( $sloc, $status );
        }
      }
      # Tidy up
      dat_annul( $jloc, $status);
      dat_annul( $loc, $status);
      if ($status != &NDF::SAI__OK) {
        my $errstr = err_flush_to_string($status);
        orac_throw " Error reading JCMT state structure from input data: $errstr";
      } 
      err_end($status);
    }

    # Now construct DRGROUP string
    if ( $state{TCS_TR_SYS} =~ /APP/ ) {
      # Use object name if tracking in GAPPT
      $group = $self->hdr( "OBJECT" );
    } else {
      # Tracking RA and Dec are in radians - convert to HHMMSS+-DMMSS
      require Astro::Coords::Angle;
      my $ra = new Astro::Coords::Angle( $state{TCS_TR_BC1}, units => 'rad' );
      $ra->range("2PI");
      my $dec = new Astro::Coords::Angle( $state{TCS_TR_BC2}, units => 'rad' );
      $dec->range("PI");

      # Retrieve RA/Dec HH/DD, MM and SS as arrays, SS to nearest integer
      my @ra = $ra->components(0);
      my @dec = $dec->components(0);
      # Zero-pad the numbers
      foreach my $i ( @ra[1..3] ) {
        $i = sprintf "%02d", $i;
      }
      foreach my $i ( @dec[1..3] ) {
        $i = sprintf "%02d", $i;
      }
      # Construct RA/Dec string
      $group = join("",@ra[1..3],@dec);
    }
    $group .= $self->hdr( "SAM_MODE" ) .
      $self->hdr( "OBS_TYPE" ) .
        $self->hdr( "FILTER" ) ;
    # Add OBSNUM if we're not doing a science observation
    if ( uc( $self->hdr( "OBS_TYPE" ) ) ne 'SCIENCE' ) {
      $group .= sprintf "%05d", $self->hdrval( "OBSNUM" );
    }
  }
  # Update $group
  $self->group($group);

  return $group;
}


=item B<findnsubs>

Forces the object to determine the number of sub-frames
associated with the data by looking in the header (hdr()). 
The result is stored in the object using nsubs().

Unlike findgroup() this method will always search the header for
the current state.

=cut

sub findnsubs {
  my $self = shift;
  my @files = $self->raw;
  my $nsubs = scalar( @files );
  $self->nsubs( $nsubs );
  return $nsubs;
}


=item B<findrecipe>

Return the recipe associated with the frame.  The state of the object
is automatically updated via the recipe() method.

=cut

sub findrecipe {
  my $self = shift;

  my $recipe = undef;
  my $mode = $self->hdr('SAM_MODE');

  # Check for RECIPE. Have to make sure it contains something (anything)
  # other than UNKNOWN.
  if (exists $self->hdr->{RECIPE} && $self->hdr->{RECIPE} ne 'UNKNOWN'
      && $self->hdr->{RECIPE} =~ /\w/) {
    $recipe = $self->hdr->{RECIPE};
  } else {
    $recipe = 'QUICK_LOOK';
  }

  # Update the recipe
  $self->recipe($recipe);

  return $recipe;
}

=item B<numsubarrays>

Return the number of subarrays in use. Works by checking for unique
subheaders and determining which of the abcd sub-arrays are producing
data. Only works once data are read in so ORAC-DR must have some other
way of knowing that there are n subarrays.

=cut

sub numsubarrays {
  my $self = shift;

  my @subs = $self->_dacodes;

  return scalar (@subs);
}

=item B<hdrval>

Return the requested header entry, automatically dealing with
subheaders. Essentially overrides the standard hdr method for
retrieving a header value. Returns undef if no arguments are passed.

    $value = $Frm->hdrval( "KEYWORD" );
    $value = $Frm->hdrval( "KEYWORD", 0 );

both return the values from the first sub-header (index 0)
if the value is not present in the primary header.

=cut

sub hdrval {
  my $self = shift;

  if ( @_ ) {
    my $keyword = shift;
    # Set a default subheader index of 0, the first subheader
    my $subindex = @_ ? shift : 0;

    my $hdrval = ( defined $self->hdr->{SUBHEADERS}->[$subindex]->{$keyword}) ? 
      $self->hdr->{SUBHEADERS}->[$subindex]->{$keyword} : 
        $self->hdr("$keyword");

    return $hdrval;

  } else {
    # If no args, warn the user and return undef
    orac_warn "hdrval method requires at least a keyword argument\n";
    return;
  }

}

=item B<rewrite_outfile_subarray>

This method modifies the supplied filename to remove specific
subarray designation and replace it with a generic filter
designation.

Should be used when subarrays are merged into a single file.

If the s8a/s4a designation is missing the filename will be returned
unchanged.

  $outfile = $Frm->rewrite_outfile_subarray( $old_outfile );

=cut

sub rewrite_outfile_subarray {
  my $self = shift;
  my $old = shift;

  # see if we have a subarray designation
  my $new = $old;
  if ($old =~ /^s[48][abcd]/) {

    # filter information
    my $filt = $self->file_from_bits_extra;

    # we would expect the filter information to go after
    # the four digit subscan number
    $new =~ s/(_\d\d\d\d_)/$1${filt}_/;

    # remove the subarray designation
    $new =~ s/^s[48][abcd]/s/;

    # Get the suffix
    my ($bitsref, $suffix) = $self->_split_fname( $new );
    if (defined $suffix && length($suffix)) {
      # see if we have an output file
      my $root = $new;
      $root =~ s/\..*$//;
      if (!-e "$root.sdf") {
        # need to make the container
        # Create the new HDS container and name the root component after the
        # first 9 characters of the output filename
        my $status = &NDF::SAI__OK;
        err_begin($status);
        my @null = (0);
        hds_new ($root,substr($root,0,9),"ORACDR_HDS",
                 0,@null,my $loc,$status);
        dat_annul($loc, $status);
        err_end($status);
      }

    }

  }
  return $new;
}

=back

=begin __INTERNAL_METHODS

=head1 PRIVATE METHODS

=over 4

=item B<_padnum>

Pad an observation number.

 $padded = $frm->_padnum( $raw );

=cut

sub _padnum {
  my $self = shift;
  my $raw = shift;
  return sprintf( "%05d", $raw);
}

=item B<_wavelength_prefix>

Return the relevent wavelength code that will be used to specify the
particular set of data files. An '8' for 850 microns and a '4' for 450
microns.

 $pre = $frm->_wavelength_prefix();

=cut

sub _wavelength_prefix {
  my $self = shift;
  my $code;
  if ($ENV{ORAC_INSTRUMENT} =~ /_LONG/) {
    $code = '8';
  } else {
    $code = '4';
  }
  return $code;
}

=item B<_dacodes>

Return the relevant Data Acquisition computer codes. Always a-d.

  @codes = $frm->_dacodes();
  $codes = $frm->_dacodes();

In scalar context returns a single string with the values concatenated.

=cut

sub _dacodes {
  my $self = shift;
  #  my @letters = qw/ a b c d /;
  my @letters = qw/ a b /;
  return (wantarray ? @letters : join("",@letters) );
}

=item B<_find_processed_images>

Some SCUBA-2 data files include processed images (specifically, DREAM
and STARE) that should be used as the pipeline input images in preference
to the time series.

This method takes a single file and returns the HDS hierarchy to these
images within the main frame. Returns empty list if no reduced images
are present.

=cut

sub _find_processed_images {
  my $self = shift;
  my $file = shift;

  # begin error context
  my $status = &NDF::SAI__OK;
  err_begin( $status );

  # create the expected path to the container
  $file =~ s/\.sdf$//;
  my $path = $file . ".MORE.SCU2RED";

  # forget about using NDF to locate the extension, use HDS directly
  ($status, my @locs) = retrieve_locs( $path, 'READ', $status );

  # if status is bad, annul what we have and return empty list
  if ($status != &NDF::SAI__OK) {
    err_annul( $status );
    dat_annul( $_, $status ) for @locs;
    err_end( $status );
    return ();
  }

  # now count the components in this location
  dat_ncomp($locs[-1], my $ncomp, $status);

  my @images;
  if ($status == &NDF::SAI__OK) {
    for my $i ( 1..$ncomp ) {
      dat_index( $locs[-1], $i, my $iloc, $status );
      dat_name( $iloc, my $name, $status );
      push(@images, $path . "." . $name) if $name =~ /^I\d+$/;
      dat_annul( $iloc, $status );
    }
  }
  dat_annul( $_, $status ) for @locs;
  err_annul( $status ) if $status != &NDF::SAI__OK;
  err_end( $status );

  return @images;
}

=back

=end __INTERNAL_METHODS

=head1 SEE ALSO

L<ORAC::Frame>, L<ORAC::Frame::NDF>

=head1 REVISION

$Id$

=head1 AUTHORS

Tim Jenness (t.jenness@jach.hawaii.edu)

=head1 COPYRIGHT

Copyright (C) 1998-2005 Particle Physics and Astronomy Research
Council. All Rights Reserved.

This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 3 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful,but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
this program; if not, write to the Free Software Foundation, Inc., 59 Temple
Place,Suite 330, Boston, MA  02111-1307, USA

=cut

1;
