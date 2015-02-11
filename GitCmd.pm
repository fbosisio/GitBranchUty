package GitCmd;

#------------------------------------------------------------------------------

my $git_id = q$Id$;

#------------------------------------------------------------------------------

use strict;
use Carp;
#use version (); our $VERSION = version->declare("v1.0");
our $VERSION = "1.0";

#------------------------------------------------------------------------------

use constant TRUE  => (1 == 1);
use constant FALSE => (! TRUE);

#------------------------------------------------------------------------------

our $AUTOLOAD;

my $git_executable;
BEGIN {
  # On a UNIX-like system, this should improve execution time of the various
  # subsequent git commands, since the path for "git" executable is cached.
  chomp( $git_executable = `which git` );
  $git_executable = 'git' if ( $git_executable !~ m!^/! );
}

#------------------------------------------------------------------------------

sub new {
  my( $this, %options ) = @_;
  my $class = ref($this) || $this;
  my $self = { verbose        => 0,
               stopOnErrors   => TRUE,
               chompScalars   => TRUE,
               printOnly      => FALSE,
               _lastCmdFailed => FALSE,
               _openHandles   => {} };

  if ( $class ne $this ) {
    # Called on an object (not a class): clone option attributes
    my @valid_opts = grep { !/^_/ } keys %{$self};
    foreach my $opt (@valid_opts) {
      $self->{$opt} = $this->{$opt};
    }
  }

  &Options( $self, %options ) if ( %options );

  bless( $self, $class );
}

#------------------------------------------------------------------------------

