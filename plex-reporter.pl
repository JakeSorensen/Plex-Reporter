#!/usr/bin/perl -w
# Plex Reporter Script - stu@lifeofstu.com
# Licensed under the Simplified BSD License, 2011
# Copyright 2012, Stuart Hopkins
# Version 0.5

use strict;
use Data::Dumper;
use File::Basename;
use MIME::Lite;
use LWP;
use POSIX qw(strftime);
use Socket;
use XML::Simple;

## Put the IP and Port of your Plex server here
my $plex_server = '127.0.0.1';
my $plex_port   = '32400';
## Put the locations of your Plex logfiles here
## TIP: Use the older log first so its in date order
my @plex_logfiles = ( '/var/lib/plexmediaserver/Library/Application Support' .
                      '/Plex Media Server/Logs/Plex Media Server.old.log',
                      '/var/lib/plexmediaserver/Library/Application Support' .
                      '/Plex Media Server/Logs/Plex Media Server.log' );

## If you want to look up the hostnames of the clients, set to 1
my $plex_dnslookup = 1;
## If you want to be warned about missing media files, set to 1
my $warn_missing = 0;

## If you dont want to send an email, set one of the below to a blank string
## Put the IP of your email relay here
my $email_server = '';
## Username/Password for email relay (leave blank if not required)
my $email_username = '';
my $email_password = '';
## Put the sending email address here
my $email_sender = '';
## Put your email recipient here
my $email_receiver = '';

###################################
## TOUCH NOTHING BELOW THIS LINE ##
###################################

## Subroutines
sub plex_die(){
  # Print an error message then exit with error code 1
  print "ERROR: $_[0]\n";
  exit 1;
}

sub plex_showHelp(){
  # Show the help screen and then exit
  print <<EOF
Usage
-----

./plex-reporter.pl 		             - Will give you todays report
./plex-reporter.pl -d "Jan 02, 2012"         - Will give you the report for specified date
./plex-reporter.pl -d "Jan [0-9][0-9], 2012" - Will give you the report for January 2012
./plex-reporter.pl -h                        - This screen

Ensure you have customised (edited) the script before running.

EOF
}

## Variables
my $curdate = sprintf("%s %02i, %i",
        (strftime "%b", gmtime),
        (strftime "%e", gmtime),
        (strftime "%Y", gmtime));
my $email;
my $email_client_text = "";
my $email_subject = "";
my $email_text = "";
my %plex_clients;

###########################
## MAIN CODE STARTS HERE ##
###########################

print "Plex Reporter Script - Version 0.5\n";

# Sanity check
length($plex_server)  || 
  &plex_die("The plex_server variable is empty, edit this script");
length($plex_port)    ||
  &plex_die("The plex_port variable is empty, edit this script");
scalar(@plex_logfiles) ||
  &plex_die("The plex_logfile variable is empty, edit this script");

# LWP object for later
my $obj_lwp = new LWP::UserAgent ||
  &plex_die("Failed to create LWP object");

# XML object for later
my $obj_xml = new XML::Simple ||
  &plex_die("Failed to create XML object");

# Check for any passed arguments
while ($ARGV[0]) {
  if ( $ARGV[0] eq "-d" || $ARGV[0] eq "--date" ) {
    # Custom date should be passed, and should be the next argument
    if ( ! $ARGV[1] ) {
      &plex_die("You passed the -d/--date option without specifying a date after");
    }
    $curdate = $ARGV[1];
    shift;
  } elsif ( $ARGV[0] eq "-h" || $ARGV[0] eq "--help" ) {
    # Print the help information
    &plex_showHelp;
    exit 0;
  } else {
    # Invalid option
    print "ERROR: Invalid option specified: " . $ARGV[0] . "\n\n";
    &plex_showHelp;
    exit 1;
  }
  shift;
}

# Print the date that is being used for the reporting
print "- Using date: $curdate\n";

# Loop through each logfile and pull in any relevant lines
foreach my $plex_lf ( @plex_logfiles ) {
  # Check the logfile exists
  if ( -f "$plex_lf" ) {
    print "- Reading logfile: $plex_lf\n";
    # Open and read the logfile line by line
    open(PLEX_LOG, $plex_lf) ||
      &plex_die("Failed to open logfile for reading: $plex_lf");
    foreach my $log_line (<PLEX_LOG>) {
      # Remove any newline character
      chomp($log_line);
      if ( $log_line !~ /$curdate.+progress\?key.+state=playing/i &&
           $log_line !~ /$curdate.+progress\?X-Plex-Token=.+state=playing/i ) {
        # Not interested, wrong type of log line
        next;
      }
      # Right type of line, grab the Date, Media Key, IP address
      my $tmp_line = $log_line;
      $tmp_line =~ s/^([a-z]+\ [0-9]+,\ [0-9]+).+[\?\&]key=([0-9]+).+\[([0-9\.]+)\].+$/$1|$2|$3/i;
      my ($tmp_date, $tmp_key, $tmp_ip) = split(/\|/, $tmp_line);
      chomp($tmp_date);
      chomp($tmp_key);
      chomp($tmp_ip);
      ( length($tmp_date) && length($tmp_key) && length($tmp_ip) ) ||
        &plex_die("Failed to retrieve required variables from line: $log_line");
      # Add the details to the client list
      $plex_clients{$tmp_ip}->{$tmp_date} = $tmp_key;
    }
    # Close the file handle
    close(PLEX_LOG);
  }
}
print "\n";

