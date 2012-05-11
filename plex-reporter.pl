#!/usr/bin/env perl
# Plex Reporter Script - stu@lifeofstu.com
# Licensed under the Simplified BSD License, 2011
# Copyright 2012, Stuart Hopkins
# Version 1.0a

use strict;
use warnings;
use Data::Dumper;
use Date::Calc qw(check_date Decode_Month Delta_Days English_Ordinal Month_to_Text);
use DateTime;
use File::Basename;
use IO::Socket;
use LWP;
use MIME::Lite;
use POSIX qw(strftime);
use XML::Simple;

########################################
## TOUCH NOTHING IN THIS FILE         ##
## USE THE CONFIGURATION FILE INSTEAD ##
########################################

########################
## VARIABLES - STATIC ##
########################

my $BEGINDATE;
my $ENDDATE;
my $CURDATE;
$CURDATE->{year}  = strftime "%Y", localtime;
$CURDATE->{month} = strftime "%m", localtime;
$CURDATE->{day}   = strftime "%d", localtime;
$CURDATE->{short} = $CURDATE->{year}.'-'.$CURDATE->{month}.'-'.$CURDATE->{day};
$CURDATE->{nice}  = Month_to_Text($CURDATE->{month}, 1) . ' ' .
    English_Ordinal(int($CURDATE->{day})) . ', ' . $CURDATE->{year};
my $CURTIME = sprintf(
    "%02d:%02d:%02d",
    (strftime "%H", localtime),
    (strftime "%M", localtime),
    (strftime "%S", localtime));
my $CURUSER = $ENV{LOGNAME} || $ENV{USER} || getpwuid($<);
my @PLEX_LOGFILES = ( 
    '/var/lib/plexmediaserver/Library/Application Support' .
    '/Plex Media Server/Logs/Plex Media Server.old.log',
    '/var/lib/plexmediaserver/Library/Application Support' .
    '/Plex Media Server/Logs/Plex Media Server.log',
    'plex.log', 'plex.old.log' );
# Add potential logfiles for OSX
if ( $CURUSER ) {
    push(@PLEX_LOGFILES, 
        "/Users/$CURUSER/Library/Logs/Plex Media Server.old.log");
    push(@PLEX_LOGFILES, 
        "/Users/$CURUSER/Library/Logs/Plex Media Server.log");
}
# Newline string, keeps things tidy
my $NL = "\n";
my $SRCHDATE;
my $VERSION = "1.0a";

#########################
## VARIABLES - DYNAMIC ##
#########################

my $datesrch;
my $email;
$email->{body} = "";
$email->{clienttext} = "";
my $html;
$html->{begin} = "";
$html->{core}  = "";
$html->{end}   = "";
my $obj_lwp;
my $obj_xml;
my $plex_cache;
my $plex_clientmap;
my $plex_dates;
my $plex_numclients = 0;
my $plex_opts;
# Default options (can be overridden by config file)
$plex_opts->{debug}         = 0;
$plex_opts->{htmlout}       = 0;
$plex_opts->{htmlimgpic}    = 1;
$plex_opts->{htmlimgwidth}  = "120px";
#$plex_opts->{htmlimgheight} = "160px";
$plex_opts->{htmllenlimit}  = 22;
$plex_opts->{htmlnoimg}     = "/images/nothumb.png";
$plex_opts->{xmlout}        = 0;
my $plex_parts;

###########################
## MAIN CODE STARTS HERE ##
###########################

print "Plex Reporter Script - Version $VERSION$NL";

# Check for any passed arguments
&plex_checkArgs(@ARGV);

# Check for the configuration file
&plex_configFind;

# Load the configuration file in
&plex_configLoad;

# Load the client mapping file (if one exists)
&plex_clientLoad;

# Check the required variables have been loaded
&plex_variableCheck;

# Create the HTML image string (for sizing)
&plex_htmlImgString;

# Create the LWP and XML objects
$obj_lwp = new LWP::UserAgent ||
    &plex_die("Failed to create LWP object");

# XML object for later
$obj_xml = new XML::Simple ||
    &plex_die("Failed to create XML object");

# Check that any passed date is valid
&plex_checkDates;

# If media lookup is enabled, and the script is on the PMS, check connectivity
&plex_mediaConnCheck;

# If the connection test worked, some extra info could be displayed
( defined($plex_opts->{servername}) ) &&
    print "- Server Name: ".$plex_opts->{servername}.$NL;
( defined($plex_opts->{server_ver}) ) &&
    print "- Server Ver:  ".$plex_opts->{server_ver}.$NL;

# Loop through each logfile and pull in any relevant lines
foreach my $plex_lf ( @PLEX_LOGFILES ) {
    &plex_debug(1,"Checking for logfile: $plex_lf");
    # Check the logfile exists
    if ( -f "$plex_lf" ) {
        print "- Reading logfile: $plex_lf$NL";
        # Open the logfile and parse it
        &plex_parseLog($plex_lf);
    } else {
        # Logfile does not exist
        &plex_debug(2,"Logfile does not exist: '$plex_lf'");
    }
}
# Newline for spacing
print $NL;

# In order for processing to work correctly in a range
# create a hash entry for every date within the range
# Note: This is only enabled when working in HTML rangesplit mode
if ( $plex_opts->{rangesplit} ) {
    print "- Rangesplit mode enabled, enabling empty day reporting$NL$NL";
    # Loop through every possible date in the range
    my $tmp_dstart = DateTime->new(
        day   => $BEGINDATE->{day},
        month => $BEGINDATE->{month},
        year  => $BEGINDATE->{year},
    );
    my $tmp_dstop = DateTime->new(
        day   => $ENDDATE->{day},
        month => $ENDDATE->{month},
        year  => $ENDDATE->{year},
    );
    do {
        $plex_dates->{$tmp_dstart->ymd('-')}->{_ignore_} = 1;
    } while ( $tmp_dstart->add(days => 1) <= $tmp_dstop ) 
}

# Check if any clients connected now the logs have been parsed
if ( ! keys(%{$plex_dates}) ) {
    # No date entries at all
    if ( defined($ENDDATE->{short}) ) {
        # Date range
        print "- No clients/users connected to your Plex server between ".
            $BEGINDATE->{nice}." and ".$ENDDATE->{nice}.$NL;
        $email->{clienttext} .= "- No clients/users connected to your Plex server between ".
            $BEGINDATE->{nice}." and ".$ENDDATE->{nice}.$NL;
    } else {
        # Single date
        print "- No clients/users connected to your Plex server on ".
            $SRCHDATE->{nice}.$NL;
        $email->{clienttext} .= "- No clients/users connected to your Plex server on ".
            $SRCHDATE->{nice}.$NL;
    }
} else {
    # At least one date entry
    if ( defined($ENDDATE->{short}) ) {
        # Date range, example the clients listed on that date
        my $tmp_clientlist;
        foreach my $tmp_date (keys %{$plex_dates}) {
            foreach my $plex_client (keys %{$plex_dates->{$tmp_date}}) {
                if ( $plex_client ne "_ignore_" ) {
                    $tmp_clientlist->{$plex_client} = 1;
                }
            }
        }
        print '- '.scalar(keys %{$tmp_clientlist}).
            " client(s)/user(s) connected to your Plex server between ".
            $BEGINDATE->{nice}." and ".$ENDDATE->{nice}.$NL;
        $email->{clienttext} .= "- ".scalar(keys %{$tmp_clientlist}).
            " client(s)/user(s) connected to your Plex server between ".
            $BEGINDATE->{nice}." and ".$ENDDATE->{nice}.$NL.$NL;
    } else {
        # Single date, examine the client entries on that date
        # tmp_clientlist should now contain a list of hosts
        print '- '.scalar(keys %{$plex_dates->{$SRCHDATE->{short}}}).
            " client(s)/user(s) connected to your Plex server on ".
            $SRCHDATE->{nice}.$NL;
        $email->{clienttext} .= "- ".scalar(keys %{$plex_dates->{$SRCHDATE->{short}}}).
            " client(s)/user(s) connected to your Plex server on ".
            $SRCHDATE->{nice}.$NL.$NL;
    }
}


