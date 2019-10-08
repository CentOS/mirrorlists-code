#!/usr/bin/perl -w

use strict;
use DBI;
use geo_cc;
use IO::Socket::INET6;
use LWP::UserAgent;
use List::Util qw(shuffle);
use Digest::MD5 qw(md5_hex);
use Config::Simple;

my $outputdir = "/tmp/centos-mirrorlists";

# if writable, write to /home
if( -W "/home/centos-mirrorlists" ) {
	$outputdir = "/home/centos-mirrorlists";
}

my $db;
my %master_ts_cache = ( );	# timestamp cache from master for each repo_id
my $debug = 2;			# higher no = more verbose - 0 - info - > stdout as well, 1 - normal log, >2 - debug
my @centos_codes = ("c1","c2","c3");
my $altarch_where = "";
my $centos_or_altarch = "centos";
my $max_http_errors = 3;	# this many HTTP errors => ignore mirror for the rest of the run
my %timeoutmirrors = ( );	# mirror IDs (incl. protocol) that time out when connecting (permanent errors)
my $timeoutmatch = "timeout|service not known|::(SSL|https)|route to host|Address family|unreachable|Connection refused|503 Service";
my @allccs = get_all_ccs();
my $starttime = time();
my $remove_stale_mirrorlists = 1;
my $max_mirror_cache_days = 3;
my $max_master_cache_days = 7;
my @all_continents = ("af", "ap", "eu", "oc", "sa", "us");

my ($release, $altarch) = @ARGV;
if(!defined($release) || $release !~ /^[6789]\.[0-9.]+$|^8-stream/ || !defined($altarch) || $altarch !~ /^(centos|altarch)$/) {
	print("Usage: $0 centosversion (centos|altarch)\n");
	exit;
}

my $majorrelease = substr($release,0,1);
# Specific workaround for the major release int vs string issue
if($release eq "8-stream") {
	$majorrelease = "8-stream";
	print("8-stream detected so using $majorrelease for mysql query\n");
} 

if($altarch eq "altarch") {
	$altarch_where = "AND altarch='yes'";
	$centos_or_altarch = "altarch";
	$altarch = 1;
} else {
	$altarch = 0;
}

system("mkdir $outputdir/logs -p");

my $start = `date +%Y%m%d-%H%M`;
my $logfile = ">$outputdir/logs/mirrorlists-${centos_or_altarch}-$release-$start";
my $repofname="repodata/repomd.xml";

open (LOG, $logfile) || warn ("cannot open $logfile");

# used for a hack for convincing LWP to use IPv4 ONLY
my $localv4addr = qx(/sbin/ip a s | grep "inet " | grep global | head -1 | awk '{print \$2}' | cut -d/ -f1);
chomp($localv4addr);
if($localv4addr !~ /^\d+\.\d+\.\d+\.\d+$/) {
	logprint(0, "$localv4addr is not a valid IPv4 address");
	die;
}

# used for a hack for convincing LWP to use IPv6 ONLY
my $localv6addr = qx(/sbin/ip a s | grep inet6 | grep global | head -1 | awk '{print \$2}' | cut -d/ -f1);
chomp($localv6addr);
if($localv6addr !~ /^[0-9a-f]+:/) {
	logprint(0, "$localv6addr is not a valid IPv6 address");
	die;
}

