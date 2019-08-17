#!/usr/bin/perl -w

use strict;
use DBI;
use LWP::UserAgent;
use List::Util qw(shuffle);
use Config::Simple;
use geo_cc; # for country subdivisions only

my $outputdir = "/tmp/centos-mirrorlists";

# if writable, write to /home
if( -W "/home/centos-mirrorlists" ) {
	$outputdir = "/home/centos-mirrorlists";
}

my $db;

my $debug = 2; #higher no = more verbose - 0 - info - > stdout as well, 1 - normal log, >2 - debug 

my @centos_codes = ("c1","c2","c3");
my $altarch_where = "";
my $centos_or_altarch = "centos";
my $max_http_errors = 3;	# this many HTTP errors => ignore mirror for the rest of the run
my %timeoutmirrors = ( );	# mirror IDs (incl. protocol) that time out when connecting (permanent errors)
my $timeoutmatch = "timeout|service not known|::(SSL|https)|route to host|Address family|unreachable|Connection refused|503 Service|500 (Internal|Can|Status)|^(30\\d|405) ";
my $starttime = time();
my $max_mirror_cache_days = 3;
my $max_master_cache_days = 7;
my $max_num_of_mirrors = 30;	# no need to list ALL the mirrors in a country

my %weekday = ( 0 => "Sun", 1 => "Mon", 2 => "Tue", 3 => "Wed", 4 => "Thu", 5 => "Fri", 6 => "Sat");
my %month = ( 0 => "Jan", 1 => "Feb", 2 => "Mar", 3 => "Apr", 4 => "May", 5 => "Jun",
       6 => "Jul", 7 => "Aug", 8 => "Sep", 9 => "Oct", 10 => "Nov", 11 => "Dec");

my ($release, $altarch, $archlist) = @ARGV;
if(!defined($release) || $release !~ /^[6789]\.[0-9.]+$/ 
		|| !defined($altarch) || $altarch !~ /^(centos|altarch)$/
		|| !defined($archlist) ) {
	print("Usage: $0 centosversion (centos|altarch) arch1,arch2,...\n");
	exit;
}

if($altarch eq "altarch") {
	$altarch_where = "AND altarch='yes'";
	$centos_or_altarch = "altarch";
	$altarch = 1;
} else {
	$altarch = 0;
}

my @arches = split(",", $archlist);

system("mkdir $outputdir/logs -p");

my $start = `date +%Y%m%d-%H%M`;
my $logfile = "$outputdir/logs/isolists-${centos_or_altarch}-$release-$start";

open (LOG, ">$logfile" ) || warn ("cannot open $logfile");


# read in the database config
my $cfg;
if( -r $ENV{"HOME"} . "/centos-ml.cfg" ) {
	$cfg = new Config::Simple($ENV{"HOME"} . "/centos-ml.cfg");
} elsif( -r "/etc/centos-ml.cfg" ) {
	$cfg = new Config::Simple("/etc/centos-ml.cfg");
} else {
	die("Can't read centos-ml.cfg");
}

my $database = $cfg->param('database');
my $dbhost = $cfg->param('dbhost');
my $dbuser = $cfg->param('dbuser');
my $dbpass = $cfg->param('dbpass');

unless ( $db = DBI->connect("DBI:mysql:database=$database;host=$dbhost",$dbuser,$dbpass,{RaiseError => 0, PrintError => 0})) {
	logprint(0,"Unable to connect to db " . $DBI::errstr . "\n");
	die;
}

############### delete old cached data ############

$db->do("DELETE FROM valid_iso_mirrors WHERE checked < date_sub(now(), interval $max_mirror_cache_days day);");
$db->do("DELETE FROM master_iso_fileinfo WHERE checked < date_sub(now(), interval $max_master_cache_days day);");

############### get master server ############

my $masterhttp = "http://master-admin.centos.org/";

my %checkedonce = ( );  # mirror IDs (incl. protocol) that were checked at least once in this session
my %http_errors = ( );	# keep track of how many HTTP errors (30x, 403, 404) we got from this mirror (mirror_id + protocol)