# Loop through each date and process the client list accordingly
# Note: Not all dates will have a client list 
# TODO - This loop is too large, abstract as much out as possible
foreach my $plex_date (sort keys %{$plex_dates}) {
    # Split the plex_date variable for processing
    my @tmp_ds = split(/-/,$plex_date);
    # If a date range is being processed, SRCHDATE needs to be updated
    if ( defined($ENDDATE->{short}) ) {
        # Update the SRCHDATE variable
        $SRCHDATE->{short} = $plex_date;
        $SRCHDATE->{day}   = $tmp_ds[2];
        $SRCHDATE->{month} = $tmp_ds[1];
        $SRCHDATE->{year}  = $tmp_ds[0];
        $SRCHDATE->{nice} = Month_to_Text($tmp_ds[1], 1) . ' ' .
            English_Ordinal($tmp_ds[2]) . ', ' . $tmp_ds[0];
    }
    undef(@tmp_ds);

    # Show how many clients have connected on the current loop date
    print '- '.&plex_clientsConnected . " client(s)/user(s) accessed your server on $SRCHDATE->{nice}$NL";
    # Email header for start of a new date
    $email->{body} .= &plex_clientsConnected . " client(s)/user(s) accessed your server on $SRCHDATE->{nice}$NL";

    print "$NL- Examining activity for date: ".$SRCHDATE->{nice}."$NL";
    $email->{clienttext} .= "Activity for date: ".$SRCHDATE->{nice}."$NL";


    # Did any clients connect on this date
    if ( scalar(keys %{$plex_dates->{$plex_date}}) == 1 ) {
        # One client entry, check if its the _ignore_ one
        if ( defined($plex_dates->{$plex_date}->{_ignore_}) ) {
            # No clients connected on this date
            print "- No clients connected to the server on this date$NL";
            $email->{clienttext} .= "- No clients connected to the server on this date$NL$NL";
            # If running in rangesplit mode, write the HTML
            if ( $plex_opts->{rangesplit} &&
                $plex_opts->{htmlout} ) {
                # Build the HTML output
                print "$NL- Constructing the HTML file for this date..$NL";
                &plex_htmlBuildBegin;
                &plex_htmlBuildEnd;
                &plex_htmlWrite;
            }
            next;            
        }
    }
    if ( scalar(keys %{$plex_dates->{$plex_date}}) == 0 ) {
        # No clients connected on this date
        print "- No clients connected to the server on this date$NL";
        $email->{clienttext} .= "- No clients connected to the server on this date$NL$NL";
        # If running in rangesplit mode, write the HTML
        if ( $plex_opts->{rangesplit} &&
            $plex_opts->{htmlout} ) {
            # Build the HTML output
            print "$NL- Constructing the HTML file for this date..$NL";
            &plex_htmlBuildBegin;
            &plex_htmlBuildEnd;
            &plex_htmlWrite;
        }
        next;
    }

    # Clients connected, loop through each
    foreach my $plex_client (sort keys %{$plex_dates->{$plex_date}}) {
        if ( $plex_client eq "_ignore_" ) {
            # Dummy entry for rangesplit
            next;
        }
        # plex_client is an IP address
        my @tmp_cw_movie;
        my @tmp_cw_tv;
        my @tmp_cw_un;
        ## Source the name of the client
        my $tmp_clientname = &plex_clientLookup($plex_client);
        print "  - Examining activity for client: ".$tmp_clientname->{name}."$NL";
        $email->{clienttext} .= "  - Activity for client: ".$tmp_clientname->{name}."$NL";

        # Information line on how many files were accessed on this date
        my $vid_accessed = scalar(keys %{$plex_dates->{$plex_date}->{$plex_client}});
        printf "  - %i video file(s) have been accessed on %s by this client$NL",
            $vid_accessed, $SRCHDATE->{nice};
        $email->{clienttext} .= "  - " . $vid_accessed .
            " file(s) have been accessed on ".$SRCHDATE->{nice}." by this client$NL";
        $html->{core} .= '<div class="item-list-item"><p>Client/User '.$tmp_clientname->{htmlname} .
                         " accessed <b>" . $vid_accessed .
                         "</b> item(s) on <b>" . $SRCHDATE->{nice} .
                         "</b></p>$NL" . '<ul style="list-style-type:none;">' . $NL;

        # Loop through each of the plex items for this client and date
        foreach my $plex_item (sort keys %{$plex_dates->{$plex_date}->{$plex_client}}) {
            my $tmp_item = &plex_itemLookup($plex_item);
            # Sanity check, has teh item type been set?
            if ( ! defined($tmp_item->{type}) ) {
                print "ERROR: A cached item type was not set\n";
                print Dumper $tmp_item;
                &plex_die("See the above error message");
            }
            if ( $tmp_item->{type} eq "movie" ) {
                push(@tmp_cw_movie, $tmp_item);
            } elsif ( $tmp_item->{type} eq "tv" ) {
                push(@tmp_cw_tv, $tmp_item);
            } elsif ( $tmp_item->{type} eq "unknown" ) {
                push(@tmp_cw_un, $tmp_item);
            } else {
                # Programming error, shouldn't happen
                &plex_die("Found unknown media type after item lookup: ".
                    $tmp_item->{type});
            }
        }
        # End of item->viewed_array loop

        # Sort the watched entries based on their title
        if ( @tmp_cw_movie ) {
            @tmp_cw_movie = sort { $a->{title} cmp $b->{title} } @tmp_cw_movie;
        }
        if ( @tmp_cw_tv ) {
            @tmp_cw_tv = sort { $a->{title} cmp $b->{title} } @tmp_cw_tv;
        }
        if ( @tmp_cw_un ) {
            @tmp_cw_un = sort { $a->{title} cmp $b->{title} } @tmp_cw_un;
        }

        # Loop through each watched entry
        # Note: If you want to prioritise TV first, swap these two arrays around
        foreach my $tmp_item (@tmp_cw_movie,@tmp_cw_tv,@tmp_cw_un) {
            print "    - ".$tmp_item->{title}.$NL;
            # Email code
            $email->{clienttext} .= "   - ".$tmp_item->{title}.$NL;

            # HTML code
            if ( $plex_opts->{medialookup} ) {
                $html->{core} .= '<li class="item">' .
                    '<img src="' . $tmp_item->{imgurl} . '" ';
#                    '" title="'  . $tmp_item->{title} ;
                    if ( ! defined($html->{imgurl}) ) {
                        # No image was found, change the ALT text
                        $html->{core} .= ' alt="No image found" ';
                    } else {
                        $html->{core} .= ' alt="' . $tmp_item->{title} . '" ';
                    }
                    $html->{core} .= $plex_opts->{htmlimgstr} . ' />' .
                        $tmp_item->{htmltitle} . "</li>$NL";
             } else {
                 # Media lookup is disabled, so no images
                 $html->{core} .= '<li class="item">' .
                     '<img src="" title="Disabled" ' .
                     'alt="' . "Lookup Disabled" . '" ' .
                     $plex_opts->{htmlimgstr} . ' />' .
                     $tmp_item->{title} . "</li>$NL";
             }
        }
        # End of viewed item action loop

        # Email formatting
        $email->{clienttext} .= $NL;

        # Close the HTML client output
        $html->{core} .= '</ul></div>'.$NL;

        # End of viewed item loop
        print "$NL";

    }
    # End of client loop (on a specific date)

    # If running in rangesplit mode, a separate HTML file should be created for each day
    if ( $plex_opts->{rangesplit} && 
         $plex_opts->{htmlout} ) {
        # Build the HTML output
        print "$NL- Constructing the HTML file for this date..$NL";
        &plex_htmlBuildBegin;
        &plex_htmlBuildEnd;
        &plex_htmlWrite;
    }

}
# End of date loop


# Action if HTML output is enabled (and rangesplit is disabled)
if ( $plex_opts->{htmlout} && 
     ! $plex_opts->{rangesplit} ) {
    # Build the HTML output
    print "$NL- Constructing the HTML file..$NL";
    &plex_htmlBuildBegin;
    &plex_htmlBuildEnd;
    &plex_htmlWrite;
}

# Action if an email server was specified
if ( $plex_opts->{emailserver} ) {
    # Construct the daily email
    &plex_emailBuild;
    # Send the email out
    &plex_emailSend;
}

# Write the XML data if it was enabled
if ( $plex_opts->{xmlout} ) {
    &plex_xmlOut;
}

# All done
print "${NL}Report finished.$NL";
exit 0;



#################
## SUBROUTINES ##
#################

