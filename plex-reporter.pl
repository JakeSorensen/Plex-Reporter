#!/usr/bin/perl -w
# Plex Reporter Script - stu@lifeofstu.com
# Licensed under the Simplified BSD License, 2011
# Copyright 2011, Stuart Hopkins
# Version 0.4

use strict;
use File::Basename;
use MIME::Lite;
use LWP;
use POSIX qw(strftime);
use Socket;
use XML::Simple;

## Put the IP and Port of your Plex server here
my $plex_server = '127.0.0.1';
my $plex_port   = '32400';
## Put the location of your Plex logfile here
my $plex_logfile = '/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Logs/Plex Media Server.log';

## If you want to look up the hostnames of the clients, set to 1
my $plex_dnslookup = 1;

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

./plex-reporter.pl 		         - Will give you todays report
./plex-reporter.pl -d "Jan 02,2011"      - Will give you the report for that date
./plex-reporter.pl -h                    - This screen

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

###########################
## MAIN CODE STARTS HERE ##
###########################

print "Plex Reporter Script - Version 0.4\n";

# Sanity check
length($plex_server)  || 
  &plex_die("The plex_server variable is empty, edit this script");
length($plex_port)    ||
  &plex_die("The plex_port variable is empty, edit this script");
length($plex_logfile) ||
  &plex_die("The plex_logfile variable is empty, edit this script");
(-e $plex_logfile)    || 
  &plex_die("The specified plex logfile was not found");

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
print "- Using date: $curdate\n\n";

# Fetch all of the IP addresses that have connected to the server
my @plex_clients = `grep '^$curdate ' "$plex_logfile" | grep 'progress?key' | sed -e 's/^.*\\[.*\\].*\\[\\(.*\\)\\].*/\\1/g' | sort | uniq`;

if ( @plex_clients eq 0 ) {
  # No clients connected
  print "No clients connected to your plex server on $curdate\n";
} else {
  printf "%i client(s) connected to your plex server on $curdate\n", scalar(@plex_clients);
}

# For each IP, grep the log to find out what has been watched
# Note, if we have zero clients, all of this is skipped
foreach my $plex_client (@plex_clients) {
  my $tmp_emailtxt = "";
  chomp($plex_client);
  # Attempt to lookup the hostname of the client
  my $plex_clientname;
  if ( $plex_dnslookup ) {
    $plex_clientname = gethostbyaddr(inet_aton("$plex_client"), AF_INET) || ($plex_clientname = "Unknown");
  } else {
    $plex_clientname = "Lookup disabled";
  }
  print "\nExamining activity for client: $plex_client ($plex_clientname)\n";
  $tmp_emailtxt .= "Activity for client: $plex_client ($plex_clientname)\n";
  # Grep through the logfile to find any activity
  my @client_viewed = `grep '^$curdate ' "$plex_logfile" | grep '\\[$plex_client\\]' | grep 'progress?key' | sed -e 's/^\\(.*,\\ [0-9][0-9][0-9][0-9]\\)\\ .*\\[.*\\]\\ DEBUG\\ -\\ Request:\\ GET\\ \\/:\\/progress?key=\\([0-9][0-9]*\\).*/\\2/g' | uniq`;
  if ( @client_viewed eq 0 ) {
    # Shouldnt happen as we detected activity earlier, regex error
    &plex_die("Regex error: Could not determine activity for client $plex_client");
  }
  printf "  - %i video file(s) have been accessed on $curdate by this client\n", scalar(@client_viewed);
  $tmp_emailtxt .= "  - " . scalar(@client_viewed) . " file(s) have been accessed on $curdate by this client\n";

  # Loop through each accessed item and retrieve the details
  foreach my $plex_item (@client_viewed) {
    chomp($plex_item);
    my $vid_fname;
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
      # Check that the file actually exists, if not, warn
      if ( ! -e $vid_xml->{Video}->{Media}->{Part}->{file} ) {
        print "WARN: File '" . $vid_xml->{Video}->{Media}->{Part}->{file} .
              "' was not found on the system\n";
      }
    } else {
      # There might be more than one Media entry for this movie/show, check
      # if the file actually exists
      # NOTE: This comes into practice where you replace files (avi to mkv)
      foreach my $tmp_keyname (keys %{$vid_xml->{Video}->{Media}}) {
        # NOTE: Regex here as for some reason we sometimes get
        #       the part tag come through as well
        if ( $tmp_keyname =~ /^[0-9]+$/ ) {
          # Valid metadata entry, check if the file exists
          if ( -e $vid_xml->{Video}->{Media}->{$tmp_keyname}->{Part}->{file} ) {
            $vid_fname = $vid_xml->{Video}->{Media}->{$tmp_keyname}->{Part}->{file};
          }
        }
      }
      # At this point, we should have the filename for the watched item
      # If not, something went very wrong
      if ( ! $vid_fname ) {
        &plex_die("Failed to read filename from XML:\n" . $vid_raw->content);
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

# Construct the daily email
$email_subject = "Plex daily report - " . gmtime;
$email_text = "Report for Plex server: $plex_server - " . $curdate . "\n";
$email_text .= scalar(@plex_clients) . " client(s) accessed your server on the specified date\n";
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