# Check if any clients connected
if ( ! keys(%plex_clients) ) {
  print "No clients connected to your plex server on '$curdate'\n";
} else {
  printf "%i client(s) connected to your plex server on '$curdate'\n", scalar(keys %plex_clients);
}

# For each client, loop through their viewings
# Note, if we have zero clients, all of this is skipped
foreach my $plex_client (sort keys %plex_clients) {
  my $tmp_emailtxt = "";
  my $tmp_clientname;
  # Attempt to lookup the hostname of the client (if enabled)
  if ( $plex_dnslookup ) {
    $tmp_clientname = gethostbyaddr(inet_aton("$plex_client"), AF_INET) || ($tmp_clientname = "Unknown");
  } else {
    $tmp_clientname = "Lookup disabled";
  }
  print "\nExamining activity for client: $plex_client ($tmp_clientname)\n";
  $tmp_emailtxt .= "Activity for client: $plex_client ($tmp_clientname)\n";
  # Loop through each of the date entries (in case we found multiple)
  foreach my $plex_date ( keys %{$plex_clients{$plex_client}} ) {
    printf "  - %i video file(s) have been accessed on '%s' by this client\n",
      scalar(keys %{$plex_clients{$plex_client}}), $plex_date;
    $tmp_emailtxt .= "  - " . scalar(keys %{$plex_clients{$plex_client}}) . " file(s) have been accessed on '$plex_date' by this client\n";
    # Loop through each of the plex items for this date
    foreach my $plex_item ( $plex_clients{$plex_client}->{$plex_date} ) {
      my $vid_fname;
      my $tmp_fkeyname;
      # Lookup the video file details
      my $vid_raw = $obj_lwp->get("http://$plex_server:$plex_port/library/metadata/$plex_item") ||
        &plex_die("Failed to retrieve metadata for item: $plex_item");
      my $vid_xml = $obj_xml->XMLin($vid_raw->content) ||
        &plex_die("Failed to import metadata for item: $plex_item\n" . $vid_raw->content);
      if ( $vid_xml->{Video}->{Media}->{Part}->{file} ) {
        # Simple XML entry, read the actual filename
        $vid_fname = basename($vid_xml->{Video}->{Media}->{Part}->{file}) ||
          &plex_die("Failed to calculate basename from file: " .
                  $vid_xml->{Video}->{Media}->{Part}->{file});
        # Check that the file actually exists,dd if not, warn
        if ( ! -e $vid_xml->{Video}->{Media}->{Part}->{file} ) {
          # File wasn't found on 
          ( $warn_missing ) && print "WARN: File '" . $vid_xml->{Video}->{Media}->{Part}->{file} .
                "' was not found on the system\n";
        }
      } else {
        # There might be more than one Media entry for this movie/show, check
        # if the file actually exists
        # NOTE: This comes into practice where you replace files (avi to mkv)
        my $tmp_fkeyname;
        foreach my $tmp_keyname (keys %{$vid_xml->{Video}->{Media}}) {
          # NOTE: Regex here as for some reason we sometimes get
          #       the part tag come through as well
          if ( $tmp_keyname =~ /^[0-9]+$/ ) {
            # Store the first key name just in case no files are present
            if ( ! $tmp_fkeyname ) {
              $tmp_fkeyname = $tmp_keyname;
            }
            # Valid metadata entry, check if the file exists
            if ( -e $vid_xml->{Video}->{Media}->{$tmp_keyname}->{Part}->{file} ) {
              $vid_fname = $vid_xml->{Video}->{Media}->{$tmp_keyname}->{Part}->{file};
            }
          }
        }
        # At this point, we should have the filename for the watched item
        # If not, it was a multi-entry and all files were missing
        if ( ! $vid_fname ) {
          ( $warn_missing ) && print "WARN: None of the files for entry $plex_item were found\n";
          $vid_fname = $vid_xml->{Video}->{Media}->{$tmp_fkeyname}->{Part}->{file};
        }
        # Shorten the filename
        $vid_fname = basename($vid_fname) ||
          &plex_die("Failed to calculate basename from file: " . $vid_fname);;
      } 

      # Print the filename to the screen
      printf "    %s\n", $vid_fname;
      # Add the details to the temp email text
      $tmp_emailtxt .= "    $vid_fname\n";
    }

    # Add this clients info the global email string
    $email_client_text .= "\n\n$tmp_emailtxt";
  }
}

# Construct the daily email
$email_subject = "Plex daily report - " . gmtime;
$email_text = "Report for Plex server: $plex_server - " . $curdate . "\n";
$email_text .= scalar(keys %plex_clients) . " client(s) accessed your server on the specified date\n";
$email_text .= $email_client_text;
$email_text .= "\n\nThat concludes this report.";

# Send the email out
if ( length($email_server) && length($email_receiver) && length($email_sender) ) {
  print "\nSending email to: $email_receiver\n";
  my $email = MIME::Lite->new(
    From     => $email_sender,
    To       => $email_receiver,
    Subject  => $email_subject,
    Data     => $email_text
  );
  if ( length($email_username) && length($email_password) ) {
    $email->send('smtp', $email_server, AuthUser=>$email_username, 
      AuthPass=>$email_password) || &plex_die("Failed to send email");
  } else {
    $email->send('smtp', $email_server) || &plex_die("Failed to send email");
  }
  print "Email sent successfully\n";
}

# All done
exit 0;