sub plex_checkArgs() {
    # Loop through the cmdline args (if any) and check/use them
    &plex_debug(3,"Called plex_CheckArgs");
    while ($_[0]) {
        if ( $_[0] eq "-c" || $_[0] eq "--config" ) {
            # Configuration file specified
            if ( defined($_[1]) ) {
                if ( -f "$_[1]" ) {
                    # Config file is valid, use it later
                    $plex_opts->{config} = $_[1];
                } else {
                    # Config file specified doesn't exist
                    &plex_die("Specified configuration file does not exist");
                }
                # At this point, shift again to skip over the filename
                shift;
            } else {
                # config option specified but no file passed
                &plex_showHelp;
                &plex_die("Config option specified but no filename given");
            }
        } elsif ( $_[0] eq "-d" || $_[0] eq "--date" ) {
            # Custom date (one) has been passed, validate it
            if ( ! $_[1] ) {
                &plex_die("You passed the -d/--date option without specifying a date");
            }
            if ( $_[1] !~ /^[1-2][0-9][0-9][0-9]-[0-2][0-9]-[0-3][0-9]$/ ){
                # Invalid date specified
                &plex_die("Invalid date specified, must be YYYY-MM-DD");
            }
            # Check if a date search has already been enabled
            if ( defined($datesrch) ) {
                &plex_die("You cannot specify multiple date searches at the same time");
            } else {
                $datesrch = 1;
            }
            # Valid date, save it
            my @tmp_date = split(/-/,$_[1]);
            $SRCHDATE->{year}  = $tmp_date[0];
            $SRCHDATE->{month} = $tmp_date[1];
            $SRCHDATE->{day}   = $tmp_date[2];
            $SRCHDATE->{short} = $tmp_date[0].'-'.$tmp_date[1].'-'.$tmp_date[2];
            $SRCHDATE->{nice} = Month_to_Text($tmp_date[1], 1) . ' ' .
                English_Ordinal($tmp_date[2]) . ', ' . $tmp_date[0];
            undef(@tmp_date);
            shift;
        } elsif ( $_[0] eq "-r" || $_[0] eq "--range"  || $_[0] eq "-R" ) {
            # Custom date (range) has been passed, validate it
            if ( ! $_[2] ) {
                &plex_die("You passed the -r/--range option without specifying a start/finish date");
            }
            if ( $_[1] !~ /^[1-2][0-9][0-9][0-9]-[0-2][0-9]-[0-3][0-9]$/ || 
                 $_[2] !~ /^[1-2][0-9][0-9][0-9]-[0-2][0-9]-[0-3][0-9]$/ ){
                # Invalid date specified
                &plex_die("Invalid date specified, must be YYYY-MM-DD");
            }
            # Check if a date search has already been enabled
            if ( defined($datesrch) ) {
                &plex_die("You cannot specify multiple date searches at the same time");
            } else {
                $datesrch = 1;
            }
            # Valid date, save it
            my @tmp_date = split(/-/,$_[1]);
            $BEGINDATE->{year}  = $tmp_date[0];
            $BEGINDATE->{month} = $tmp_date[1];
            $BEGINDATE->{day}   = $tmp_date[2];
            $BEGINDATE->{short} = $tmp_date[0].'-'.$tmp_date[1].'-'.$tmp_date[2];
            $BEGINDATE->{nice}  = Month_to_Text($tmp_date[1], 1) . ' ' .
                English_Ordinal($tmp_date[2]) . ', ' . $tmp_date[0];

            @tmp_date = split(/-/,$_[2]);
            $ENDDATE->{year}  = $tmp_date[0];
            $ENDDATE->{month} = $tmp_date[1];
            $ENDDATE->{day}   = $tmp_date[2];
            $ENDDATE->{short} = $tmp_date[0].'-'.$tmp_date[1].'-'.$tmp_date[2];
            $ENDDATE->{nice}  = Month_to_Text($tmp_date[1], 1) . ' ' .
                English_Ordinal($tmp_date[2]) . ', ' . $tmp_date[0];
            # If -R (not -r) was specified, a report must be generate for each date
            if ( $_[0] eq "-R" ) {
                $plex_opts->{rangesplit} = 1;
            } else {
                $plex_opts->{rangesplit} = 0;
            }
            shift;
            shift;
        } elsif ( $_[0] eq "-h" || $_[0] eq "--help" ) {
            # Print the help information
            &plex_showHelp;
            exit 0;
        } elsif ( $_[0] eq "-v" || $_[0] eq "--verbose" || $_[0] eq "--debug" ) {
            # Increase debugging level
            $plex_opts->{debug}++;
        } elsif ( $_[0] eq "-w" || $_[0] eq "--web" ) {
            # HTML output
            ( defined($_[1]) ) || &plex_die("HTML output enabled but no output file specified");
            ( defined($_[2]) ) || &plex_die("HTML output enabled but no relative CSS file specified");
            ( length($_[1]) )  || &plex_die("HTML output enabled but no output file specified");
            ( length($_[2]) )  || &plex_die("HTML output enabled but no relative CSS file specified");
            $plex_opts->{htmlout}    = 1;
            $plex_opts->{htmoutfile} = $_[1];
            $plex_opts->{htmlcss}    = $_[2];
            shift;
            shift;
        } elsif ( $_[0] eq "-x" || $_[0] eq "--xml" ) {
            # XML output has been enabled
            ( defined($_[1]) ) || &plex_die("XML output was enabled but no file was specified");
            $plex_opts->{xmlout}  = 1;
            $plex_opts->{xmlfile} = $_[1];
            shift; 
        } else {
            # Invalid option
            &plex_showHelp;
            print "ERROR: Invalid option specified: " . $_[0] . "$NL$NL";
            exit 1;
        }
        shift;
    }
    # At this point, if SRCHDATE isn't populated, use CURDATE
    if ( ! defined($SRCHDATE) ) {
        $SRCHDATE = $CURDATE;
    }
    # At this point, if rangesplit isnt populated, set it to zero
    if ( ! defined($plex_opts->{rangesplit}) ) {
        $plex_opts->{rangesplit} = 0;
    }
}

sub plex_checkDates {
    # Check the stored date(s) and ensure they are valid
    &plex_debug(3,"Called plex_checkDates");
    # SRCHDATE
    ( check_date($SRCHDATE->{year}, $SRCHDATE->{month}, $SRCHDATE->{day}) ) ||
        &plex_die("The specified date is not valid: ".
                  $SRCHDATE->{year}.'-'.$SRCHDATE->{month}.'-'.$SRCHDATE->{day});
    # BEGINDATE (if it exists)
    if ( defined($BEGINDATE->{short}) ) {
        ( check_date($BEGINDATE->{year}, $BEGINDATE->{month}, $BEGINDATE->{day}) ) ||
            &plex_die("The specified begin date is not valid: ".
                      $BEGINDATE->{year}.'-'.$BEGINDATE->{month}.'-'.$BEGINDATE->{day});
    }
    # ENDDATE (if it exists)
    if ( defined($ENDDATE->{short}) ) {
        ( check_date($ENDDATE->{year}, $ENDDATE->{month}, $ENDDATE->{day}) ) ||
            &plex_die("The specified end date is not valid: ".
                      $ENDDATE->{year}.'-'.$ENDDATE->{month}.'-'.$ENDDATE->{day});
    }
    # ENDDATE > BEGINDATE
    if ( defined($BEGINDATE->{short}) && defined($ENDDATE->{short}) ) {
        $ENDDATE->{delta} = Delta_Days($BEGINDATE->{year}, $BEGINDATE->{month}, $BEGINDATE->{day},
                                       $ENDDATE->{year}, $ENDDATE->{month}, $ENDDATE->{day});
        if ( $ENDDATE->{delta} == 0 ) {
            # Dates are the same
            &plex_die("The specified begin/end dates are the same");
        } elsif ( $ENDDATE->{delta} < 0 ) {
            # Dates are the wrong way around
            &plex_die("The specified begin date is after the end date");
        }
    }
}

sub plex_clientLoad {
    # Load a list of client mappings from a file
    &plex_debug(3,"Called plex_clientLoad");
    if ( defined($plex_opts->{clientcfg}) ) {
        open (CLIENTSFILE, '<'.$plex_opts->{clientcfg}) ||
            &plex_die("Failed to open client configuration file for reading");
        while (<CLIENTSFILE>) {
            chomp;
            if ( $_ !~ /^$/ &&
                 $_ !~ /^\ $/ &&
                 $_ !~ /^\#/ &&
                 $_ =~ /^.+\|.+$/ ) {
                # Line looks usable, split it
                my ($client_host, $client_name) = split(/\|/, $_);
                if ( defined($client_host) &&
                     defined($client_name) ) {
                    # Successful split, add it to hash
                    $plex_clientmap->{$client_host}->{name} = $client_name;
                    $plex_clientmap->{$client_host}->{htmlname} = "<b>$client_name</b>";
                }
            }
        }
        close (CLIENTSFILE);
    }
}

sub plex_clientLookup {
    # Attempt to lookup the hostname of the client (if enabled)
    &plex_debug(3,"Called plex_clientLookup");
    my $tmp_host = shift;
    my $tmp_client;
    my $tmp_dnsname;
    # Check first if this is already a known name
    if ( defined($plex_clientmap->{$tmp_host}) ) {
        # Already mapped
        $tmp_client->{name} = $plex_clientmap->{$tmp_host}->{name};
        $tmp_client->{htmlname} = $plex_clientmap->{$tmp_host}->{htmlname};
        return $tmp_client;
    }

    # Client IP wasnt mapped, perform a lookup if enabled
    if ( $plex_opts->{dnslookup} ) {
        # Perform a reverse DNS lookup
        $tmp_dnsname = gethostbyaddr(inet_aton($tmp_host), AF_INET);
        if ( ! $tmp_dnsname ) {
            # No reverse DNS found
            $tmp_client->{name} = "$tmp_host (Unknown)";
            $tmp_client->{htmlname} = '<b>'.$tmp_host.' (Unknown)</b>';
        } else {
            # Reverse DNS found
            $tmp_client->{name} = $tmp_host." ($tmp_dnsname)";
            $tmp_client->{htmlname} = '<b>'.$tmp_host.' ('.$tmp_dnsname.')</b>';
        }
    } else {
        # Lookups disabled, default the name
        $tmp_client->{name} = $tmp_host;
        $tmp_client->{htmlname} = "<b>$tmp_host</b>";
    }

    # Add the IP to the cache
    $plex_clientmap->{$tmp_host}->{name}     = $tmp_client->{name};
    $plex_clientmap->{$tmp_host}->{htmlname} = $tmp_client->{htmlname};

    # Return the client info
    return $tmp_client;
}

sub plex_clientsConnected {
    # Determine how many clients connected on the current (set) date
    &plex_debug(3,"Called plex_clientsConnected");
    my $tmp_srchdate = $SRCHDATE->{short};
    # Check if the _ignore_ entry is present
    if ( defined($plex_dates->{$tmp_srchdate}->{_ignore_}) ) {
        return scalar(keys %{$plex_dates->{$tmp_srchdate}})-1;
    }
    return scalar(keys %{$plex_dates->{$tmp_srchdate}});
}

