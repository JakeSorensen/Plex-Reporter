<?php
    /* These are default variables, make changes to the plex_settings.php file */
    // Your server name (displayed on the webpage)
    $servername = "My Plex Server";
    // Folder where your dated plex reports are
    $reportdir  = "reports";
    // Prefix for any plex reports (needs to match your plex-reporter.cfg)
    $reportpfx  = "plex";
    // Sort order for dates (0 = asc, 1 = desc)
    $sortorder = 1;

    /* ------------------------------
       CHANGE NOTHING BELOW THIS LINE
       ------------------------------ */

    // Variable for holding HTML to be output later on
    $htmlout = "";
    // Variable for successful logfile count
    $logfiles = 0;
    // Indentation variable for HTML formatting
    $indent = "                        ";

    // Load the settings file if it exists
    if ( is_file("plex_settings.php") ) {
        require_once "plex_settings.php";
    }

    // Is this running on Windows (if it is, can't use tail)
    if ( strtoupper(substr(PHP_OS, 0, 3)) == 'WIN' ) {
        $dotail = 0;
    } else {
        $dotail = 1;
    }

    // Check the specified directory is valid
    if ( ! is_dir($reportdir) ) {
        $htmlout = "<li><h3>ERROR: The specified report directory does not exist</h3></li>";
        exit;
    }

    // Scan the directory for all files/folders
    $dirlist = scandir($reportdir,$sortorder);
    if ( ! $dirlist ) {
        $htmlout = "<li><h3>ERROR: Unable to read file list form report directory</h3></li>\n";
        exit;
    }

    // Loop through each entry and process it
    foreach ($dirlist as $entry) {
        // Is the entry a file
        if ( ! is_file("$reportdir/$entry") ) {
            continue;
        }
        // Does the entry starts with a '.'
        if ( preg_match('/^\./', $entry) ) {
            continue;
        }
        // Does the file match the naming convention (plex-YYYY-MM-DD.htm(l))
        if ( ! preg_match('/^'.$reportpfx.'-[1-2][0-9][0-9][0-9]-'.
              '[0-1][0-9]-[0-3][0-9]\.htm$/i', $entry) ) {
            continue;
        }

        // Successful entry, increment the counter
        $logfiles++;

        // Split the filename to get just the date
        preg_match('/[1-2][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]/i', $entry, $logdate);
        if ( ! $logdate ) {
            // Something went wrong
            $htmlout .= $indent."<li class='index_item'>\n";
            $htmlout .= $indent."    <a href='$reportdir/$entry'>Unknown</a><br />Unknown\n";
            $htmlout .= $indent."</li>\n";
            continue;
        }

        // If running on something other than Windows, try to read the last line of the file
        if ( $dotail ) {
            $lastline = shell_exec("tail -n 1 '$reportdir/$entry' 2>/dev/null");
            if ( $lastline != "" ) {
                // Check for the plex-reporter tag at the end
                preg_match('/plex-clients:[0-9]+:/', $lastline, $magictag);
                if ( $magictag ) {
                    // Magic tag found, parse the number of clients
                    $exp_clients = explode(':', $magictag[0]);
                    $num_clients = $exp_clients[1].' client(s)';
                } else {
                    // No magic tag, just set the empty variable
                    $num_clients = 'Unknown';
                }
            } else {
                // Empty line retrieved
                $num_clients = 'Unknown';
            }
        } else {
            // Tail not enabled
            $num_clients = 'Unknown';
        }

        // Add the HTML entry for the file
        $htmlout .= $indent."<li class='index_item'>\n";
        $htmlout .= $indent."    <a href='$reportdir/$entry'>".date("M jS, Y", strtotime($logdate[0]))."</a><br />".$num_clients."\n";
        $htmlout .= $indent."</li>\n";
    }

    // Finally, check if any suitable files were found
    if ( ! $logfiles ) {
        $htmlout = "<li><h3>No reports were found</h3></li>\n";
    }

?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
   "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en">
<head>
    <title>Plex Reporter - Index</title>
    <meta http-equiv="content-type" content="text/html;charset=utf-8" />
    <meta name="viewport" content="initial-scale=1,minimum-scale=1,maximum-scale=1" />
    <link rel="shortcut icon" href="favicon.ico" />
    <link rel="stylesheet" href="css/style.css" type="text/css" />
</head>
<body>
    <div id="container">
        <div id="header">
            <h1><span>Plex Reporter</span></h1>
        </div>

        <div id="main">
            <div id="section-header">
                <div>
                    <h2><?php echo $servername ?></h2>
                </div>

            </div>

            <div id="item-list">
                <div id="index-list-item">
                    <h3>Client/Device Reports</h3>
                    <ul style="list-style-type:none">
<?php echo $htmlout ?>
                    </ul>
                </div>
            </div>
        </div>

        <div id="footer">
        </div>

    </div>
</body>
</html>
