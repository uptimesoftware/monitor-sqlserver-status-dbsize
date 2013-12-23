#!/usr/bin/perl -w
#
use DBI ;

my $host = $ENV{'UPTIME_MSSQL_HOST'} ;
my $user = $ENV{'UPTIME_MSSQL_USER'} ;
my $pass = $ENV{'UPTIME_MSSQL_PASS'} ;
my $port = $ENV{'UPTIME_MSSQL_PORT'} ;
my $action = $ENV{'UPTIME_MSSQL_MON_ACTION'} ;
my $dat = $ENV{'UPTIME_MSSQL_DATABASES'} ;
my $agent_port = $ENV{'UPTIME_AGENT_PORT'} ;
my $instance = $ENV{'UPTIME_MSSQL_INSTANCE'};

# if host not explicitly defined, use uptime host
unless ($host) {
	$host = $ENV{'UPTIME_HOSTNAME'} ;
}	

unless ( $host and $user and $pass){
	print "Critical. ENV variables missing. Halting program\n" ;
	exit 2 ;
}
$port = '1433' unless $port ;

if (($action and !$dat) or (!$action and $dat)){
	print "Critical. Either include/exclude or database list is missing. Both inputs should be provided. Halting program\n" ;
	exit 2 ;
}

# database status mapping, please adjust the severity of the code if needed 
my %dbstatus = (
	0		=> OK,
	1		=> WARN,
	2		=> WARN,
	3		=> WARN,
	4		=> CRIT,
	5		=> CRIT,
	6		=> CRIT,
	);

my $server_host = $host ;
$server_host = $server_host.'\\'.$instance if $instance ;
my $dbc = DBI->connect("DBI:ODBC:Driver=FreeTDS;Server=$server_host;Port=$port;TDS_Version=7.0;","$user","$pass") or die "Can't connect to MSSQL database:$DBI::errstr\n" ;

my %file ;
my %drive ;
my %db_master ;
my @ext ;
my $exit_stat = 'OK' ;

my $sth1 = $dbc->prepare("select sysdatabases.name,databases.state from master..sysdatabases left outer join sys.databases on sysdatabases.name = databases.name ") ;
$sth1->execute() ;

# Mark all databases in DBserver with one attrib in master datastructure
while (my ($d,$s) = $sth1->fetchrow_array()){
   $db_master{$d}{'current'} = 1 ;
	$db_master{$d}{'state'} = $s ;
}
$sth1->finish ;

# Add the externally provided db names also inside the datastructure and use the attrib name as an identifier (include/exclude) 
if ($dat) {
   @ext = split /,/,$dat ;
   foreach (@ext) {
      $db_master{$_}{$action} = 1 ;
   }
}