sub plex_configFind {
    # Search for the usable configuration file
    &plex_debug(3,"Called plex_configFind");
    # If the config variable is already defined, skip this
    if ( defined($plex_opts->{config}) ) {
        # Was already specified on the command line
        return;
    }
    if ( $CURUSER ) {
        if ( -f "/home/$CURUSER/.plex-reporter.cfg" ) {
            $plex_opts->{config} = "/home/$CURUSER/.plex-reporter.cfg";
        } elsif ( -f "/Users/$CURUSER/.plex-reporter.cfg" ) {
            $plex_opts->{config} = "/Users/$CURUSER/.plex-reporter.cfg";
        } elsif ( -f "/etc/plex-reporter.cfg" ) {
            $plex_opts->{config} = "/etc/plex-reporter.cfg";
        } else {
            &plex_die("No configuration file was found, aborting");
        }
        # Check for client mapping file
        if ( -f "/home/$CURUSER/.plex-clients.cfg" ) {
            $plex_opts->{clientcfg} = "/home/$CURUSER/.plex-clients.cfg";
        } elsif ( -f "/Users/$CURUSER/.plex-clients.cfg" ) {
            $plex_opts->{clientcfg} = "/Users/$CURUSER/.plex-clients.cfg";
        } elsif ( -f "/etc/plex-clients.cfg" ) {
            $plex_opts->{clientcfg} = "/etc/plex-clients.cfg";
        }
    } elsif ( -f "/etc/plex-reporter.cfg" ) {
        $plex_opts->{config} = "/etc/plex-reporter.cfg";
        # Check for client mapping file
        if ( -f "/etc/plex-clients.cfg" ) {
            $plex_opts->{clientcfg} = "/etc/plex-reporter.cfg";
        }
    } else {
        # No configuration file found, abort
        &plex_die("No configuration file was found, aborting");
    }
    if ( defined($plex_opts->{clientcfg}) ) {
        print "- Client configuration file found: ".$plex_opts->{clientcfg}."$NL";
    }
}

sub plex_configLoad {
    # Load the configuration file and parse each option
    &plex_debug(3,"Called plex_configLoad");
    open (CFG_FILE, "<".$plex_opts->{config}) ||
        &plex_die("Failed to open configuration file for reading");
    while (<CFG_FILE>) {
        if ( $_ =~ /^#/ || $_ =~ /^$/ || $_ =~ /^\ +$/ ) {
            # Line to be ignored
            next;
        }
        # Process the line
        chomp;
        my @tmp_opt = split(/:/, $_);
        # Each option should be in name:value format, error if not
        ( scalar(@tmp_opt) == 2 ) ||
            &plex_die("Invalid option found: $_$NL");
        # Add the option to the hash
        if ( $tmp_opt[0] eq "debug" ) {
            # As the debug level can be set on the cmdline, increment, not replace
            $plex_opts->{debug} += int($tmp_opt[1]);
        } elsif ( $tmp_opt[0] eq "dnslookup"    ||
                  $tmp_opt[0] eq "medialookup"  ||
                  $tmp_opt[0] eq "warnmissing"  ||
                  $tmp_opt[0] eq "htmlout"      ||
                  $tmp_opt[0] eq "htmldate"     ||
                  $tmp_opt[0] eq "htmlimgpic"   ||
                  $tmp_opt[0] eq "htmllenlimit" ||
                  $tmp_opt[0] eq "xmlout" ) {
            # Numeric options, typecast them
            $plex_opts->{$tmp_opt[0]} = int($tmp_opt[1]);
        } else {
            # Standard option, overwrite
            $plex_opts->{$tmp_opt[0]} = $tmp_opt[1];
        }
    }
    close (CFG_FILE);

    # Now the configuration has been loaded, check if rangesplit mode can work
    # Rangesplit implies HTML mode, so enable it
    if ( defined($plex_opts->{htmloutfile}) &&
         defined($plex_opts->{htmlcss}) ) {
        $plex_opts->{htmlout} = 1;
    } else {
        # Rangesplit specified but missing config items
        &plex_die("Rangesplit mode specified but HTML configuration incomplete");
    }
    # If the user enabled xml output, check a file was also specified
    if ( $plex_opts->{xmlout} ) {
        ( defined($plex_opts->{xmlfile}) ) || 
            &plex_die("XML output was enabled but no file was specified");
        ( length($plex_opts->{xmlfile}) )  ||
            &plex_die("XML output was enabled but no file was specified");
    }
}

sub plex_dateProcess() {
    # Check if the passed within the range we want to process
    &plex_debug(3,"Called plex_dateProcess");
    my $tmp_delta;
    if ( defined($BEGINDATE->{short}) ) {
        # Working with a range
        $tmp_delta = Delta_Days($BEGINDATE->{year},$BEGINDATE->{month},$BEGINDATE->{day},
                                $_[0]->{year},$_[0]->{month},$_[0]->{day});
        if ( $tmp_delta < 0 ) {
            # Date was in the past
            return 0;
        } elsif ( $tmp_delta > $ENDDATE->{delta} ) {
            # Date was past the end date
            return 0;
        } else {
            # Date is in range, use it
            return 1;
        }
    } else {
        # Single date
        $tmp_delta = Delta_Days($SRCHDATE->{year},$SRCHDATE->{month},$SRCHDATE->{day},
                                $_[0]->{year},$_[0]->{month},$_[0]->{day});
        if ( $tmp_delta == 0 ) {
            # Same day
            return 1;
        } else {
            # Not the same day, ignore
            return 0;
        }
    }
}

sub plex_emailBuild {
    # Build the email to be sent
    &plex_debug(3,"Called plex_emailBuild");
    $email->{subject} = "Plex daily report - " . localtime;
    $email->{body} = "Report for Plex server: ".$plex_opts->{servername}." - ".
        $CURDATE->{nice}."$NL$NL";
    if ( ! $plex_opts->{medialookup} ) {
        $email->{header} .= "Running in offline mode (no media information)$NL";
    }
    $email->{body} .= $email->{clienttext};
    $email->{body} .= "${NL}${NL}Report finished.";
}

sub plex_emailSend {
    # Send an email to the end user
    &plex_debug(3,"Called plex_emailSend");
    if ( defined($plex_opts->{emailserver}) &&
         defined($plex_opts->{emailreceiver}) &&
         defined($plex_opts->{emailsender}) ) {
        print "$NL- Sending email to: ".$plex_opts->{emailreceiver}."$NL";
        my $email = MIME::Lite->new(
                From     => $plex_opts->{emailsender},
                To       => $plex_opts->{emailreceiver},
                Subject  => $email->{subject},
                Data     => $email->{body}
        );
        if ( defined($plex_opts->{emailuser}) && 
             defined($plex_opts->{emailpass}) ) {
            $email->send('smtp', $plex_opts->{emailserver}, 
                    AuthUser => $plex_opts->{emailuser}, 
                    AuthPass => $plex_opts->{emailpass}) || 
                &plex_die("Failed to send email");
        } else {
            $email->send('smtp', $plex_opts->{emailserver}) ||
                &plex_die("Failed to send email");
        }
        print "- Email sent successfully$NL";
    }
}

sub plex_htmlBuildBegin {
    # Build the beginning of the HTML output
    &plex_debug(3,"Called plex_htmlBuildBegin");
    $html->{begin} .= '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"'.$NL;
    $html->{begin} .= '   "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">'.$NL;
    $html->{begin} .= '<html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en">'.$NL;
    $html->{begin} .= '<head>'.$NL;
    if ( defined($ENDDATE->{short}) ) {
        if ( $plex_opts->{rangesplit} ) {
            $html->{begin} .= '<title>Plex Reporter - '.$SRCHDATE->{nice}.'</title>'.$NL;
        } else {
            $html->{begin} .= '<title>Plex Reporter - '.$BEGINDATE->{nice}.' to '.$ENDDATE->{nice}.'</title>'.$NL;
        }
    } else {
        $html->{begin} .= '<title>Plex Reporter - '.$SRCHDATE->{nice}.'</title>'.$NL;
    }
    $html->{begin} .= '<meta http-equiv="content-type" content="text/html;charset=utf-8" />'.$NL;
    $html->{begin} .= '<meta name="viewport" content="initial-scale=1,minimum-scale=1,maximum-scale=1" />'.$NL;
    $html->{begin} .= '<link rel="shortcut icon" href="favicon.ico" />'.$NL;
    $html->{begin} .= '<link rel="stylesheet" href="'.$plex_opts->{htmlcss}.'" type="text/css" />'.$NL;
    $html->{begin} .= '</head>'.$NL;
    $html->{begin} .= '<body>'.$NL;
    $html->{begin} .= '<div id="container">'.$NL;
    $html->{begin} .= '<div id="header">'.$NL;
    $html->{begin} .= '<h1><span>Plex Reporter</span></h1>'.$NL;
    $html->{begin} .= '<p><span>Clients/Users</span><strong id="total_items">'.&plex_clientsConnected.'</strong></p></div>'.$NL;
    $html->{begin} .= '<div id="main">'.$NL;
    my $html_index = "";
    if ( defined($plex_opts->{htmlurl}) ) {
        $html_index = $plex_opts->{htmlurl};
    }
    if ( defined($ENDDATE->{short}) ) {
        if ( $plex_opts->{rangesplit} ) {
            $html->{begin} .= '<div id="section-header"><div><h2>'.$plex_opts->{servername}.'</h2><p><span>'.$SRCHDATE->{nice}.'</span><span><a href="'.$html_index.'">Index</a></span></p></div></div>'.$NL;
#            $html->{begin} .= '<div id="section-header"><div><h2>'.$plex_opts->{servername}.'</h2><p><a href="'.$html_index.'">'.$SRCHDATE->{nice}.'</a></p>'.$html_index.'</div></div>'.$NL;
        } else {
            $html->{begin} .= '<div id="section-header"><div><h2>'.$plex_opts->{servername}.'</h2><p><span>'.$BEGINDATE->{nice}.' to '.$ENDDATE->{nice}.'</span><span><a href="'.$html_index.'">Index</a></span></p></div></div>'.$NL;
#            $html->{begin} .= '<div id="section-header"><div><h2>'.$plex_opts->{servername}.'</h2><p><a href="'.$html_index.'">'.$BEGINDATE->{nice}.' to '.$ENDDATE->{nice}.'</a></p>'.$html_index.'</div></div>'.$NL;
        }
    } else {
        $html->{begin} .= '<div id="section-header"><div><h2>'.$plex_opts->{servername}.'</h2><p><span>'.$SRCHDATE->{nice}.'</span><span><a href="'.$html_index.'">Index</a></span></p></div></div>'.$NL;
    }
    $html->{begin} .= '<div id="item-list">'.$NL;
}

