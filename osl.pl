#!/usr/bin/perl	-w

$ftp_server	= "ftp://10.1.18.1/";
$ftp_dir = "/dir/dir/dir";		# no backslash at the end!
$ftp_uid = "some username";
$ftp_pw	= "some password";

@src_dir = ("\\\\kronos\\sites\\vmgp");
@wc_exclude	= ("_vti",".mdb","\\bak","\\data","server.inc");

#use strict;
use File::Copy;
use File::stat;
use File::Find;
use Net::FTP;
#use Date::Pcalc qw(Delta_DHMS);
use Date::Parse;
use Win32::OLE;
use Win32::OLE::Variant;
use Win32::OLE::Const ("Microsoft ActiveX Data Objects 2");	# the "2" is important, otherwise it finds something else.

####################################################################

$logfilename = removeFilename($0);
$log_cnt = 0;

$total_files = 0;
$processed_files = 0;
$skipped_files = 0;
$start_date = timeString(time);


LOG("connecting to ftp server...");
$ftp = Net::FTP->new($ftp_server)		or die "unable to connect: $@\n";
$ftp->login($ftp_uid, $ftp_pw)			or die "unable to login: $@\n";
$ftp->binary;
LOG("connected!");

#--------------------------------------------------------------------------------------------------

my %lookup;
readFromDb();

find(\&processFiles, @src_dir);

#--------------------------------------------------------------------------------------------------

# report.
$span = calcDeltaSeconds($start_date,timeString(time));
LOG("finished. $span seconds, $total_files files, $processed_files uploaded, $skipped_files skipped.");

$ftp->quit()									or warn "unable to quit: $@\n";

writeToDb();
$conn->close();

closeLogfile();

####################################################################

sub readFromDb {
	my $rs = Win32::OLE->new("ADODB.Recordset");
	$rs->Open("SELECT * FROM FileInfo", $conn, adOpenDynamic, adLockOptimistic);

	while ( not $rs->Eof() ) {
		$lookup{$rs->{'Path'}->value} = $rs->{'Modified'}->value;
		
		$rs->MoveNext;
	}

	$rs->Close;
}

sub writeToDb {
	# delete all, first.
	$conn->Execute("DELETE FROM FileInfo");

	my $rs = Win32::OLE->new("ADODB.Recordset");
	$rs->Open("SELECT * FROM FileInfo", $conn, adOpenDynamic, adLockOptimistic);

	# write all.
	foreach $path (keys(%lookup)) {
		$rs->AddNew;

		$rs->{'Path'		}->{value} = $path;
		$rs->{'Modified'	}->{value} = timeString(stat($path)->mtime);
		$rs->{'Size'			}->{value} = stat($path)->size;

		$rs->Update;
	}

	$rs->Close;
}

sub processFiles {
	my $srcdir = fsToBs($File::Find::dir);
	my $srcpath = fsToBs($File::Find::name);
	my $base = fsToBs($File::Find::topdir);

	foreach my $exclude (@wc_exclude) {
		if ( index($srcpath, $exclude)>-1 ) {
			$File::Find::prune = 1 if -d $srcpath;
			return;
		}
	}

	# no DIRECT processing of directories.
	if ( -d $srcpath ) {
		return;
	}

	my $dstdir = $srcdir;
	my $dstpath = $srcpath;
	$dstdir =~ s{\Q$base\E}{$ftp_dir}is;
	$dstpath =~ s{\Q$base\E}{$ftp_dir}is;
	$dstdir = bsToFs($dstdir);
	$dstpath = bsToFs($dstpath);

	processFile($srcpath,$dstpath,$dstdir);
}

sub processFile {
	my ($src,$dst,$dstdir) = @_;

	$total_files++;
	LOG("processing file $total_files \"$src\"...");

	# --------------------
	# check time.

	my $need_upload = 0;

	# create time.
	my $t1 = $lookup{$src};
	my $t2 = timeString(stat($src)->mtime);

	if ( not defined $t1 ) {
		$lookup{$src} = $t2;
		$need_upload = 1;
	} else {
		my $delta_sec = calcDeltaSeconds($t1,$t2);
		$need_upload = 1 if $delta_sec>5;					# 5 seconds as tolerance.
	}

	# --------------------

	if ( $need_upload>0 ) {
		$processed_files++;

		LOG("uploading file \"$src\" to \"$dst\"...");
	
		$ftp->mkdir($dstdir,1);
		$ftp->put($src, $dst) or  die "unable to upload file \"$src\" to \"$dst\" (dst-dir: \"$dstdir\"): $@\n";

	} else {
		$skipped_files++;
	}
}

####################################################################

sub bsToFs {
	my ($s) = @_;
	$s =~ s/\\/\//gis;
	return $s;
}

sub fsToBs {
	my ($s) = @_;
	$s =~ s/\//\\/gis;
	return $s;
}

sub timeString {
	my ($tm) = @_;
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($tm);
	return sprintf("%04d-%02d-%02d %02d:%02d:%02d", $year+1900, $mon+1, $mday, $hour, $min, $sec);
}

# input dates as string "YYYY-MM-DD HH:MM:SS".
# earlier as first parameter, later as second.
sub calcDeltaSeconds {
	my ($t1,$t2) = @_;

	my ($year1,$month1,$day1,$hh1,$mm1,$ss1) = scanDate($t1);
	my ($year2,$month2,$day2,$hh2,$mm2,$ss2) = scanDate($t2);

	my ($days, $hours, $minutes, $seconds) = Delta_DHMS( 
		$year1, $month1, $day1, $hh1, $mm1, $ss1,					# earlier.
		$year2, $month2, $day2, $hh2, $mm2, $ss2);				# later.

	return $seconds + $minutes*60 + $hours*60*60 + $days*60*60*24.
}

sub removeFilename {
	my ($s) = @_;
	my $pos = rindex($s,'\\');
	return substr($s, 0, $pos);
}

# format: "2000-09-29 09:09:51".
sub scanDate {
	my ($date) = @_;
	my ($year, $month, $day, $hour, $minute, $seconds);

	$year			= substr($date, 0, 4);
	$month		= substr($date, 5, 2);
	$day			= substr($date, 8, 2);
	$hour			= substr($date, 11, 2);
	$minute		= substr($date, 14, 2);
	$seconds	= substr($date, 17, 2);

	return ($year, $month, $day, $hour, $minute, $seconds);
}

####################################################################

sub LOG {
	my ($text) = @_;
	my $time = timeString time;

	# log to stdout.
	print "[$time] $text\n";

	# log to logfile.
	my $LOG_STEP = 10;
	flushLogfile() if ($log_cnt % $LOG_STEP)==0 or $log_cnt==0;
	$log_cnt++;
	print HLOG "[$time] $text\n";
}

sub openLogfile {
	closeLogfile();
	open(HLOG,">>$logfilename") or die("Kann Logdatei $logfilename nicht öffnen: $!");	
};

sub closeLogfile {
	close HLOG if defined HLOG;
}

sub flushLogfile {
	closeLogfile();
	openLogfile();
}

####################################################################