foreach (keys %db_master) {
   my $c_db = $_ ;
   next if ($db_master{$c_db}{'exclude'}) ; # Skip all db names that has exclude attrib set (explicit)
   next unless !$action or ($action and $db_master{$c_db}{'include'}) or ($action and $action =~/exclude/) ; # Ensure iteration progresses with incuded db names only (if specified one)
   if ($action and $action =~ /include/ and !$db_master{$c_db}{'current'}) {
		print "Error. DB $c_db not found in this server\n" ;
		exit 2 ;
	}
	# explicitly setting DB state to file 1 ( though some cases no files at all i.e offline 
	$file{$c_db}{1}{'state'} = $db_master{$c_db}{'state'} ;
	$file{$c_db}{1}{'status'} = $dbstatus{$db_master{$c_db}{'state'}} ;
	# Skip the databases those were not online and may spit error if we try connecting . Note : same skip permuatation needs at below iteration as well, if at all any changes here
	next if ($db_master{$c_db}{'state'} > 0 ) ;
	my $form_db = '"'.$c_db.'"' ; # hyphens and spaces in database names need some protection it seems
	$sth1 = $dbc->prepare("
   use $form_db
   select db_name(),sysfilegroups.groupid,sysfilegroups.groupname,fileid,
   convert(decimal(12,2),round(sysfiles.size/128.000,2)) as file_size,
   convert(decimal(12,2),round(fileproperty(sysfiles.name,'spaceused')/128.000,2)) as space_used,
   convert(decimal(12,2),round((sysfiles.size-fileproperty(sysfiles.name,'spaceused'))/128.000,2)) as free_space,
   maxsize/128 as max_size_mb,
   maxsize,
   sysfiles.name,
   sysfiles.filename,
   left(sysfiles.filename,1),
   database_files.growth
   from sys.sysfiles
   left outer join sys.sysfilegroups
   on sysfiles.groupid = sysfilegroups.groupid
   left outer join sys.database_files
   on sysfiles.fileid = database_files.file_id
   ");
   $sth1->execute ;
   my $filecnt = 1 ;
   while ( my ($db,$grp_id,$grp_name,$f_id,$f_size,$space_u,$free_space,$m_size_mb,$m_size,$l_f_name,$f_name,$f_drv,$growth) = $sth1->fetchrow_array()){
      $grp_id = '' unless defined $grp_id ;
      $grp_name = 'TLOG' unless defined $grp_name ;
      #print "$db,$grp_id,$grp_name,$f_id,$f_size,$space_u,$free_space,$m_size_mb,$m_size,$l_f_name,$f_name,$f_drv,$growth\n" ;
      $file{$db}{$filecnt}{'grp_id'} = $grp_id ;
      $file{$db}{$filecnt}{'grp_name'} = $grp_name ;
      $file{$db}{$filecnt}{'f_id'} = $f_id ;
      $file{$db}{$filecnt}{'f_size'} = $f_size ;
      $file{$db}{$filecnt}{'s_used'} = $space_u ;
      $file{$db}{$filecnt}{'fr_space'} = $free_space ;
      $file{$db}{$filecnt}{'m_size_mb'} = $m_size_mb ;
      $file{$db}{$filecnt}{'m_size'} = $m_size ;
      $file{$db}{$filecnt}{'l_f_name'} = $l_f_name ;
      $file{$db}{$filecnt}{'f_name'} = $f_name ;
      $file{$db}{$filecnt}{'f_drv'} = $f_drv ;
      $file{$db}{$filecnt}{'growth'} = $growth ;
      $filecnt ++ ;
   }
   $sth1->finish ;
}

# Collect the drive capacity info thru agent

my @drives = `echo -n df-k | /usr/bin/nc $host $agent_port` ;
foreach (@drives ){
   if (/^(\w):\s+(\d+)\s+\d+\s+(\d+)\s+(\d+|\d+\.\d+)%\s+\w:$/){
      my ($f_space,$drv,$size) = ($3,$1,$2) ;
      $f_space /= 1024  if $f_space ;
      $f_space = int $f_space if $f_space ;
      $size /= 1024 if $size ;
      $size = int ( $size ) if $size ;
      $drive{$drv}{'size'} = $size ; # size in MB
      $drive{$drv}{'free_space'} = $f_space ; # free space in MB
   }
}

foreach ( keys %file ) {
   my $db = $_ ;
   my %tmp ;
	my $dbfile_cnt = 1 ;
	my %dbfiles ;
	my %db_drv ;
	print "$db".'.DBStatus '.$file{$db}{1}{'state'}."\n" ;
	$exit_stat = $file{$db}{1}{'status'} if ($file{$db}{1}{'status'} eq 'WARN' and $exit_stat eq 'OK') ;
	$exit_stat = $file{$db}{1}{'status'} if ($file{$db}{1}{'status'} eq 'CRIT' and  ($exit_stat eq 'OK' or $exit_stat eq 'WARN')) ;
	next if ($file{$db}{1}{'state'} > 0 ) ;
   foreach ( keys %{$file{$db}} ){
      my $filecnt = $_ ;
      my $file_grp = $file{$db}{$filecnt}{'grp_name'} ;
      $tmp{$file_grp}{'f_size'} += $file{$db}{$filecnt}{'f_size'} ;
      $tmp{$file_grp}{'s_used'} += $file{$db}{$filecnt}{'s_used'} ;
      $tmp{$file_grp}{'fr_space'} += $file{$db}{$filecnt}{'fr_space'} ;
      $tmp{$file_grp}{'l_f_name'} = $file{$db}{$filecnt}{'l_f_name'} ;
      my $comp_m_size ;
      if ($file{$db}{$filecnt}{'growth'} == 0 ){
			$comp_m_size = $file{$db}{$filecnt}{'f_size'} ;
      }else {
			if ($file{$db}{$filecnt}{'m_size'} == -1 ){ # If maxsize is set -1 with autogrow then file will grow until the disk is full, so we go with the fixed drive freespace as maxsize
			$comp_m_size = $drive{$file{$db}{$filecnt}{'f_drv'}}{'free_space'} ;
			}elsif ( $file{$db}{$filecnt}{'m_size'} == 268435456 ){ # If maxsize is set 268435456 (Log file will grow to a maximum size of 2 TB), then maxsize is as either 2TB or diskfree space if it is less than 2TB
				if ( $drive{$file{$db}{$filecnt}{'f_drv'}}{'free_space'} > 2097152 ) {
					$comp_m_size = 2097152 ;
				}else {
				  	$comp_m_size = $drive{$file{$db}{$filecnt}{'f_drv'}}{'free_space'} ;
				}
			}elsif ( $file{$db}{$filecnt}{'m_size'} == 0){ # If maxsize is set 0 ( ie, no growth ), then use maxsize as the file's 'size', though this condition is not expected with autogrowth
				$comp_m_size = $file{$db}{$filecnt}{'f_size'} ;
			}else { # if none of the above, then the maxsize will have a value (mb converted value)
				$comp_m_size = $file{$db}{$filecnt}{'m_size_mb'} ;
			}
      }
      push @{$tmp{$file_grp}{'array'}}, {
		comp_size	=> $comp_m_size,
      };
		# another struct creation for DB size calc, here we include all files except logs
		unless ($file_grp =~ /TLOG/){
			$dbfiles{$dbfile_cnt}{'flag'} = 'drv_free_space' if ($file{$db}{$filecnt}{'growth'} != 0 and $file{$db}{$filecnt}{'m_size'} == -1) ;
			$dbfiles{$dbfile_cnt}{'flag'} = 'maxsize' if ($file{$db}{$filecnt}{'growth'} != 0 and $file{$db}{$filecnt}{'m_size'} != -1) ;
			$dbfiles{$dbfile_cnt}{'flag'} = 'filesize' if ($file{$db}{$filecnt}{'growth'} == 0 ) ;
			$db_drv{$file{$db}{$filecnt}{'f_drv'}} = $drive{$file{$db}{$filecnt}{'f_drv'}}{'free_space'} if ($file{$db}{$filecnt}{'growth'} != 0 and $file{$db}{$filecnt}{'m_size'} == -1) ;
			$dbfiles{$dbfile_cnt}{'f_drv'} = $file{$db}{$filecnt}{'f_drv'} ;
			$dbfiles{$dbfile_cnt}{'m_size_mb'} = $file{$db}{$filecnt}{'m_size_mb'} ;
			$dbfiles{$dbfile_cnt}{'f_size_mb'} = $file{$db}{$filecnt}{'f_size'} ;
			$dbfiles{$dbfile_cnt}{'drv_free_space'} = $drive{$file{$db}{$filecnt}{'f_drv'}}{'free_space'} ;
			$dbfiles{$dbfile_cnt}{'fr_space'} = $file{$db}{$filecnt}{'fr_space'} ;
			$dbfiles{$dbfile_cnt}{'s_used'} = $file{$db}{$filecnt}{'s_used'} ;
			$dbfiles{$dbfile_cnt}{'l_f_name'} = $file{$db}{$filecnt}{'l_f_name'} ; 
			$dbfile_cnt ++ ;
		}
   }
	my ($db_max_spc,$db_spc_used,$db_fr_spc,$db_file_size) ;
	for ( my $i=1 ; $i < $dbfile_cnt ; $i++ ){
		$db_spc_used += $dbfiles{$i}{'s_used'} ;
		$db_fr_spc += $dbfiles{$i}{'fr_space'} ;
		$db_file_size +=  $dbfiles{$i}{'f_size_mb'} ;
		if ($dbfiles{$i}{'flag'} ne 'drv_free_space'){ 
			next if ($db_drv{$dbfiles{$i}{'f_drv'}}) ; # skip m_size_mb or f_size_mb if the drive free space itself going to consider
			if($dbfiles{$i}{'flag'} eq 'maxsize'){
				# check max size set is higher than drive space 
				$db_max_spc += $dbfiles{$i}{'m_size_mb'} if($dbfiles{$i}{'m_size_mb'} <= $dbfiles{$i}{'drv_free_space'}) ;
				$db_max_spc += $dbfiles{$i}{'drv_free_space'} if($dbfiles{$i}{'m_size_mb'} > $dbfiles{$i}{'drv_free_space'}) ; 
			}else {
				# file_size case i.e no Autogrow
				$db_max_spc += $dbfiles{$i}{'f_size_mb'} ;
			}
		}
	}
	# add all drv free space (if any is set )
	foreach ( keys %db_drv ){
		$db_max_spc += $db_drv{$_} ;
	}
	my $db_alloc_spc_lft = $db_max_spc - $db_spc_used ; 
	my $db_alloc_spc_lft_pct = ( $db_alloc_spc_lft / $db_max_spc ) * 100 ;
	my $db_fr_spc_pct = ( $db_fr_spc / $db_file_size ) * 100 ;
	printf "$db.DBFreeSpaceMB %.2f\n", $db_alloc_spc_lft ;
	printf "$db.DBFreeSpacePCT %.2f\n", $db_alloc_spc_lft_pct ;
#	printf "$db.DBAllocatedSpaceLeftMB %.2f\n", $db_fr_spc ;
#	printf "$db.DBAllocatedSpaceLeftPCT %.2f\n", $db_fr_spc_pct ;
	# loop that does the file group calc ( Now its only for TLOG )
   foreach ( keys %tmp ){ # if one file group has multiple maxsize set (different drive for files situation), then add it if not same values
      my $grp = $_ ;
      my ($maxsize,$l_maxsize) ;
      foreach (@{$tmp{$grp}{'array'}}){
			my $ref = $_ ;
			if (defined $l_maxsize){
				$maxsize += $$ref{'comp_size'} if $l_maxsize != $$ref{'comp_size'} ;
			}else {
				$maxsize = $l_maxsize = $$ref{'comp_size'} ;
			}
      }
      my $allo_spc_lft = $maxsize - $tmp{$grp}{'s_used'} ; # DB Filegroup Allocated free space left
      my $allo_spc_lft_pct = ($allo_spc_lft / $maxsize ) * 100 ;
      printf "$db.LogFileFreeSpaceMB %.2f\n", $allo_spc_lft if $grp =~ /TLOG/ ;
      printf "$db.LogFileFreeSpacePCT %.2f\n", $allo_spc_lft_pct if $grp =~ /TLOG/ ;
      my $file_grp_fr_spc = $tmp{$grp}{'fr_space'} ;
      my $file_grp_fr_spc_pct = ( $file_grp_fr_spc / $tmp{$grp}{'f_size'} ) * 100 ;
 #     printf "$db.LogFileAllocatedSpaceLeftMB %.2f\n", $file_grp_fr_spc if $grp =~ /TLOG/ ;
#      printf "$db.LogFileAllocatedSpaceLeftPCT %.2f\n", $file_grp_fr_spc_pct if $grp =~ /TLOG/ ;
	}
}

# decide script exit value
if ( $exit_stat eq 'WARN' ) {
	exit 1 ; # warning exit code
}elsif ( $exit_stat eq 'CRIT' ) {
	exit 2 ; # critical
}else {
	exit 0 ; 
}
