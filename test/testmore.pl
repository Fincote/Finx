#!/usr/bin/perl -w

use strict;

print "Checking for Test::More...\n";
if (eval {require Test::More} ) {
	exit 0;
} else {
	print "\nBail out!  Can't find Test::More\n";
	print STDERR <<ERROR;

$@

This is normal if you are bootstrapping finx, or upgrading to
finx 0.18.0 for the first time.  Otherwise, you need to install 
the test-simple-pm package or perl >= v5.8.0.

ERROR
	exit 1;
}
