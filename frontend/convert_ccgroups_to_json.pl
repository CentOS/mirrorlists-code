#!/usr/bin/perl -w
use strict;
use geo_cc;

print "{";

my $flag = 0;
foreach my $cc (sort (get_all_ccs())) {
	my @cclist = grep(!/c\d/, get_cc_list($cc));
#	shift @cclist; # get rid of the first entry, which is the same as $cc
#	next if ! scalar(@cclist);
	if($flag++) {
		print ",";
	}
	print "\n\"$cc\":[\"" . join("\",\"", @cclist) . "\"]";
}
print "\n}\n";