foreach my $arch (shuffle @arches) {
	my %iso_info = ();	# hash of master file info by iso_id
	my %iso_filenames = ();	# hash of filenames by iso_id
	my $res;
	my $ref;

	############## get master iso lists ##########
			
	# read the master sha256sum file
	my $filetype = "isos";
	my $checksumfilename = "sha256sum.txt";
	if($release !~ /^[67]/) {
		if($arch eq "armhfp") {
			$filetype = "images";
		}
		$checksumfilename = "CHECKSUM";
	}
	my $isourl = "$release/$filetype/$arch/";
	my $isosha256url = "${isourl}${checksumfilename}";
		
	my $sha256list = get_isolist("${masterhttp}${centos_or_altarch}/$isosha256url");

	if($debug == 0){
		logprint (0, "$arch\n");
	} else {
		logprint (0, "\n$arch\n$sha256list\n");
	}	

	if($sha256list) {
		foreach my $iso (split ('\n', $sha256list)) {
			next unless $iso =~ /centos.*\.(iso|raw\.xz)/i;
			my ($sha256, $iso) = split(' ', $iso);
				
			# now get the file sizes and times
			my $finfo = get_fileinfo("${masterhttp}${centos_or_altarch}/${isourl}${iso}");
			logprint (2, "$iso $finfo\n");
			print "$iso $finfo\n";

			next if $finfo !~ /#_#/;

			# make sure the .iso is mentioned in the isos table
			$db->do("INSERT IGNORE INTO isos (filename, arch, altarch)
				VALUES ('$iso', '$arch', $altarch);");

			# find out iso_id
			$res = $db->prepare("SELECT iso_id FROM isos
				WHERE filename='$iso' AND arch='$arch' AND altarch=$altarch;");
			$res->execute();
			$ref = $res->fetchrow_hashref();
			my $iso_id = $$ref{"iso_id"};
			$iso_info{$iso_id} = $finfo;
			$iso_filenames{$iso_id} = $iso;

			# see if the value has changed since the last time
			$res = $db->prepare("SELECT value FROM master_iso_fileinfo
				WHERE iso_id=$iso_id AND version='$release';");
			$res->execute();
			my $ref = $res->fetchrow_hashref();
			my $oldvalue = $$ref{"value"};
			$oldvalue = "" unless defined($oldvalue);

			if($finfo ne $oldvalue) {
				logprint (2, "$iso new value $finfo, old value $oldvalue\n");
				# information changed, invalidate old cached mirror data
				$db->do("DELETE from valid_iso_mirrors WHERE iso_id=$iso_id AND version='$release';");
			}
			$db->do("REPLACE INTO master_iso_fileinfo (iso_id, version, value, checked)
				VALUES ($iso_id, '$release', '$finfo', now());");
		}
	} else {
		# use cached data if available
		$res = $db->prepare("SELECT i.iso_id, filename, value FROM master_iso_fileinfo m, isos i
			WHERE m.iso_id=i.iso_id AND i.arch='$arch' AND i.altarch=$altarch AND m.version='$release';");
		$res->execute();
		while($ref = $res->fetchrow_hashref()) {
			my $iso_id = $$ref{"iso_id"};
			my $filename = $$ref{"filename"};
			my $value = $$ref{"value"};
			$iso_info{$iso_id} = $value;
			$iso_filenames{$iso_id} = $filename;
			logprint (2, "$filename cached value $value\n");
		}
	}
	logprint (2, "\n");
	print "\n";

	# if sha256sums are unavailable, skip this arch
	next if scalar(keys %iso_info) == 0;

	# fetch the list of previously valid mirrors
	# iso_id=0 is for caching the directory index status
	my %valid_mirrors = ( );	# mirror IDs (incl. protocol and iso_id) that were previously found to be valid
	$res = $db->prepare("SELECT v.mirror_id, v.proto, i.iso_id FROM valid_iso_mirrors v, isos i
		WHERE v.iso_id=i.iso_id AND v.version='$release' AND i.arch='$arch' AND i.altarch=$altarch AND v.iso_id>0
		UNION
		SELECT v.mirror_id, v.proto, 0 FROM valid_iso_mirrors v
		WHERE v.version='$release' AND v.iso_id=0");
	$res->execute();

	while(my @l = $res->fetchrow_array()) {
		$valid_mirrors{"${l[0]} ${l[1]} ${l[2]}"} = 1; # sets "mirror_id http iso_id" = 1
	}

	my @allccs = ( );

	# intentionally not limited to active mirrors to help clean up stale data
	$res = $db->prepare("SELECT DISTINCT cc FROM mirrors WHERE cc>'';");
	$res->execute();
	while($ref = $res->fetchrow_hashref()) {
		push(@allccs, $$ref{"cc"});
	}

	system("mkdir $outputdir/ipv4/${centos_or_altarch}/$release/$filetype/$arch -p");

	foreach my $cc (shuffle ("%", @allccs, @centos_codes, keys %country_subregions)) {
		logprint (2, "cc: $cc\n");

		################# get status of mirrors ##########

		my $okmirrors = "";
		my %okisos;
		my $okmirrorcount = 0;
		my $save_cc = $cc;
		if($cc eq "%") {
			$save_cc = "fallback";
		}

		my $commonqueryparams = "status NOT IN ('Dead', 'Disabled', 'Gone') AND state NOT IN ('timeout') AND use_in_mirrorlists='yes'";
		my $columns = "mirror_id, ";
		if($altarch) {
			$columns .= "altarch_http, altarch_https";
		} else {
			$columns .= "http, https";
		}

		#is this a centos code ??

		if(grep(/^$cc$/i, @centos_codes)) {
			$res = $db->prepare("SELECT $columns FROM mirrors WHERE type IN ('Direct', 'Indirect') AND status = 'Active' 
				AND centos_code = '$cc' AND $commonqueryparams $altarch_where ORDER BY RAND();");
		} elsif($cc =~ /^[A-Z][A-Z]$/) {
			# US/CA state/province
			my $fallbackcountry = $country_subregions{$cc};

			$res = $db->prepare("SELECT $columns FROM mirrors WHERE type IN ('Direct', 'Indirect') AND status = 'Active'
				AND cc='$fallbackcountry' AND `location-minor`='$cc' AND $commonqueryparams $altarch_where ORDER BY RAND();");
			$save_cc = "${fallbackcountry}-${cc}"; # us-TX
		} else {
			$res = $db->prepare("SELECT $columns FROM mirrors WHERE type IN ('Direct', 'Indirect') AND status = 'Active'
				AND cc LIKE '$cc' AND $commonqueryparams $altarch_where ORDER BY RAND();");
		}
		$res->execute();

		while (my $mirref = $res->fetchrow_hashref) {

			my %mirror = %$mirref;
			my $mirror_id = $mirror{"mirror_id"};

			my $url = "";
			my $proto = "http";
			my $base = "";

			if($altarch) {
				if ($mirror{"altarch_http"}) {
					$base = $mirror{"altarch_http"};
					$url = $base.$isourl;
				}
			} else {
				if ($mirror{"http"}) {
					$base = $mirror{"http"};
					$url = $base.$isourl;
				}
			}

			$http_errors{"$mirror_id $proto"} = 0 unless defined($http_errors{"$mirror_id $proto"});
			next if $http_errors{"$mirror_id $proto"} >= $max_http_errors;
			next if defined($timeoutmirrors{"$mirror_id $proto"});
			next unless $url;

			# now we have to check the individual files ...
			my $onebad = 0;		# at least one failure from this mirror for this arch

			foreach my $iso_id (shuffle keys(%iso_info)) {
				last if $http_errors{"$mirror_id $proto"} >= $max_http_errors;
				my $iso = $iso_filenames{$iso_id};
				logprint (2, "Check $url$iso");

				if(defined($checkedonce{"$mirror_id $proto"}) && defined($valid_mirrors{"$mirror_id $proto $iso_id"})) {
					logprint (2," - good from cache\n");
					$okisos{$iso} .= "${url}${iso}\n";
					next;
				}

				my $finfo = get_fileinfo($url.$iso);

				if($finfo =~ /$timeoutmatch/ ) {
					logprint(2, " - $finfo\n");
					logprint(0, "$base going in timeout mirrors\n");
					$timeoutmirrors{"$mirror_id $proto"} = 1;
					$onebad = 1;
					last;
				}

				if($finfo eq $iso_info{$iso_id}) {
					# this is a good iso on the mirror !!
					$db->do("REPLACE INTO valid_iso_mirrors (iso_id, version, mirror_id, proto, checked)
						VALUES ($iso_id, '$release', $mirror_id, '$proto', now());");
					logprint (2," - good\n");
					$okisos{$iso} .= "${url}${iso}\n";
					$checkedonce{"$mirror_id $proto"} = 1;
					$valid_mirrors{"$mirror_id $proto $iso_id"} = 1;
				} elsif($finfo =~ /#_#/) {
					# reachable but contents differ from expected
					logprint (2," - bad - $finfo\n");
					$onebad = 1;

					# clear any possible valid_iso_mirrors entries for all protocols
					my $somethingfound = 0;
					foreach my $key (grep /^$mirror_id .+ $iso_id$/, keys %valid_mirrors) {
						delete($valid_mirrors{$key});
						if(++$somethingfound == 1) {
							$db->do("DELETE FROM valid_iso_mirrors WHERE iso_id=$iso_id AND version='$release' AND mirror_id=$mirror_id;");
						}
					}
				} else {
					# unreachable or other unspecified error
					logprint (2," - unreachable - $finfo\n");
					$onebad = 1;
					if(defined($valid_mirrors{"$mirror_id $proto $iso_id"})) {
						# we thought the mirror using this protocol was valid and reachable, but apparently it isn't
						delete($valid_mirrors{"$mirror_id $proto $iso_id"});
						$db->do("DELETE FROM valid_iso_mirrors WHERE iso_id=$iso_id AND version='$release' AND mirror_id=$mirror_id AND proto='$proto';");
					}
				}

				if($finfo =~ /^(40[34]|30\d) /) {
					if(++$http_errors{"$mirror_id $proto"} >= $max_http_errors) {
						logprint(1, "$base has had too many HTTP errors, not testing again\n");
						last;
					}
				}
			}

			if(!$onebad) {
				# mirror has all .isos, check that dirindex is enabled
				# but only if the result hasn't already been stored into cache
				if(!defined($valid_mirrors{"$mirror_id $proto 0"})) {
					my $ua = LWP::UserAgent->new;
					$ua->timeout(20);
					$ua->agent('CentOS-makeisolists/9q ');
					$ua->max_redirect(0);
					my $req = HTTP::Request->new(GET => "$url");

					$req->header('Accept' => 'text/html');

					# send request
					my $lwpres = $ua->request($req);

					if ($lwpres->is_success) {
						# this used to search for CentOS- but then I found out that one mirror uses JS for creating the list
						if ($lwpres->content =~ /href/i) {
							$valid_mirrors{"$mirror_id $proto 0"} = 1;
							$db->do("REPLACE INTO valid_iso_mirrors (iso_id, version, mirror_id, proto, checked)
								VALUES (0, '$release', $mirror_id, '$proto', now());");
						} else {
							logprint (1, "$url did not have a directory listing\n");
						}
					} else {
						logprint (1, "$url error - " . $lwpres->status_line . "\n");
					}
				}
				if(defined($valid_mirrors{"$mirror_id $proto 0"})) {
					logprint (2, "adding $url\n");
					$okmirrors .= "$url\n";
					last if ++$okmirrorcount>=$max_num_of_mirrors;
				}
			}
		}		

		logprint (2, "\n");
		foreach my $iso (keys(%okisos)) {
			logprint (2, "ISO - $iso\n$okisos{$iso}\n");
		}

		unlink glob("$outputdir/ipv4/${centos_or_altarch}/$release/$filetype/$arch/*.$save_cc");

		foreach my $iso (keys(%okisos)) {
			my $outfile = "$outputdir/ipv4/${centos_or_altarch}/$release/$filetype/$arch/$iso.$save_cc";

			if (open (OUT, ">$outfile")) {
				print OUT "$okisos{$iso}";
				close(OUT);
			} else {
				logprint(0, "Could not open $outfile for writing\n");
				# but carry on ...
			}
		}
				
		my $isofile = "$outputdir/ipv4/${centos_or_altarch}/$release/$filetype/$arch/iso.$save_cc";
				
		if($okmirrors) {
			if (open (OUT, ">$isofile")) {
				print OUT "$okmirrors";
				close(OUT);
			} else {
				logprint(0,"Could not open $isofile for writing\n");
				# but carry on ...
			}
		}
	}
}

logprint(2, "\nFinished, took " . int((time()-$starttime)/60) . " min " . ((time()-$starttime) % 60) . " sec\n");
close(LOG);


## get_isolist - read a file and return list of sha256sum/filename

sub get_isolist {
	my $url = shift;

	my $ua = LWP::UserAgent->new;
	$ua->default_header('Accept-Encoding' => 'nozip');
	$ua->timeout(15);
	my $req = HTTP::Request->new(GET => "$url");
	$req->header('Accept' => 'text/html');

	# send request
	my $lwpres = $ua->request($req);

	if ($lwpres->is_success) {
		my $isolist = $lwpres->content;
		if($url =~ /sha256sum.txt$/) {
			return $isolist;
		} else {
			# convert CHECKSUM file format to regular sha256sum file format
			my $retval = "";
			foreach my $row (split '\n', $isolist) {
				if ($row =~ /^SHA256 \((.+?)\) = ([0-9a-f]+)/) {
					$retval .= "$2  $1\n";
				}
			}
			return $retval;
		}
	} else {
		logprint(0,"Empty isolist $url\n");
		return 0;
	}
}

## get_fileinfo - use HEAD to get file information - returns string with size#datetime

sub get_fileinfo {
	my $url = shift;

	my $ua = LWP::UserAgent->new;
	$ua->timeout(10);
	$ua->agent('CentOS-makeisolists/9q ');
	$ua->max_redirect(0);
	my $res = '';
	my $length = 0;
	my $date = '';

	my $req = HTTP::Request->new(HEAD => "$url");

	$req->header('Accept' => 'text/html');

	# send request
	my $lwpres = $ua->request($req);

	if ($lwpres->is_success) {
		my $head = \%{$lwpres->headers};

		while(my($key,$value) = each(%$head)) {

			if ($key eq 'content-length') {
				$length = $value;
			}	
			if ($key eq 'last-modified') {
				$date = $value;
			}	

		}
		$res = $length."#_#".$date;
	} else {
		print "$url error - " . $lwpres->status_line . "\n";
		$res = $lwpres->status_line;
#		print $lwpres->as_string();
	}

	return $res;
}

sub logprint {
	my ($debuglevel, @log) = @_;

	if ($debuglevel == 0){
		print @log;
	}
	if($debuglevel <= 1 || $debuglevel <= $debug) {
		print LOG @log;
	}
}