# read in the database config
my $cfg;
if( -r $ENV{"HOME"} . "/centos-ml.cfg" ) {
	$cfg = new Config::Simple($ENV{"HOME"} . "/centos-ml.cfg");
} elsif( -r "/etc/mirmon/centos-ml.cfg" ) {
	$cfg = new Config::Simple("/etc/mirmon/centos-ml.cfg");
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


############### get master server ############

my $res = $db->prepare("SELECT * from mirrors WHERE name = 'centosg-admin' ");
$res->execute();
my $mastref = $res->fetchrow_hashref();
my %master = %$mastref;


############### create a json file of the repos ############

create_json();


############### delete old cached data ############

$db->do("DELETE FROM valid_mirrors WHERE checked < date_sub(now(), interval $max_mirror_cache_days day);");

if($remove_stale_mirrorlists) {
	# clean up (some) mirrorlist files for old forgotten about repos.
	# these repos haven't been available on master for some time: EOL content and previous versions that were moved to vault.
	# note: if you set enabled='no' or delete the rows before this script triggers the deletion, clean up the mirrorlist files yourself
	my $repores = $db->prepare("SELECT r.*, ts.version FROM repos r, master_timestamps ts
		WHERE r.repo_id=ts.repo_id AND enabled='yes' AND checked < date_sub(now(), interval $max_master_cache_days day)
		ORDER BY r.repo_id;");
	$repores->execute();
	while(my $reporef = $repores->fetchrow_hashref()) {
		my %repo = %$reporef;
		my ($repo_id, $repo_path, $cleanup_release, $cleanup_aa) = ( $repo{"repo_id"}, $repo{"path"}, $repo{"version"}, $repo{"altarch"} );
		my $cleanup_centos_or_altarch = "centos";
		if($cleanup_aa) {
			$cleanup_centos_or_altarch = "altarch";
		}
		my $cleandirs = "$cleanup_centos_or_altarch/$cleanup_release/$repo_path/mirrorlists";
		my $cleanpath = "$outputdir/{ipv4,ipv6}/$cleandirs";
		logprint(1, "Cleaning up old files for $repo_id from $cleandirs\n");
		unlink(glob("$cleanpath/mirrorlist.*"));

		while($cleandirs =~ m!/!) {
			rmdir("$outputdir/ipv4/$cleandirs");
			last unless rmdir("$outputdir/ipv6/$cleandirs");
                        $cleandirs =~ s!/[^/]+$!!; # chop off last path component
		}
	}
}
$db->do("DELETE FROM master_timestamps WHERE checked < date_sub(now(), interval $max_master_cache_days day);");


############### check mirrors ############

foreach my $ipver ("ipv4", "ipv6") {

	# clear out the checked once status and HTTP error counter between IPv4 and IPv6 tests
	my %checkedonce = ( );	# mirror IDs (incl. protocol) that were checked at least once in this session (cleared between IPv4/IPv6)
	my %http_errors = ( );	# keep track of how many HTTP errors (30x, 403, 404) we got from this mirror (mirror_id + protocol)
	# but we can keep timeoutmirrors -- if a mirror had problems with IPv4, it likely has problems with IPv6 as well

	# find enabled repositories
	print("doing now the mysql query with major_release='$majorrelease' and altarch=$altarch\n");
	my $repores = $db->prepare("SELECT * FROM repos
			WHERE enabled='yes' AND major_release='$majorrelease' AND altarch=$altarch
			ORDER BY rand();");
	$repores->execute();
	while(my $reporef = $repores->fetchrow_hashref()) {
		my %repo = %$reporef;
		my ($repo_id, $repo_path) = ( $repo{"repo_id"}, $repo{"path"} );

		# fetch the timestamp from database just prior to use to reduce chances of using possibly stale data
		my $tsres = $db->prepare("SELECT value FROM master_timestamps WHERE repo_id=$repo_id AND version='$release';");
		$tsres->execute();
		my $tsref = $tsres->fetchrow_hashref();
		my $master_timestamp = $$tsref{"value"};
		$master_timestamp = "" unless defined($master_timestamp);

		my $master_reached = 0; # used to determine if we are testing against cached master data
		my $newts = get_master_timestamp($master{"http"}."$centos_or_altarch/$release/$repo_path/$repofname");
		if($newts !~ /^[0-9.]{5,}$/) {
			logprint(1, "Got invalid timestamp $newts from master for $repo_id $repo_path\n");
			# use the cached copy from database instead if available, otherwise skip this repo
			if($master_timestamp !~ /^[0-9.]{5,}$/) {
				logprint(1, "Skipping $repo_id $repo_path due to missing timestamp\n");
				next;
			}
			logprint(1, "Using cached timestamp $master_timestamp for $repo_id $repo_path\n");
		} else {
			# we got a valid timestamp from master, so the repo definitely exists
			$master_reached = 1;

			if( $newts ne $master_timestamp ) {
				logprint(2, "\nGot a new ts $newts for $repo_id $repo_path, old was $master_timestamp\n");
				$master_timestamp = $newts;
				# timestamp changed, invalidate old cached data
				$db->do("DELETE FROM valid_mirrors WHERE repo_id=$repo_id AND version='$release';");
			}
			$db->do("REPLACE INTO master_timestamps (repo_id, version, value, checked) VALUES ($repo_id, '$release', '$newts', now());");
		}

		system("mkdir $outputdir/$ipver/$centos_or_altarch/$release/$repo_path/mirrorlists -p");

		my %errors = ( );		# errors from each mirror ID (incl. protocol)
		my %valid_mirrors = ( );	# mirror IDs (incl. protocol) that were previously or during this run found to be valid
		my %outdated_mirrors = ( );	# mirror IDs that were found to be outdated

		$res = $db->prepare("SELECT mirror_id, proto FROM valid_mirrors WHERE repo_id=$repo_id AND version='$release' AND ipver='$ipver';");
		$res->execute();

		while(my @l = $res->fetchrow_array()) {
			$valid_mirrors{"${l[0]} ${l[1]}"} = 1; # sets "mirror_id http" = 1
		}

		logprint (0, "\n$ipver $repo_path ts=$master_timestamp id=$repo_id\n");

		my $continentcounter = 0;			# for iterating through continents for the fallback list
		@all_continents = shuffle(@all_continents);	# randomize the order of continents for the fallback list
		my @used_fallback_mirrors = ( 0 );		# don't include any mirror twice on the fallback list, init to zero to make SQL OK

		foreach my $cc ("fallback", shuffle (@allccs, keys %country_subregions)){

			logprint (0, "\n$ipver $cc $repo_path\n");

			################# get status of mirrors ##########

			my $lwpres;
			my $okmirrors="";
			my $goodtot=0;

			###
			
			# phase 1 -- this U.S. state or Canada province
			# phase 2 -- this country
			# phase 3 -- other nearby countries
			# phase 4 -- mirrors from the same continent
			# phase 5 -- a random mirror from each continent (for fallback only)
			# note: phase 5 will be executed once for each continent (with "redo")
			# phase 6 -- random mirrors from any continent (for fallback only)
			# phase 7 -- centos servers from the same continent
			# phase 8 -- centos servers from other continents (used also for fallback)

			###

			my $continent;
			my @checkedccs = ( );
			my $save_cc = $cc;	# for U.S. and Canada, where to save the generated mirrorlist file (for example: fi or us-TX; TX will be changed to us-TX later)
			my $skipregion = "";	# for U.S. and Canada, SQL fragment to skip this region in later phases

			# state IN ('behind', 'out of date') mirrors can still be useful for many repos, even if they don't have the latest updates
			my $commonqueryparams = "status NOT IN ('Dead', 'Disabled', 'Gone') AND state NOT IN ('timeout') AND use_in_mirrorlists='yes'";
			my $columns = "mirror_id, ";
			if($altarch) {
				$columns .= "altarch_http";
			} else {
				$columns .= "http";
			}

			PHASE: foreach my $phase (1..8) {

				if($goodtot >= 10){
					last;
				}
				if(($phase == 5 || $phase == 6) && $cc ne "fallback") {
					next;
				}
				if(($phase < 5 || $phase == 7) && $cc eq "fallback") {
					next;
				}

				my $query = "";
				if($phase == 1) {
					# phase 1 for U.S. states and Canadian provinces only
					next unless $cc =~ /^[A-Z][A-Z]$/;

					my $fallbackcountry = $country_subregions{$cc}; # from geo_cc.pm

					$query = "SELECT $columns FROM mirrors WHERE type IN ('Direct', 'Indirect') AND status = 'Active' 
						AND cc='$fallbackcountry' AND `location-minor`='$cc' AND $commonqueryparams $altarch_where ORDER BY RAND()";
					$skipregion = "AND `location-minor`<>'$cc'";

					$save_cc = "${fallbackcountry}-${cc}"; # us-TX
					$cc = $fallbackcountry; # next phases will be done with either "us" or "ca" as the cc
				}
				if($phase == 2) {
					#is this a centos code ??
					if(grep(/^$cc$/i, @centos_codes)) {
						$query = "SELECT $columns FROM mirrors WHERE type IN ('Direct', 'Indirect') AND status = 'Active' 
							AND centos_code = '$cc' AND $commonqueryparams $altarch_where ORDER BY RAND()";
					} else {
						$query = "SELECT $columns FROM mirrors WHERE type IN ('Direct', 'Indirect') AND status = 'Active' 
							AND cc = '$cc' AND $commonqueryparams $skipregion $altarch_where ORDER BY RAND()";
					}
					push(@checkedccs, $cc);
				}

				if($phase == 3) {
					# get list of nearby countries
					my @cclist = get_cc_list($cc);
					if(scalar(@cclist) == 0) {
						next;
					}
					for(my $index=0; $index<scalar(@cclist); $index++) {
						my $ccl = $cclist[$index];
						if( $ccl ne $cc) {
							push(@checkedccs, $ccl);
							$query .= "SELECT $index AS idx, $columns FROM mirrors WHERE type IN ('Direct', 'Indirect') AND 
								status = 'Active' AND speed = 'T1' AND cc = '$ccl' AND $commonqueryparams $altarch_where UNION ";
						}
					}

					next unless $query;

					$query =~ s/UNION $/ORDER BY idx, RAND()/;
				}

				if($phase == 4) {
					$continent = get_cc_cont($cc);
					$continent = "" unless defined($continent);
					if($continent eq "" || grep(/^$cc$/i, @centos_codes)) {
						next;
					}
					$query = "SELECT $columns FROM mirrors WHERE type IN ('Direct', 'Indirect') AND status = 'Active' AND speed = 'T1' 
						AND continent = '$continent' AND $commonqueryparams 
						AND cc NOT IN ('" . join("','", @checkedccs) . "') $altarch_where ORDER BY RAND()";
				}

				if($phase == 5) {
					$continent = $all_continents[$continentcounter++];
					next unless defined($continent);
					logprint(3, "searching for fallback mirrors from $continent\n");
					$query = "SELECT $columns FROM mirrors WHERE type IN ('Direct', 'Indirect') AND status = 'Active' AND speed = 'T1' 
						AND continent = '$continent' AND $commonqueryparams AND bandwidth+0>=200
						$altarch_where ORDER BY RAND()";
				}

				if($phase == 6) {
					logprint(3, "searching for fallback mirrors from anywhere\n");
					$query = "SELECT $columns FROM mirrors WHERE type IN ('Direct', 'Indirect') AND status = 'Active' AND speed = 'T1' 
						AND $commonqueryparams AND bandwidth+0>=200
						AND mirror_id NOT IN (" . join(",", @used_fallback_mirrors) . ") $altarch_where ORDER BY RAND()";
					$continent = "fallback";	# so that the query in phase 8 would work properly
				}

				if($phase == 7) {
					logprint(2, "only got $goodtot - adding some centos ones\n");
					next unless $continent;
					$query = "SELECT mirror_id, arch_all, arches, concat(http,'centos/') AS http, status, state,
						concat(http,'altarch/') AS altarch_http
						FROM mirrors
						WHERE Type = 'Slave' AND status = 'Master' AND continent = '$continent' 
						AND $commonqueryparams ORDER BY RAND()";
				}

				if($phase == 8) {
					logprint(2, "only got $goodtot - adding some centos ones\n") if $continent eq "fallback";
					$query = "SELECT mirror_id, arch_all, arches, concat(http,'centos/') AS http, status, state,
						concat(http,'altarch/') AS altarch_http
						FROM mirrors 
						WHERE Type = 'Slave' AND status = 'Master' AND continent <> '$continent' 
						AND $commonqueryparams ORDER BY RAND()";
				}

				next unless $query;

				$res = $db->prepare($query);
				$res->execute();
				while (my $mirref = $res->fetchrow_hashref()){

					if($goodtot >= 10){
						last;
					}
					my %mirror = %$mirref;
					my $mirror_id = $mirror{"mirror_id"};

					my $url="";
					my $base="";
					my $proto="";

					if($altarch) {
						if ($mirror{"altarch_http"}) {
							$base = $mirror{"altarch_http"};
							$url = "${base}$release/$repo_path/";
							$proto = "http";
						}
					} else {
						if ($mirror{"http"}) {
							$base = $mirror{"http"};
							$url = "${base}$release/$repo_path/";
							$proto = "http";
						}
					}

					next unless $url;

					if($phase == 5) {
						# maybe it doesn't get used in phase 5, but at least it was considered
						push(@used_fallback_mirrors, $mirror_id);
					}

					if(defined($timeoutmirrors{"$mirror_id $proto"}) || defined($outdated_mirrors{$mirror_id}) || defined($errors{"$mirror_id $proto"}) ) {
						next;
					}
					if(!defined($http_errors{"$mirror_id $proto"})) {
						$http_errors{"$mirror_id $proto"} = 0;
					}
					if($http_errors{"$mirror_id $proto"} >= $max_http_errors && $master_reached == 1) {
						# too many errors from this mirror
						next;
					}

					# first check this mirror does this arch
					# currently not in use, but perhaps gets used some day. in that case add arch_all and arches to query.
					#if ($mirror{"arch_all"} ne "yes") {
					#	my @ar = split(' ',$mirror{"arches"});
					#	if(!grep(/^$arch$/i, @ar)) {
					#		logprint (2,"No arch match $arch in @ar\n");
					#		next; #while
					#	}
					#}

					#it may already be in the cache 

					if(defined($valid_mirrors{"$mirror_id $proto"}) && defined($checkedonce{"$mirror_id $proto"})) {
						logprint(2, "$url - good ts from cache\n");
						$okmirrors.="$url\n";
						++$goodtot;
						if($phase == 5) {
							# repeat this phase for other continents, until next is invoked elsewhere when continents run out
							redo PHASE;
						}
						next;
					}

					# send request
					$lwpres = get_file("$url$repofname", $ipver);

					if ($lwpres->is_success) {
						my $ts = "";
						if($url =~ m!/atomic/(.+?)/repo/$! ) {
							$ts = ownhash($lwpres->content);
						} else {
							$ts = get_ts_from_xmlfile($lwpres->content);
						}
						logprint(3,"$ipver ts is $ts\n");
		
						if($ts eq $master_timestamp) {
							logprint(2, "$url\n");
							logprint(3, "$ipver good timestamp\n");
							$okmirrors.="$url\n";
							++$goodtot;
							$checkedonce{"$mirror_id $proto"} = 1;
							$valid_mirrors{"$mirror_id $proto"} = 1; # only for this repo, will be cleared for the next repo
							$db->do("REPLACE INTO valid_mirrors (repo_id, version, mirror_id, ipver, proto, checked)
								VALUES ($repo_id, '$release', $mirror_id, '$ipver', '$proto', now());");
							if($phase == 5) {
								# repeat this phase for other continents, until next is invoked elsewhere when continents run out
								redo PHASE;
							}
						}
						else {
							logprint(1,"$url - Bad ts $ts\n");
							$outdated_mirrors{$mirror_id} = 1; # only for this repo, will be cleared for the next repo
							# clear any possible valid_mirrors entries for all protocols
							my $somethingfound = 0;
							foreach my $key (grep /^$mirror_id /, keys %valid_mirrors) {
								delete($valid_mirrors{$key});
								if(++$somethingfound == 1) {
									$db->do("DELETE FROM valid_mirrors WHERE repo_id=$repo_id AND version='$release' AND mirror_id=$mirror_id AND ipver='$ipver';");
								}
							}
						}
  					}
					else {
						if(defined($valid_mirrors{"$mirror_id $proto"})) {
							# we thought the mirror using this protocol was valid and reachable, but apparently it isn't
							delete($valid_mirrors{"$mirror_id $proto"});
							$db->do("DELETE FROM valid_mirrors WHERE repo_id=$repo_id AND version='$release' AND mirror_id=$mirror_id AND ipver='$ipver' AND proto='$proto';");
						}
						my $errstr = $lwpres->status_line;
						logprint(1, "$url - $errstr\n");
						$errors{"$mirror_id $proto"} = $errstr; # only for this repo, will be cleared for the next repo
					}

					if($lwpres->status_line =~ /$timeoutmatch/){
						# don't use this mirror for the rest of this session
						logprint(0,"$ipver $base going in timeout mirrors\n");
						$timeoutmirrors{"$mirror_id $proto"} = 1;
					}
					if($lwpres->status_line =~ /^(40[34]|30\d)/ && $master_reached == 1) {
						if(++$http_errors{"$mirror_id $proto"} >= $max_http_errors) {
							logprint(1, "$ipver $base has had too many HTTP errors, not testing again\n");
						}
					}
				}
				if( $phase == 1 && $goodtot == 0 && $save_cc =~ /^[a-z][a-z]-[A-Z][A-Z]$/) {

					# If at first you don't succeed destroy all evidence that you ever tried.

					# We did not find any usable mirrors from this U.S. state / Canadian province after all, but let's
					# clean up any possible stale data from previous runs. The main .us/.ca list should be used instead.

					unlink("$outputdir/$ipver/$centos_or_altarch/$release/$repo_path/mirrorlists/mirrorlist.$save_cc");

					# uncomment this if you want to create symlinks to the fallback country
					# (but this would better be handled in mirrorlist.c.o scripts)
					#symlink("mirrorlist.$cc",
					#	"$outputdir/$ipver/$centos_or_altarch/$release/$repo_path/mirrorlists/mirrorlist.$save_cc");
					last;
				}
				if($phase == 5) {
					# repeat this phase for other continents, until next is invoked elsewhere when continents run out
					redo PHASE;
				}
			}

			if($goodtot > 5){ # replace mirrorlist file - otherwise leave it alone 
				my $outfile = "$outputdir/$ipver/$centos_or_altarch/$release/$repo_path/mirrorlists/mirrorlist.$save_cc";
				# remove the file first, important if the file was a symlink and a new separate file is being created now
				unlink($outfile);
				if (open (OUT, ">$outfile")){
					print OUT "$okmirrors";
					close(OUT);
				}
				else	{
					logprint(0,"Could not open $outfile for writing\n");
					# but carry on ...
				}
			}
			# end of cc
		}
		# end of repo

		# if there was a 2nd instance of this script checking the same release and the same repo at the same time, and
		# an update happened on master between the starts of those crawler runs, it is possible that the 1st instance has
		# written stale data to valid_mirrors. the 2nd script cleared valid_mirrors in the beginning, but the 1st
		# script kept writing entries to valid_mirrors based on the old timestamp. it's very unlikely that this would happen
		# in real life, but let's take care of this anyway by checking if the timestamp in database has been changed
		# by the 2nd instance. if so, it is possible that we have just written mirrorlist files based on old information,
		# but they will be fixed either by the 2nd instance, or at the latest by the next run. for the latter, we need
		# to clear valid_mirrors for this repo for the current IP version, so that the mirrors would be rechecked.

		$tsres = $db->prepare("SELECT value FROM master_timestamps WHERE repo_id=$repo_id AND version='$release';");
		$tsres->execute();
		$tsref = $tsres->fetchrow_hashref();
		my $new_master_timestamp = $$tsref{"value"};
		$new_master_timestamp = "" unless defined($new_master_timestamp);

		next if $master_timestamp eq $new_master_timestamp;

		logprint(1, "\nOh wow, timestamp for $repo_id changed from $master_timestamp to $new_master_timestamp during checking, clearing valid_mirrors\n");
		$db->do("DELETE FROM valid_mirrors WHERE repo_id=$repo_id AND version='$release' AND ipver='$ipver';");
	}
	# end of ipv4/ipv6
}
# end of everything

logprint(2, "\nFinished, took " . int((time()-$starttime)/60) . " min " . ((time()-$starttime) % 60) . " sec\n");
close(LOG);


#### some useful functions ####

sub get_ts_from_xmlfile {
	
	my $block = $_[0];

	foreach($block) {
		if($block=~/<timestamp>(.*?)<\/timestamp>/) {
			return $1;
		}
	}
	return "";
}

sub get_master_timestamp {
	my $url = $_[0];

	# cache the timestamps from master for a while
	if(defined($master_ts_cache{$url}) && $master_ts_cache{"$url stored"} > time()-10*60) {
		return $master_ts_cache{$url};
	}

	# send request
	my $lwpres = get_file($url, "ipv4", 15);
	my $ts = "";

	if ($lwpres->is_success) {
		if($url =~ m!/atomic/(.+?)/repo/! ) {
			$ts = ownhash($lwpres->content);
		} else {
			$ts = get_ts_from_xmlfile($lwpres->content);
		}
		$master_ts_cache{$url} = $ts;
		$master_ts_cache{"$url stored"} = time();
	}
	return $ts;
}

sub logprint {
	my ($debuglevel, @log) = @_;

	if ($debuglevel == 0) {
		print @log;
	}
	if($debuglevel <= 1 || $debuglevel <= $debug) {
		print LOG @log;
	}
}

sub get_file
	{
	my ($url, $ipver, $timeout) = @_;

	if(!defined($timeout)) {
		$timeout = 10;
	}

	# request a "summary" file instead of repomd.xml for Atomic
	$url =~ s!/atomic/(.+?)/repo/repodata/repomd.xml$!/atomic/$1/repo/summary!;

	my $ua = LWP::UserAgent->new;
	$ua->agent('CentOS-makemirrorlists/9q ');
	
	# don't follow redirects
	$ua->max_redirect(0);

	# we need to use a socket class that is capable of IPv6 (and IPv4)
	$Net::HTTP::SOCKET_CLASS = 'IO::Socket::INET6';
	if($Net::HTTP::SOCKET_CLASS) {} # silence warning

	# this is needed to force LWP to use only the specified IP version
	if($ipver eq "ipv6") {
		@LWP::Protocol::http::EXTRA_SOCK_OPTS = ( LocalAddr => $localv6addr );
	} else {
		@LWP::Protocol::http::EXTRA_SOCK_OPTS = ( LocalAddr => $localv4addr );
	}

	$ua->timeout($timeout);
	my $req = HTTP::Request->new(GET => "$url");
 	$req->header('Accept' => 'text/html');

	# send request
	return $ua->request($req);
}

sub create_json {
	my %repohash = ( );
	my $foundrepos = 0;
	# order by altarch desc so that if there are conflicting repo definitions, main arch repos get priority (altarch data gets overwritten)
	my $repores = $db->prepare("SELECT * FROM repos WHERE enabled='yes' ORDER BY altarch DESC, repo_id");
	$repores->execute();
	while(my $reporef = $repores->fetchrow_hashref()) {
		my %repo = %$reporef;
		my ($major, $name, $arch, $altarch, $path) = ( $repo{"major_release"}, $repo{"name"}, $repo{"arch"}, $repo{"altarch"}, $repo{"path"} );
		if($altarch) {
			${repohash{$major}{$name}{$arch}{"branch"}} = "altarch";
		} else {
			${repohash{$major}{$name}{$arch}{"branch"}} = "centos";
		}
		${repohash{$major}{$name}{$arch}{"path"}} = $path;
		$foundrepos++;
	}

	# sanity check
	if($foundrepos < 20) {
		# don't touch the files
		return;
	}

	my $json = "{\n";

	my $majors = 0;
	foreach my $major (sort keys %repohash) {
		if($majors++ > 0) {
			$json .= ",\n";
		}
		$json .= "\t\"$major\": {\n";

		my $repos = 0;
		foreach my $repo (sort keys %{ $repohash{$major} }) {
			if($repos++ > 0) {
				$json .= ",\n";
			}
			$json .= "\t\t\"$repo\": {\n";

			my $arches = 0;
			foreach my $arch (sort keys %{ $repohash{$major}{$repo} }) {
				if($arches++ > 0) {
					$json .= ",\n";
				}
				$json .= "\t\t\t\"$arch\": {\n";
				$json .= "\t\t\t\t\"branch\": \"" . ${repohash{$major}{$repo}{$arch}{"branch"}} . "\",\n";
				$json .= "\t\t\t\t\"path\": \"" . ${repohash{$major}{$repo}{$arch}{"path"}} . "\"";
				$json .= "\n\t\t\t}";
			}
			$json .= "\n\t\t}";
		}
		$json .= "\n\t}";
	}
	$json .= "\n}\n";

	my $newmd5 = md5_hex($json);

	my $oldmd5 = "";

	if( -r "$outputdir/repos.json" ) {
		open(OLD, "$outputdir/repos.json") || warn("Can't open old repos.json");
		my $oldjson = do { local $/; <OLD> };
		close(OLD);
		$oldmd5 = md5_hex($oldjson);
	}

	if( $newmd5 ne $oldmd5 ) {
		logprint(1, "New repos.json $newmd5, old was $oldmd5\n");
		my $jsonfilename = "$outputdir/repos.json";
		open (JSON, ">$jsonfilename") || warn ("cannot open $jsonfilename");
		print JSON $json;
		close(JSON);
	} else {
		logprint(2, "repos.json unchanged\n");
	}

#	not used at the moment
#	my $pyfilename = "$outputdir/repos.py";
#	open (JSON, ">$pyfilename") || warn ("cannot open $pyfilename");
#	print JSON "repos = $json";
#	close(JSON);
}

sub ownhash {
	# construct a 15-digit "timestamp" from binary data
	my $ts = shift;

	# hopefully there is at least one digit in the md5 hex string.
	# chances for an "all a-f" md5 string are (6/16)^32, which is low enough.
	# using md5 because anything better would require additional modules.
	$ts = md5_hex($ts) x 15;
	$ts =~ s/[^0-9]//g;
	$ts = substr($ts, 0, 15);
	return $ts;
}