sub plex_htmlBuildEnd {
    # Build the end of the HTML output
    &plex_debug(3,"Called plex_htmlBuildEnd");
    my $html_index  = "";
    if ( defined($plex_opts->{htmlurl}) ) {
        $html_index = $plex_opts->{htmlurl};
    }
    if ( ! &plex_clientsConnected ) {
        # No clients connected
        if ( defined($ENDDATE->{short}) && ! $plex_opts->{rangesplit} ) {
            # Date range, range-split disabled (so single page for all dates)
            $html->{end} .= '<p><b>No clients/users connected between '.$BEGINDATE->{nice}.' and '.$ENDDATE->{nice}.'</b></p>'.$NL;
        } elsif ( defined($ENDDATE->{short}) && $plex_opts->{rangesplit} ) {
            # Date range, range-split enabled (so separate html page for each date)
            $html->{end} .= '<p><b>No clients/users connected on '.$SRCHDATE->{nice}.'</b></p>'.$NL;
        } else {
            # Single date
            $html->{end} .= '<p><b>No clients/users connected on '.$SRCHDATE->{nice}.'</b></p>'.$NL;
        }
    }
    $html->{end} .= '</div>'.$NL;
    $html->{end} .= '</div>'.$NL;
    $html->{end} .= '<div id="footer">'.$NL;
#    $html->{end} .= '<p><span id="last_updated">Updated at '.$CURTIME.' on '.$CURDATE->{nice}."</span>$html_index</p></div>".$NL;
    $html->{end} .= '<p><span id="last_updated">Updated at '.$CURTIME.' on '.$CURDATE->{nice}.'</span><span><a href="'.$html_index.'">Index</a></span></p></div>'.$NL;
    $html->{end} .= '</div>'.$NL;
    $html->{end} .= '</body>'.$NL;
    $html->{end} .= '</html>'.$NL;
    # Add the tag for the php indexer (no newline at the end!)
    $html->{end} .= '<!-- plex-clients:'.&plex_clientsConnected.': -->';
}

sub plex_htmlImgString {
    # Create a new string for width/height formatting
    &plex_debug(3,"Called plex_htmlImgString");
    if ( defined($plex_opts->{htmlimgwidth}) &&
         defined($plex_opts->{htmlimgheight}) ) {
        # Both the width and height are defined
        $plex_opts->{htmlimgstr} = 'width="'.$plex_opts->{htmlimgwidth}.'" '.
            'height="'.$plex_opts->{htmlimgheight}.'" ';
    } elsif ( defined($plex_opts->{htmlimgwidth}) &&
            ! defined($plex_opts->{htmlimgheight}) ) {
        # The width has been specified
        $plex_opts->{htmlimgstr} = 'width="'.$plex_opts->{htmlimgwidth}.'" ';
    } else {             
        # Coding error as the htmlimgwidth variable is set internally
        &plex_die("Missing the htmlimgwidth variable during html generation");
    }
}

sub plex_htmlImgURL {
    # Check if a picture is defined in the passed hash, and return the URL
    &plex_debug(3,"Called plex_htmlImgURL");
    my $tmp_url;
    # If media lookup is disabled, just return the url for the noimage pic
    if ( ! $plex_opts->{medialookup} ) {
        return $plex_opts->{htmlnoimg};
    }
    # Does the user prefer the preview pic or the banner?
    if ( $plex_opts->{htmlimgpic} == 0 ) {
        # Use the episode preview pic (not the banner)
        if ( defined($_[0]->{Video}->{thumb}) ) {
            $tmp_url = 'http://' . $plex_opts->{server} . ':' .
                $plex_opts->{port} . $_[0]->{Video}->{thumb};
        } elsif ( defined($_[0]->{Video}->{parentThumb}) ) {
            # No preview pic was found, use the parent (better than nothing)
            $tmp_url = 'http://' . $plex_opts->{server} . ':' .
                $plex_opts->{port} . $_[0]->{Video}->{parentThumb};
        } else {
            # No preview pic
            $tmp_url = $plex_opts->{htmlnoimg};
        }
    } else {
        # Use the parent banner (if it exists)
        # Note: For a movie, this falls back to the item preview
        if ( defined($_[0]->{Video}->{parentThumb}) ) {
            $tmp_url = 'http://' . $plex_opts->{server} . ':' .
                $plex_opts->{port} . $_[0]->{Video}->{parentThumb};
        } elsif ( defined($_[0]->{Video}->{thumb}) ) {
            $tmp_url = 'http://' . $plex_opts->{server} . ':' .
                $plex_opts->{port} . $_[0]->{Video}->{thumb};
        } else {
            # No thumbnail
            $tmp_url = $plex_opts->{htmlnoimg};
        }
    }
    # Return the URL
    return $tmp_url;
}

sub plex_htmlWrite {
    # Write the HTML file
    &plex_debug(3,"Called plex_htmlWrite");
    # Determine the correct filename to write to
    my $tmp_docname;
    if ( $plex_opts->{htmldate} ) {
        my $tmp_ext = $plex_opts->{htmloutfile};
        my $tmp_pre = $plex_opts->{htmloutfile};
        $tmp_pre =~ s/^(.+)\.([a-zA-Z0-9]+)$/$1/;
        $tmp_ext =~ s/^(.+)\.([a-zA-Z0-9]+)$/$2/;
        if ( $tmp_pre eq "" || $tmp_ext eq "" ) {
            &plex_die("Failed to work out extension from HTML filename");
        }
        if ( defined($ENDDATE->{short}) ) {
            # Date range
            if ( $plex_opts->{rangesplit} ) {
                # Rangesplit enabled, use SRCHDATE
                $tmp_docname = $tmp_pre."-".$SRCHDATE->{short}.".".$tmp_ext;
            } else {
                # Rangesplit disabled, use _to_
                $tmp_docname = $tmp_pre."-".$BEGINDATE->{short}.'_to_'.$ENDDATE->{short}.".".$tmp_ext;
            }
        } else {
            # Singular date in use
            $tmp_docname = $tmp_pre."-".$SRCHDATE->{short}.".".$tmp_ext;
        }
    } else {
        # Using a static name (the one specified)
        $tmp_docname = $plex_opts->{htmloutfile};
    }

    print "- Writing the new HTML file: '".$tmp_docname."'$NL$NL";
    open(OUTFILE, ">".$tmp_docname) ||
        &plex_die("Failed to open ".$tmp_docname." for writing");
    print OUTFILE $html->{begin} .$NL;
    print OUTFILE $html->{core}  .$NL;
    print OUTFILE $html->{end}   .$NL;
    close(OUTFILE);
    # Clean out the HTML buffers (in ase we write multiple pages
    $html->{begin} = "";
    $html->{core}  = "";
    $html->{end}   = "";
}