sub Options {
  my( $self, %options ) = @_;
  my %valid_opts = map { $_ => TRUE } grep { !/^_/ } keys %{$self};
  my %prev_values = ();

  foreach my $opt (keys %options) {
    if ( exists($valid_opts{$opt}) ) {
      $prev_values{$opt} = $self->{$opt};
      $self->{$opt} = $options{$opt};
    } else {
      &croak( "Invalid option '$opt' for Options() method in " . ref($self) .
              " package !\n" );
    }
  } # END foreach

  # The 'printOnly' option implies the 'verbose' one
  $self->{verbose} = 1 if ( $self->{printOnly} && ($self->{verbose} <= 0) );

  # Evaluate the proper return-value, if requested
  if ( defined wantarray ) { # Non-void context
    if ( wantarray ) { # List (i.e. hash) context
      %prev_values
    } else { # Scalar context
      my @k = keys %prev_values;
      # If a single option given, return its value; otherwise use an hash-ref
      ( ($#k == 0) ? $prev_values{$k[0]} : \%prev_values );
    }
  }
}

#------------------------------------------------------------------------------

sub KO {
  my( $self ) = @_;

  $self->{_lastCmdFailed}; # Return value
}

#------------------------------------------------------------------------------

# This is intended for sub-classes only
sub ReturnListOrString {
  my( $self, $array_ref ) = @_;

  return @{$array_ref} if ( wantarray ); # Return list

  my $str = join( '', @{$array_ref} );
  chomp( $str ) if ( $self->{chompScalars} );
  $str; # Return string
}

#------------------------------------------------------------------------------

# N.B.: local (anonymous) function
my $OpenFailed = sub {
  my( $self, $git_cmd ) = @_;

  &croak( "Can't execute 'git $git_cmd': $!\n" ) if ( $self->{stopOnErrors} );
  $self->{_lastCmdFailed} = TRUE;
};

#------------------------------------------------------------------------------

# N.B.: local (anonymous) function
my $CloseFailed = sub {
  my( $self, $git_cmd ) = @_;

  if ( $self->{stopOnErrors} ) {
    my $msg = ( $! ? "Failure in 'git $git_cmd': $!" :
                     "Exit code from 'git $git_cmd' is $?" );

    &croak( "$msg\n" );
  }
  $self->{_lastCmdFailed} = TRUE;
};

#------------------------------------------------------------------------------
# Execute the given git-command and place its standard output either on STDOUT,
# on a list (one elem per line), on a single string (concatenating all lines) or
# in a given file-handle (to be processed by the caller).
#-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub Run {
  my( $self, $command, @args ) = @_;

  my $fh = undef;
  if ( ( $#args >= 0 ) && UNIVERSAL::isa($args[0],'IO::Handle') ) {
    $fh = shift @args;
  }

  my $cmd = $command . ' ' . join(' ',@args);
  $cmd =~ s/\s+$//;
  print STDERR '[',ref($self),"] About to run \"git $cmd\" ...\n" if ( $self->{verbose} > 0 );
  # If 'printOnly' option is set, use a "do-nothing" command
  $cmd = 'log -0' if ( $self->{printOnly} );
  $cmd = "$git_executable --no-pager $cmd";

  $self->{_lastCmdFailed} = FALSE; # Reset state

  if ( defined($fh) ) { # File-handle provided: just "open" the command
    open( $fh, "$cmd |" ) or $self->$OpenFailed( $command );
    $self->{_openHandles}->{$fh} = $command;
  } elsif ( ! defined wantarray ) { # Void context: leave output on STDOUT
    system( $cmd ) == 0 or $self->$OpenFailed( $command );
  } else { # Scalar or list context: run command and save output
    local *GIT_CMD;
    my @output = ();
    open( GIT_CMD, "$cmd |" ) or do { $self->$OpenFailed( $command ); return };
      while ( my $line = <GIT_CMD> ) {
        push( @output, $line );
      }
    close( GIT_CMD ) or $self->$CloseFailed( $command );

    $self->ReturnListOrString( \@output ); # Return list or string as required
  }
}

#------------------------------------------------------------------------------

sub Close {
  my( $self, $fh ) = @_;

  my $command = delete $self->{_openHandles}->{$fh} || '';
  $fh->close or $self->$CloseFailed( $command );
}

#------------------------------------------------------------------------------
# Auto-magically implement (on-the-fly) any call to an undefined method.
# In this way, the following two shell commands are exactly equivalent:
#   - git COMMAND ARGUMENTS
#   - perl -MGitCmd -e '$git=new GitCmd; $git->COMMAND(ARGUMENTS);'
# no matter what "COMMAND" is (built-in, add-on, alias or invalid name).
# Notice also that dashes (-) are replaced by underscores (_) inside "COMMAND".
#-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub AUTOLOAD {
  # Remove package from name
  my $name = $AUTOLOAD;
  $name =~ s/^.*:://;
  # Replace underscores with dashes
  $name =~ s/_/-/g;

  # Define the function (simply forward the call to the "Run" method)
  my $method = sub { my $self = shift; $self->Run($name,@_); };

  { #- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    # Turn off "strict references" to enable "magic" AUTOLOAD speedup
    no strict 'refs';

    # Install the function definition in the symbol table
    *{$AUTOLOAD} = $method;

    # Turn "strict references" back on
    use strict 'refs';
  } #- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  # Invoke the function
  goto &$method;
}

#------------------------------------------------------------------------------

# Provide a DESTROY method, to avoid AUTOLOADING it too
sub DESTROY {}

#------------------------------------------------------------------------------

# Module return code
1;

__END__


=head1 NAME

GitCmd - Perl Object Class for GIT commands.

=head1 SYNOPSIS

use GitCmd;

=head1 DESCRIPTION

This Perl module provides an object oriented interface to access B<GIT>
commands. GIT must be installed on the system in order to use this module.
This module should simplify invoking GIT commands from perl, performing
error-checking and allowing to (easily) either capture the command output
or to leave it go to STDOUT. We used capitalized names for intenal commands,
leaving all-lowercase names for git-commands (since they are normally
written this way).

=head1 METHODS

The module provides some explicit methods (namely B<new>, B<Option>, B<KO>,
B<ReturnListOrString>, B<Run> and B<Close>) plus an B<AUTOLOAD> facility so
that I<every> GIT command can be used as a method (just with dashes converted
to undercores in the name, to cope with perl syntax). In other words, the
following perl snippet:

   use GitCmd;
   my $git = new GitCmd;
   $git->COMMAND( ARGUMENTS );

is exactly equivalent to this shell command

   git COMMAND ARGUMENTS

no matter what "COMMAND" is (a git built-in, an add-on command or an alias). Of
course, the execution time may differ.

=head2 OBJECT CONSTRUCTOR

The B<new> method may be used as either a class method or an object method to
create a new object.

    # called as class method
    my $git = new GitGmd;

    # called as object method
    my $git2 = $git->new;

You can pass options to the constructor (this is exactly the same as calling
the B<Option()> method after creating the object):

    # explicitly set the same values that are used by default
    my $git = new GitGmd( verbose      => 0,
                          stopOnErrors => 1,
                          chompScalars => 1 );

    # calling object method is useful exactly to change some option
    my $git2 = $git->new( stopOnErrors => 0 );

=head2 CHANGING OPTIONS

The B<Options> method can be used to change various options after the object
was constructed. Valid options are:

    verbose      (default false): print git command before execution
    stopOnErrors (default true) : croak if a GIT command fails
    chompScalars (default true) : chomp output when stored in a scalar

For example:

    my $git = new GitGmd;               # stopOnErrors is TRUE here
    $git->log();                        # throw exception on failure
    $git->Options( stopOnErrors => 0 ); # stopOnErrors is FALSE now
    $git->status();                     # no exception will be thrown

=head2 CHECKING RETURN CODE

The B<KO> method can be used to test the result of last executed GIT command,
when the I<stopOnErrors> option is set to I<false>.

    my $git = new GitGmd( stopOnErrors => 0 ); # turn-off default
    $git->status();                            # no exception can occurr
    if ( $git->KO ) { ... }                    # handle error, if any

=head2 EXECUTING A COMMAND

The B<Run> method is the core function in this module, even if it is not
intended to be used directly: its purpuose is to allow the implementation of
I<any> GIT command, through the AUTOLOAD method (see L<below|AUTOLOAD>).

The method can be used for different purpouses, depending on how it is invoked:

=over

=item *

If called in "void" context (i.e. without assigning return val), the given
git-command will simply be executed and its output will go to STDOUT:

    $git->Run( 'git_command' [, args] );

=item *

If the return value is assigned to a list, the output of the given git-command
will be saved in a list (each line goes into a different list element):

    my @output = $git->Run( 'git_command' [, args] );

=item *

If the return value is a scalar, the output of given git-command will be placed
in a string, i.e. all lines will be concateneted together (the last newline will
be removed if the I<chompScalars> option is set, which is the default):

    my $output = $git->Run( 'git_command' [, args] );

=item *

If the second agrument (i.e. the one right after the git-command name) is an
"IO::Handle" object (or a sub-class of it), then the output of the given
git-command will go to this file-handle, so that the caller can deal with it
directly (no return value is foreseen in this case from C<Run>, which shall
in fact be called in "void" contest). The B<Close()> method
(see L<below|CLOSING FILES>) shall be invoked on the file-handle when output
parsing is done.

    my $file_handle = new IO::Handle;
    $git->Run( 'git_command', $file_handle [, args] );
       [...]  # Read the file-handle as needed
    $git->Close( $file_handle );  # Close file and check errors

=back

=head2 CLOSING FILES

The B<Close> method is used to close a file-descriptor given as second argument
to I<Run> (or as first argument to any method mapping a git command via the
autoload facility). Besides closing the given file descriptor, the return-code
for the underlying git-command is checked and, in case of errors, either
I<croak> is called or it is stored for subsequent inspection by the I<KO>
method (depending on the I<stopOnErrors> option).

    my $io_handle = new IO::Handle;
    $git->log( $io_handle, '-1' );
       [...]  # Parse output of 'git log -1'
    $git->Close( $io_handle );

Multiple open commands at the same time are supported: this is why you need to
pass the file-handle again to this method.

TODO: as a special case, we could accept a call to Close with no args, if
just one file-handle is currently opened

=head2 AUTOLOAD

The AUTOLOAD method converts any call to an unknown method into a call to the
B<Run> method with the unknown method name as first argument (all the other
arguments are passed unchanged after it). The only performed manipulation is
a replacement of underscores ('_') with dashes ('-') in the command name before
passing it to Run: this is because dashes are not valid in perl identifiers
but git commands use them.

In other words, any call to "GitCmd::xy_zt( 'a', 'b' )" is mapped into a call
to "GitCmd::Run( 'xy-zt', 'a', 'b' )", which ends up in calling "git xy-zt a b".
The same rules for the I<Run> command applies for output parsing, depending on
whether there is a return-value or not, on its type (scalar or list context)
and maybe the usage of an "IO::Handle" object as first argument.

=over

=item *

In "void" context the output will go to STDOUT:

    $git->status;

=item *

In list context, the output will be saved in the list, one element per line:

    my @remote_urls = $git->remote( '-v' );

=item *

In scalar context all output lines will be concateneted together (and last
newline will be removed if the I<chompScalars> is set):

    my $repo_root = $git->rev_parse( '--show-toplevel' );

=item *

If first agrument is an "IO::Handle" object (or a sub-class) the output
will go to this file-handle and the caller can deal with it:

    my $fh = new IO::Handle;
    $git->log( $fh, '--pretty=format:%s%b' );
    while ( my $line = <$fh> ) {
	  print $line if ( $line =~ /$regex/ );
    }
    $git->Close( $fh );

=back
 
=head2 OBJECT DESTRUCTOR

The B<DESTROY> method actually does nothing, but is anyway implemented in order
to avoid AUTOLOADing it.

=head1 AUTHOR

F. Bosisio, <fbosisio@bigfoot.com>

=head1 COPYRIGHT

Copyright (C) 2013 F. Bosisio. All rights reserved. This program is free
software: you can redistribute it and/or modify it under the same terms as
Perl itself.

=cut
