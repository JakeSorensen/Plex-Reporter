#!/usr/bin/perl -w
# Plex Reporter Script - stu@lifeofstu.com
# Licensed under the Simplified BSD License, 2011
# Copyright 2011, Stuart Hopkins
# Version 0.1

use strict;
use File::Basename;
use MIME::Lite;
use POSIX qw(strftime);
use Socket;
use XML::Simple;

## Put the IP of your Plex server here
my $plex_server = '';
## Put the location of your Plex logfile here
my $plex_logfile = '/var/lib/plexmediaserver/Library/Application\ Support/Plex\ Media\ Server/Logs/Plex\ Media\ Server.log';
## Put the IP of your email relay here
my $email_server = '';
## Put the sending email address here
my $email_sender = '';
## Put your email recipient here
my $email_receiver = '';

###################################
## TOUCH NOTHING BELOW THIS LINE ##
###################################

# Start
print 'Plex Reporter Script' . "\n";
print "Version 0.1\n\n";

# XML object for later
my $obj_xml = new XML::Simple;

# Email empties
my $email;
my $email_client_text = "";
my $email_subject = "";
my $email_text = "";

# Create string of current date to grep for (daily reporting)
my $curdate = strftime "%b %e, %Y", gmtime;

# Fetch all of the IP addresses that have connected to the server
my @plex_clients = `cat $plex_logfile | grep '^$curdate ' | grep 'progress?key' | sed -e 's/^.*\\[.*\\].*\\[\\(.*\\)\\].*/\\1/g' | sort | uniq`;

if ( @plex_clients eq 0 ) {
  # No clients connected
  print "No clients connected to your plex server today\n";
} else {
  printf "%i client(s) connected to your plex server today\n", scalar(@plex_clients);
}

# For each IP, grep the log to find out what has been watched
# Note, if we have zero clients, all of this is skipped
foreach my $plex_client (@plex_clients) {
  my $tmp_emailtxt = "";
  chomp($plex_client);
  # Attempt to lookup the hostname of the client
  my $plex_clientname;
  $plex_clientname = gethostbyaddr(inet_aton("$plex_client"), AF_INET) || ($plex_clientname = "Unknown");
  print "\nExamining activity for client: $plex_client ($plex_clientname)\n";
  $tmp_emailtxt .= "Activity for client: $plex_client ($plex_clientname)\n";
  my @client_viewed = `cat $plex_logfile | grep '^$curdate ' | grep '\\[$plex_client\\]' | grep 'progress?key' | sed -e 's/^\\(.*,\\ [0-9][0-9][0-9][0-9]\\)\\ .*\\[.*\\]\\ DEBUG\\ -\\ Request:\\ GET\\ \\/:\\/progress?key=\\([0-9][0-9]*\\).*/\\2/g' | uniq`;
  if ( @client_viewed eq 0 ) {
    # Shouldnt happen as we detected activity earlier, regex error
    die("Regex error: Could not determine activity for client $plex_client");
  }
  printf "  - %i video file(s) have been accessed today by this client\n", scalar(@client_viewed);
  $tmp_emailtxt .= "  - " . scalar(@client_viewed) . " file(s) have been accessed today by this client\n";
  # Loop through each accessed item and retrieve the details
  foreach my $plex_item (@client_viewed) {
    chomp($plex_item);
    #print "    - $plex_item\n";
    # Lookup the video file details
    my $vid_raw = `curl -s http://$plex_server:32400/library/metadata/$plex_item`;
    my $vid_xml = $obj_xml->XMLin($vid_raw);
    my $vid_fname = basename($vid_xml->{Video}->{Media}->{Part}->{file});
    printf "    %s\n", $vid_fname;
    # Add the details to the temp email text
    $tmp_emailtxt .= "    $vid_fname\n";
  }

  # Add this clients info the global email string
  $email_client_text .= "\n\n$tmp_emailtxt";
}

# Construct the daily email
$email_subject = "Plex daily report - " . gmtime;
$email_text = "Daily report for Plex server: $plex_server - " . gmtime . "\n";
$email_text .= scalar(@plex_clients) . " client(s) accessed your server today\n";
$email_text .= $email_client_text;
$email_text .= "\n\nThat concludes todays report.";

# Send the email out
if ( $email_server ne "" && $email_receiver ne "" ) {
  print "\nSending email to: $email_receiver\n";
  my $email = MIME::Lite->new(
    From     =>$email_sender,
    To       =>$email_receiver,
    Subject  =>$email_subject,
    Data     =>$email_text
  );
  $email->send || die("Failed to send email");
  print "Email sent successfully\n";
}

# All done
exit 0;