sub plex_itemLookup() {
    # Perform a lookup on the passed item ID
    &plex_debug(3,"Called plex_itemLookup");
    my $tmp_id = shift;
    my $tmp_item->{id} = $tmp_id;

    # Is the metadata for this ID already stored in the cache
    if ( defined($plex_cache->{$tmp_item->{id}}) ){
        # Return the cache entry
        return $plex_cache->{$tmp_item->{id}};
    }

    # Item isn't in the cache, perform a lookup (if enabled or item ID != 0)
    if ( ! $plex_opts->{medialookup} || $tmp_id eq "0" ) {
        # Connecting to the server is disabled (offline mode)
        $tmp_item->{title}  = "Item: " . $tmp_item->{id};
        $tmp_item->{htmltitle} = "<h4>Item: " . $tmp_item->{id} . "</h4><h4>&nbsp;</h4>";
        $tmp_item->{imgurl} = $plex_opts->{htmlnoimg};
        $tmp_item->{type}   = "unknown";
        # Add the item to the cache
        $plex_cache->{$tmp_id} = $tmp_item;
        undef($tmp_item);
        # Return the item
        return $plex_cache->{$tmp_id}
    }

    # Connect to the plex server to retrieve the metadata
    # Lookup the video file details
    my $vid_raw = $obj_lwp->get("http://".$plex_opts->{server}.":".$plex_opts->{port}."/library/metadata/".$tmp_item->{id}) ||
        &plex_die("Failed to retrieve metadata for item: ".$tmp_item->{id});
    # Check if an error code was returned
    if ( ! $vid_raw->is_success ) {
        # Failed to lookup the item metadata
        printf "WARN: Unable to retrieve metadata for item: ".$tmp_item->{id}."$NL";
        $tmp_item->{title}     = "Item: " . $tmp_item->{id};
        $tmp_item->{htmltitle} = "<h4>Item: " . $tmp_item->{id} . "</h4><h4>&nbsp;</h4>";
        $tmp_item->{imgurl}    = $plex_opts->{htmlnoimg};
        $tmp_item->{type}      = "unknown";
        # Add the item to the cache
        $plex_cache->{$tmp_id} = $tmp_item;
        undef($tmp_item);
        # Return the item
        return $plex_cache->{$tmp_id}
    }

    # Import the XML from the request
    my $vid_xml = $obj_xml->XMLin($vid_raw->content) ||
        &plex_die("Failed to import metadata for item: ".$tmp_item->{id}. "$NL" . $vid_raw->content);
    undef($vid_raw);

    # Check if a filename was in the XML
    my $vid_fname;
    if ( $vid_xml->{Video}->{Media}->{Part}->{file} ) {
        # Simple XML entry, read the actual filename
        $vid_fname = basename($vid_xml->{Video}->{Media}->{Part}->{file}) ||
            &plex_die("Failed to calculate basename from file: " .
                $vid_xml->{Video}->{Media}->{Part}->{file});
        # Check that the file actually exists (if running on local server)
        if ( $plex_opts->{server} eq "127.0.0.1" ||
             $plex_opts->{server} eq "localhost" ) {
            if ( ! -e $vid_xml->{Video}->{Media}->{Part}->{file} ) {
                # File wasn't found on local system
                ( $plex_opts->{warnmissing} ) && 
                    print "WARN: File '" . $vid_xml->{Video}->{Media}->{Part}->{file} .
                        "' was not found on the system$NL";
            }
        }

    } else {
        # There might be more than one Media entry for this movie/show,
        # check if the file actually exists
        # This comes into practice where you replace files (avi to mkv)
        my $tmp_fkeyname;
        foreach my $tmp_keyname (keys %{$vid_xml->{Video}->{Media}}) {
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
            ( $plex_opts->{warnmissing} ) && 
                print "WARN: None of the files for entry ".$tmp_item->{id}." were found$NL";
            $vid_fname = $vid_xml->{Video}->{Media}->{$tmp_fkeyname}->{Part}->{file};
        }
        # Shorten the filename
        $vid_fname = basename($vid_fname) ||
            &plex_die("Failed to calculate basename from file: " . $vid_fname);
    } 

    # Check if a file part was defined in the XML
    if ( defined($vid_xml->{Video}->{Media}->{Part}->{id}) ) {
        # Video part defined, add it to the hash
        $tmp_item->{part_id} = $vid_xml->{Video}->{Media}->{Part}->{id};
    }

    # Check if the video type is defined in the XML
    if ( ! defined($vid_xml->{Video}->{type}) ) {
        # No video type defined, default to filename
        &plex_debug(2,"No video type defined for item ID: ".$tmp_item->{id});
        # Set the HTML title
        # If the length is too large, truncate
        if ( length($tmp_item->{title}) > $plex_opts->{htmllenlimit} ) {
            # Title is too large, trim it
            $tmp_item->{htmltitle} = '<h4>'.substr($tmp_item->{title},0,($plex_opts->{htmllenlimit}-2)).
                '..</h4><h4>&nbsp;</h4>';
        } else {
            # Title is fine, save it
            $tmp_item->{htmltitle} = '<h4>'.$tmp_item->{title}.'</h4><h4>&nbsp;</h4>';
        }
        # Store the attributes
        $tmp_item->{title}  = $vid_fname;
        $tmp_item->{imgurl} = $plex_opts->{htmlnoimg};
        $tmp_item->{type}   = "unknown";
        # Add the item to the cache
        $plex_cache->{$tmp_id} = $tmp_item;
        undef($tmp_item);
        # Return the item
        return $plex_cache->{$tmp_id}
    }

    # Is this entry a TV episode
    if ( $vid_xml->{Video}->{type} eq "episode" ) {
        # TV Episode, lookup the grandparentTitle,title,parentIndex and index
        if ( ! defined($vid_xml->{Video}->{grandparentTitle}) ||
             ! defined($vid_xml->{Video}->{title}) ||
             ! defined($vid_xml->{Video}->{parentIndex}) ||
             ! defined($vid_xml->{Video}->{index})) {
            # Required information is missing, use defaults
            &plex_debug(2,"Item ID $tmp_item has missing metadata");
            # Set the HTML title
            # If the length is too large, truncate
            if ( length($tmp_item->{title}) > $plex_opts->{htmllenlimit} ) {
                # Title is too large, trim it
                $tmp_item->{htmltitle} = '<h4>'.substr($tmp_item->{title},0,($plex_opts->{htmllenlimit}-2)).
                    '..</h4><h4>&nbsp;</h4>';
            } else {
                # Title is fine, save it
                $tmp_item->{htmltitle} = '<h4>'.$tmp_item->{title}.'</h4><h4>&nbsp;</h4>';
            }
            # Store the attributes
            # Title should be the filename here
            $tmp_item->{title}   = $vid_fname;
            $tmp_item->{imgurl}  = &plex_htmlImgURL($vid_xml);
            $tmp_item->{type}    = "tv";
            # Add the item to the cache
            $plex_cache->{$tmp_id} = $tmp_item;
            undef($tmp_item);
            # Return the item
            return $plex_cache->{$tmp_id}
        }

        # Metadata is present, use it
        &plex_debug(2,"Item ID ".$tmp_item->{id}." has title information in XML, using");
        # Create the new title (non-HTML)
        $tmp_item->{title} = $vid_xml->{Video}->{grandparentTitle} . 
            " S" . sprintf("%02d", $vid_xml->{Video}->{parentIndex}) .
            "E" . sprintf("%02d", $vid_xml->{Video}->{index}) . 
            " - " . $vid_xml->{Video}->{title};
        # Set the HTML show/title
        my $tmp_show;
        my $tmp_title;
        # Is the show name too large
        if ( length($vid_xml->{Video}->{grandparentTitle}) > ($plex_opts->{htmllenlimit}-7) ) {
            # Show name needs to be truncated
            $tmp_show = '<h4>'.substr($vid_xml->{Video}->{grandparentTitle}, 0, ($plex_opts->{htmllenlimit}-9)).
                '.. S' . sprintf("%02d", $vid_xml->{Video}->{parentIndex}) .
                'E'    . sprintf("%02d", $vid_xml->{Video}->{index}) . '</h4>';
        } else {
            # Show name is fine, save it
            $tmp_show = '<h4>'.$vid_xml->{Video}->{grandparentTitle}.
                ' S' . sprintf("%02d", $vid_xml->{Video}->{parentIndex}) .
                'E'  . sprintf("%02d", $vid_xml->{Video}->{index}) . '</h4>';
        }
        # Is the episode title too large
        if ( length($vid_xml->{Video}->{title}) > ($plex_opts->{htmllenlimit}) ) {
            # Title needs to be truncated
            $tmp_title = '<h4>'.substr($vid_xml->{Video}->{title}, 0, ($plex_opts->{htmllenlimit}-2)).'..</h4>';
        } else {
            # Title is fine
            $tmp_title = '<h4>'.$vid_xml->{Video}->{title}.'</h4>';
        }
        # Store the new HTML title
        $tmp_item->{htmltitle} = $tmp_show . $tmp_title;
        # Store the attributes
        # XXXX why is the title being saved as the video filename?
        $tmp_item->{title} = $vid_xml->{Video}->{grandparentTitle} .
            ' S'  . sprintf("%02d", $vid_xml->{Video}->{parentIndex}) .
            'E'   . sprintf("%02d", $vid_xml->{Video}->{index}) . 
            ' - ' . $vid_xml->{Video}->{title};
        $tmp_item->{imgurl}  = &plex_htmlImgURL($vid_xml);
        $tmp_item->{show}    = $vid_xml->{Video}->{grandparentTitle};
        $tmp_item->{season}  = $vid_xml->{Video}->{parentIndex};
        $tmp_item->{episode} = $vid_xml->{Video}->{index};
        $tmp_item->{type}    = "tv";
        # Add the item to the cache
        $plex_cache->{$tmp_id} = $tmp_item;
        undef($tmp_item);
        # Return the item
        return $plex_cache->{$tmp_id}
    }

    # Is this entry a movie
    if ( $vid_xml->{Video}->{type} eq "movie" ) {
        # Movie, just the title needed
        if ( ! defined($vid_xml->{Video}->{title}) ) {
            # Title is missing for movie (strange), use the filename
            &plex_debug(2,"Item ID ".$tmp_item->{id}." is missing the title");
            $tmp_item->{title} = $vid_fname;
            # Set the HTML title
            # If the length is too large, truncate
            if ( length($tmp_item->{title}) > $plex_opts->{htmllenlimit} ) {
                # Title is too large, trim it
                $tmp_item->{htmltitle} = '<h4>'.substr($tmp_item->{title},0,($plex_opts->{htmllenlimit}-2)).
                    '..</h4><h4>&nbsp;</h4>';
            } else {
                # Title is fine, save it
                $tmp_item->{htmltitle} = '<h4>'.$tmp_item->{title}.'</h4><h4>&nbsp;</h4>';
            }
            # Store the attributes
            $tmp_item->{title}   = $vid_fname;
            $tmp_item->{imgurl}  = &plex_htmlImgURL($vid_xml);
            $tmp_item->{type}    = "movie";
            # Add the item to the cache
            $plex_cache->{$tmp_id} = $tmp_item;
            undef($tmp_item);
            # Return the item
            return $plex_cache->{$tmp_id}            
        }
        
        # Store the HTML title
        # If the length is too large, truncate
        if ( length($vid_xml->{Video}->{title}) > $plex_opts->{htmllenlimit} ) {
            # Title is too large, trim it
            $tmp_item->{htmltitle} = '<h4>'.substr($vid_xml->{Video}->{title},0,($plex_opts->{htmllenlimit}-2)).
                '..</h4><h4>&nbsp;</h4>';
        } else {
            # Title is fine, save it
            $tmp_item->{htmltitle} = '<h4>'.$vid_xml->{Video}->{title}.'</h4><h4>&nbsp;</h4>';
        }
        # Store the attributes
        $tmp_item->{title}   = $vid_xml->{Video}->{title};
        $tmp_item->{imgurl}  = &plex_htmlImgURL($vid_xml);
        $tmp_item->{type}    = "movie";
        # Add the item to the cache
        $plex_cache->{$tmp_id} = $tmp_item;
        undef($tmp_item);
        # Return the item
        return $plex_cache->{$tmp_id}
    }

    # At this point, the item type was unknown
    &plex_debug(2,"Unknown video type: ".$vid_xml->{Video}->{type});
    &plex_die("Unknown media type for ID: $tmp_id -  ".$vid_xml->{Video}->{type});

}

