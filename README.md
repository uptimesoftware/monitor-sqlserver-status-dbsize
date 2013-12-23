SQL File Space DBstatus Monitor
===================
This monitor uses a perl script along with ODBC to connect to a remote MSSQL instance and obtains the following parametres :

	DBStatus 
	DBFreeSpaceMB 
	DBFreeSpacePCT 
	LogFileFreeSpaceMB 
	LogFileFreeSpacePCT 


It requires:

	Hostname
	Username
	Password
	
	Optional : 	SQL port 
			 	Action (include/exclude)
			 	List of databases (comma seperated)
			 	uptime agent port
	
	

Depenedency: Requires unixODBC, freeTDS to be configured for DNS less authentication

Usage: 
	1. Add the MSSQL as a virtual node in up.time
	2. Add this service monitor to the MSSQL 