sub plex_mediaConnCheck {
    # Check if medialookup is enabled, and test the connection if so
    &plex_debug(3,"Called plex_mediaConnCheck");
    if ( $plex_opts->{medialookup} ) {
        my $tmp_conn = $obj_lwp->get("http://".$plex_opts->{server}.":".$plex_opts->{port}."/servers") ||
            &plex_die("Failed to perform a connection to Plex");
        # Check if the attempt was successful
        if ( ! $tmp_conn->is_success ) {
            print "- Unable to retrieve server details, disabling media lookup$NL";
            $plex_opts->{medialookup} = 0;
            $plex_opts->{servername} = $plex_opts->{server};
            return;
        }
        # Connection succeeded, import the XML so we can parse it
        my $plex_xml = $obj_xml->XMLin($tmp_conn->content) ||
            &plex_die("Failed to import server XML");
        undef($tmp_conn);
        # Check for the required server variables
        if ( ! defined($plex_xml->{Server}->{name}) ||
             ! defined($plex_xml->{Server}->{host}) ||
             ! defined($plex_xml->{Server}->{address}) ||
             ! defined($plex_xml->{Server}->{port}) ||
             ! defined($plex_xml->{Server}->{machineIdentifier}) ||
             ! defined($plex_xml->{Server}->{version}) ) {
            # Missing some details, warn and use the specified name
            # Media lookup can still take place
            print "- Missing server information, ignoring$NL";
            $plex_opts->{servername} = $plex_opts->{server};
            return;
        }
        # At this point the server variables can now be saved
        # Don't use server_address here as multiple nic's make this confusing!
        $plex_opts->{servername} = $plex_xml->{Server}->{name}." (".
            $plex_opts->{server}.")";
        $plex_opts->{server_name}    = $plex_xml->{Server}->{name};
        $plex_opts->{server_host}    = $plex_xml->{Server}->{host};
        $plex_opts->{server_address} = $plex_xml->{Server}->{address};
        $plex_opts->{server_port}    = $plex_xml->{Server}->{port};
        $plex_opts->{server_id}      = $plex_xml->{Server}->{machineIdentifier};
        $plex_opts->{server_ver}     = $plex_xml->{Server}->{version};
    } else {
        # Media lookup disabled in configuraton
        print "- Media info lookup disabled in configuration$NL";
        $plex_opts->{medialookup} = 0;
        $plex_opts->{servername}  = $plex_opts->{server};
    }
}

sub plex_parseLog() {
    # Open the passed logfile and parse usable lines
    &plex_debug(3,"Called plex_parseLog");
    my $tmp_lastdate;
    open(PLEX_LOG, $_[0]) ||
        &plex_die("Failed to open logfile for reading: ".$_[0]);
    foreach my $log_line (<PLEX_LOG>) {
        # Remove any newline character
        chomp($log_line);
        # Some vars to make the code somewhat neater
        my $t_id = 'identifier=com.plexapp.plugins.library';
        my $t_lm = 'library/metadata';
        my $t_pt = 'X-Plex-Token';
        if ( $log_line !~ /.+progress\?key=[0-9]+.+state=playing/ &&
             $log_line !~ /.+progress\?key=[0-9]+.+$t_pt=/ &&
             $log_line !~ /.+GET\ \/$t_lm\/[0-9]+\?$t_pt=.*\[[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\]/ &&
             $log_line !~ /.+GET\ \/:\/progress\?key=[0-9]+&$t_id&time=[0-9]+/ &&
             $log_line !~ /.+GET\ \/video\/:\/transcode.+ratingKey=[0-9]+/ &&
             $log_line !~ /.+GET\ \/library\/metadata\/[0-9]+\?X-Plex-Token/ &&
             $log_line !~ /.+GET\ \/video\/:\/transcode\/segmented\/start.m3u8.+library\%2fparts\%2f[0-9]+/
        ) {
            # Not interested, wrong type of log line
            next;
        }

        # Regex matched, so now check the date is within range
        # Note: We do this after the regex as it can be CPU intensive
        my $tmp_date = $log_line;
        $tmp_date =~ s/^([a-zA-Z]+)\ ([0-9]+),\ ([0-9][0-9][0-9][0-9])\ .*$/$1-$2-$3/;
        my @tmp_split = split(/-/, $tmp_date);
        if ( scalar(@tmp_split) != 3 ) {
            &plex_die("Failed to split date line: ".$log_line);
        }
        undef($tmp_date);
        # Store the date
        my $tmp_ldate;
        $tmp_ldate->{year}  = $tmp_split[2];
        $tmp_ldate->{month} = sprintf("%02d", Decode_Month($tmp_split[0],1));
        $tmp_ldate->{day}   = sprintf("%02d", $tmp_split[1]);
        undef(@tmp_split);
        # Check if it matches a previously stored date (saves calculating the delta)
        if ( defined($tmp_lastdate) ) {
            # A date has already been saved, compare
            if ( $tmp_ldate->{day}   eq $tmp_lastdate->{day} && 
                 $tmp_ldate->{month} eq $tmp_lastdate->{month} &&
                 $tmp_ldate->{year}  eq $tmp_lastdate->{year} ) {
                # Stored entry is a match, was it valid
                if ( ! $tmp_lastdate->{valid} ) {
                    # Date wasn't valid, skip it
                    next;
                }
            } else {
                # This is a different date entry, check it
                $tmp_lastdate = $tmp_ldate;
                if ( &plex_dateProcess($tmp_ldate) ) {
                    # Date is valid
                    $tmp_lastdate->{valid} = 1;
                } else {
                    # This date isn't valid
                    $tmp_lastdate->{valid} = 0;
                    next;
                }
            }
        } else {
            # No date previously saved, check if this one is valid
            if ( ! &plex_dateProcess($tmp_ldate) ) {
                # Date was out of range, ignore
                $tmp_lastdate = $tmp_ldate;
                $tmp_lastdate->{valid} = 0;
                next;
            }
        }

        # At this point, the line is the right type and within the date range
        # Regex matched, check if it was just a media lookup (needed for 0.9.6.1)
        if ( $log_line =~ /.+GET\ \/library\/metadata\/[0-9]+\?X-Plex-Token/ ) {
            # This is just a media lookup entry, but we need the file part ID from it
            my $media_id = $log_line;
            $media_id =~ s/^(.+\/library\/metadata\/)([0-9]+)(.+)$/$2/;
            # Check the media entry was correctly parsed
            if ( $media_id eq "" || $media_id =~ /[^0-9]/ ) {
                # Incorrect parse
                &plex_die("Failed to parse the log line: ".$log_line." - '".$media_id."'");
            }
            # Lookup the part ID for it
            my $tmp_item = &plex_itemLookup($media_id);
            if ( ! defined($tmp_item->{part_id}) ) {
                # For some reason the part id wasnt found, ignore it here
                next;
            }
            # Save the item into the hash (needed for 0.9.6.1 remote devices)
            $plex_parts->{$tmp_item->{part_id}} = $media_id;
            next;
        }

        # Right type of line, grab the Date, Media Key, IP address
        my $tmp_line = $log_line;
        if ( $tmp_line =~ /GET\ \/library\/metadata\// ) {
            if ( $tmp_line =~ /progress/ ) {
                $tmp_line =~ s/^[a-zA-Z]+\ [0-9]+,\ [0-9]+.+GET\ \/:\/progress\?key=([0-9]+).*\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\].*$/$1|$2/;
                &plex_debug(2,"Type 1 Line Match: $tmp_line");
            } else {
                $tmp_line =~ s/^[a-zA-Z]+\ [0-9]+,\ [0-9]+.+GET\ \/library\/metadata\/([0-9]+).*\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\].*$/$1|$2/;
                &plex_debug(2,"Type 2 Line Match: $tmp_line");
            }
        } elsif ( $tmp_line =~ /X-Plex-Client-Platform/ ) {
            # Plex 0.9.6 - new URL format
            &plex_debug(2,"Type 3 Line Match: $tmp_line");
            if ( $tmp_line =~ /\[[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+\]/ ) {
                # Port number is present
	        $tmp_line =~ s/^[a-zA-Z]+\ [0-9]+,\ [0-9]+.+\?key=([0-9]+)\&.*\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):[0-9]+\].*$/$1|$2/;
            } else {
                # No port number
                $tmp_line =~ s/^[a-zA-Z]+\ [0-9]+,\ [0-9]+.+\?key=([0-9]+)\&.*\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\].*$/$1|$2/;
            }
        } elsif ( $tmp_line =~ /transcode\/segmented\/start\.m3u.+ratingKey/ ) {
            # Mobile device, transcoding session, use the ratingKey
            &plex_debug(2,"Type 5 Line Match: $tmp_line");
            if ( $tmp_line =~ /\[[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+\]/ ) {
                $tmp_line =~ s/^[a-zA-Z]+\ [0-9]+,\ [0-9]+.+\&ratingKey=([0-9]+)\&.+\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):[0-9]+\].*$/$1|$2/;
            } else {
                $tmp_line =~ s/^[a-zA-Z]+\ [0-9]+,\ [0-9]+.+\&ratingKey=([0-9]+)\&.+\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\].*$/$1|$2/;
            }
        } elsif ( $tmp_line =~ /.+GET\ \/video\/:\/transcode\/segmented\/start.m3u8.+library\%2fparts\%2f[0-9]+/ ) {
            # Plex 0.9.6.1 - yet another new URL format
            &plex_debug(2, "Type 6 Line Match: $tmp_line");
            if ( $tmp_line =~ /\[[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+\]/ ) {
                 $tmp_line =~ s/^.+%2flibrary%2fparts%2f([0-9]+)%2f.+\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):[0-9]+\].*$/$1|$2/;
            } else {
                 $tmp_line =~ s/^.+%2flibrary%2fparts%2f([0-9]+)%2f.+\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\].*$/$1|$2/;
            }
            # Type 6 lines pass the part, not the media ID, so we have to check the part cache
            my ($tmp_part, $tmp_ip) = split(/\|/, $tmp_line);
            if ( $tmp_part =~ /[^0-9]/ ) {
                &plex_die("Invalid characters found after line split: $tmp_part");
            }
            if ( ! defined($tmp_ip) ) {
                &plex_die("Failed to split the IP address from the line: $tmp_line");
            }
            if ( defined($plex_parts->{$tmp_part}) ) {
                # We have a match, create a new line so we can drop through to the rest of the code
                $tmp_line = $plex_parts->{$tmp_part}."|".$tmp_ip;
            } else {
                # No entry, and no way to lookup, set the media ID to zero
                $tmp_line = "0|".$tmp_ip;
            }
        } else {
            $tmp_line =~ s/^[a-zA-Z]+\ [0-9]+,\ [0-9]+.+[\?\&]key=([0-9]+).+\[([0-9\.]+)\].+$/$1|$2/;
            # Plex 0.9.6 - new URL format
            &plex_debug(2,"Type 4 Line Match: $tmp_line");
            if ( $tmp_line =~ /\[[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+\]/ ) {
                $tmp_line =~ s/^[a-zA-Z]+\ [0-9]+,\ [0-9]+.+GET\ \/:\/progress\?key=([0-9]+).*\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):[0-9]+\].*$/$1|$2/;
            } else {
                $tmp_line =~ s/^[a-zA-Z]+\ [0-9]+,\ [0-9]+.+GET\ \/:\/progress\?key=([0-9]+).*\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\].*$/$1|$2/;
            }
        }
        # Split the new line to pull out the date/video id/ip
        my ($tmp_key, $tmp_ip) = split(/\|/, $tmp_line);
        if ( ! defined($tmp_key) || ! defined($tmp_ip) ) {
            &plex_regexError($log_line, $tmp_line);
        } elsif ( $tmp_key eq "" || $tmp_ip eq "" ) {
            &plex_regexError($log_line, $tmp_line);
        }
        # Construct tmp_date for simplicity
        $tmp_date = $tmp_ldate->{year}.'-'.$tmp_ldate->{month}.'-'.$tmp_ldate->{day};
        # Remove any potential newline characters from the key/date
        chomp($tmp_key); chomp($tmp_ip);
        # Check that both the key and ip are populated (not zero length)
        ( length($tmp_key) && length($tmp_ip) ) ||
            &plex_die("Failed to retrieve required variables from line: $log_line");
        # Store this entry in the plex_dates hash
        $plex_dates->{$tmp_date}->{$tmp_ip}->{$tmp_key} = 1;
    }
    # Close the file handle
    close(PLEX_LOG);
}

sub plex_regexError {
    # A line from the log didnt process properly, fatal
    &plex_debug(3,"Called plex_regexError");
    print "ERROR: Failed to parse the following log line$NL";
    print "ERROR: '".$_[0]."'$NL";
    print "ERROR: '".$_[1]."'$NL";
    print "Please email the above error lines to stu\@lifeofstu.com$NL";
    print "Note: Change the IP to 111.222.333.444 and scramble your Plex Token for security$NL";
    exit 1;
}

sub plex_variableCheck {
    &plex_debug(3,"Called plex_variableCheck");
    # Check for the required core variables
    foreach my $tmp_var (qw(debug server port dnslookup medialookup warnmissing htmlout)) {
        ( defined($plex_opts->{$tmp_var}) ) ||
            &plex_die("The '$tmp_var' configuration option was missing, aborting");
        ( length($plex_opts->{$tmp_var}) ) ||
            &plex_die("The '$tmp_var' configuration option was empty, aborting");
    }
    # Check for the optional variables (conditional)
    if ( defined($plex_opts->{emailserver}) ) {
        ( length($plex_opts->{emailserver}) ) ||
            &plex_die("The 'emailserver' configuration option was empty, aborting");
        ( defined($plex_opts->{emailsender}) ) ||
            &plex_die("The 'emailsender' configuration option was missing, aborting");
        ( defined($plex_opts->{emailreceiver}) ) ||
            &plex_die("The 'emailreceiver' configuration option was missing, aborting");
        ( length($plex_opts->{emailsender}) ) ||
            &plex_die("The 'emailsender' configuration option was empty, aborting");
        ( length($plex_opts->{emailreceiver}) ) ||
            &plex_die("The 'emailreceiver' configuration option was empty, aborting");
    }
    if ( defined($plex_opts->{emailuser}) ) {
        ( length($plex_opts->{emailuser}) ) ||
            &plex_die("The 'emailuser' configuration option was empty, aborting");
        ( defined($plex_opts->{emailpass}) ) ||
            &plex_die("The 'emailpass' configuration option was missing, aborting");
        ( length($plex_opts->{emailpass}) ) ||
            &plex_die("The 'emailpass' configuration option was empty, aborting");
    }
    if ( $plex_opts->{htmlout} ) {
        ( defined($plex_opts->{htmloutfile}) ) ||
            &ple_die("The 'htmloutfile' configuration option was missing, aborting");
        ( length($plex_opts->{htmloutfile}) ) ||
            &plex_die("The 'htmloutfile' configuration option was empty, aborting");
        ( defined($plex_opts->{htmlcss}) ) ||
            &plex_die("The 'htmlcss' configuration option was missing, aborting");
        ( length($plex_opts->{htmlcss}) ) ||
            &plex_die("The 'htmlcss' configuration option was empty, aborting");
        ( defined($plex_opts->{htmldate}) ) ||
            &plex_die("The 'htmldate' configuration option was missing, aborting");
        ( length($plex_opts->{htmldate}) ) ||
            &plex_die("The 'htmldate' configuration option was missing, aborting");
    }
}

sub plex_xmlOut {
    # Generate XML from the plex_dates entry and write it to a file
    &plex_debug(3,"Called plex_xmlOut");
    print "- Writing XML data to file: ".$plex_opts->{xmlfile}."$NL";
    my $tmp_xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>$NL";
    $tmp_xml .= "<dates>$NL";
    foreach my $xml_date ( sort keys %{$plex_dates} ) {
        $tmp_xml .= "  <date name=\"$xml_date\">$NL";
        foreach my $xml_client ( sort keys %{$plex_dates->{$xml_date}} ) {
            $tmp_xml .= "    <client name=\"$xml_client\">$NL";
            foreach my $xml_viewed ( sort keys %{$plex_dates->{$xml_date}->{$xml_client}} ) {
                $tmp_xml .= "      <item ";
                foreach my $item_key ( sort keys %{$plex_cache->{$xml_viewed}} ) {
                    if ( $item_key eq "htmltitle" ) {
                        # Skip this tag as it breaks XML
                        next;
                    }
                    $tmp_xml .= $item_key."=\"".$plex_cache->{$xml_viewed}->{$item_key}."\" ";
                }
                $tmp_xml .= "/>$NL";
            }
            $tmp_xml .= "    </client>$NL";
        }
        $tmp_xml .= "  </date>$NL";
    }
    $tmp_xml .= "</dates>$NL";

    # Write the XML to the specified file
    open (XMLOUT, '>'.$plex_opts->{xmlfile}) ||
        &plex_die("Unable to open XML file for writing");
        print XMLOUT $tmp_xml;
    close (XMLOUT);
    undef($tmp_xml);
}

## Generic subroutines that can sit at the bottom

sub plex_debug() {
    # Depending on debugging level, print the passed message
    ( $_[0] <= $plex_opts->{debug} ) && print "DEBUG: [".$_[0]."] - ".$_[1]."$NL";
}

sub plex_die() {
    # Print an error message then exit with error code 1
    print "ERROR: $_[0]$NL";
    exit 1;
}

sub plex_showHelp {
    # Show the help screen and then exit
    my $sname = basename($0);
    print <<EOF
Usage
-----

$sname [option1] [option2] ..

   -c "config_name"             - Use a non-default configuration file
   -d "2012-02-01"              - Will give you the report for specified date
   -h                           - This screen
   -r "2012-02-01" "2012-02-29" - Will give you the report for February 2012
   -R "2012-02-01" "2012-02-29" - Will give you separate HTML reports for February 2012
   -v                           - Increase verbosity/debugging (use it multiple times if needed)
   -w "outfile.htm" "csspath"   - Write a HTML report to the file specified
                                - CSS path is relative to your document root (e.g. css/style.css)
   -x "output file"             - Write the XML data for all results to the specified file

EOF
}
