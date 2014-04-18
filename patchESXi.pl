#!/usr/bin/perl
#Author: Stephen Schmidt

use strict;
use FindBin;
use lib "$FindBin::Bin/../";
use lib "/usr/lib/vmware-vcli/apps";
use VMware::VIRuntime;
use AppUtil::VMUtil;


my %opts = (

        host => {
                type => "=s",
                help => "ESXi Host name",
                required => 1,
        },
);

Opts::add_options(%opts);
Opts::parse();
Opts::validate();

my $domain = `grep domain patchESXi.conf|cut -d= -f2`;
my $host_name = Opts::get_option('host');
chomp($host_name, $domain);
my $hostnm;
if($domain == '') { $hostnm = $host_name; }else {$host_name =~ /(.+)\.$domain/; $hostnm = $1;}
my $host_service = "";
my $timestamp = `date '+%m-%d-%y'`;
chomp($timestamp);
my $ssh_key;
my $patch_file;
my $gold_version;
my $log_file;
my $nfs_server; 
my $nfs_share_dir;
my $ds_name;
my $ds_location;
my $vMA_server;
my $host;

#set variables from conf file
open(CONF,"<patchESXi.conf");
while(<CONF>) {
	chomp($_);
	if($_ =~ /ssh_key=(.*)/) {
		$ssh_key = $1;
	}
	elsif($_ =~ /patch_file=(.*)/) {
		 $patch_file = $1;
	}
	elsif($_ =~ /gold_version=(.*)/) {
		 $gold_version = $1;
	}
	elsif($_ =~ /log_file_location='(.*)'/) {
		 $log_file = $1 . "\/$hostnm\_$timestamp\_esxi.log";
	}
	elsif($_ =~ /nfs_server=(.*)/) {
		 $nfs_server = $1;
	}
	elsif($_ =~ /nfs_share_dir=(.*)/) {
		 $nfs_share_dir = $1;
	}
	elsif($_ =~ /ds_name='(.*)'/) {
		 $ds_name = $1 . $hostnm;
	}
	elsif($_ =~ /ds_location=(.*)/) {
		$ds_location = $1;
	}
	elsif($_ =~ /vMA_server=(.*)/) {
		$vMA_server = $1;
	}
}
Util::connect();

open(LOG, ">>$log_file");

#Connect to the ESXi host
$host = Vim::find_entity_view(view_type => 'HostSystem', filter => { 'name' => qr/$host_name/ });
if($host) {

	$host_service = Vim::get_view(mo_ref => $host->configManager->serviceSystem);
}
else {
	logger("Host does not exist or not a valid hostname, must use a FQDN (i.g. myserver.mydomain.com)");
	exit 1;
}

#Enter maintenance mode and start SSH, so that the NFS share can be mounted with the patch payload
if($host->runtime->inMaintenanceMode == '1') {
	logger("Host already in maintenance mode, proceeding.");
}
else {
	host_ops('ent_maint',$host);
}
$host_service->StartService(id => 'TSM-SSH');
check_keys($ssh_key);
logger("Beginning Patching...");

my $patch_volume = `ssh -q $host_name ls -1 $ds_name 2> /dev/null`;

#Mount payload on esxi host
if($patch_volume eq "") {

	logger("Mounting a NFS datastore that contains patch payload...");
	my $mount_results = `ssh -q $host_name esxcfg-nas -a $ds_name -o $nfs_server -s $nfs_share_dir`;
	chomp($mount_results);

	if($mount_results =~ /.*created and connected.*/) {

		logger($mount_results);
	}
	else{
		logger("Could not mount patch payload!");
		logger("$mount_results");
		exit 1;
	}
}

#Apply the patch
logger("Applying ESXi Patch");
my $patch_results= `ssh -q $host_name esxcli software vib install -d $ds_location/$ds_name/$patch_file`; 

logger("\n\n$patch_results\n\n");
logger("Cleaning up NFS mount");
`ssh -q $host_name "esxcfg-nas -d  $ds_name"`;

if($patch_results =~ /.*The update completed successfully.*/) {

	logger("Patching completed successfully, rebooting server.");
	host_ops('reboot',$host);
	sleep 150;
	$host->update_view_data();
	my $esxi_state = $host->runtime->connectionState->val;
	while($esxi_state ne "connected") {

		logger("Waiting for $host_name to reconnect, current status: $esxi_state");
		sleep 60;
		$host->update_view_data();
		$esxi_state = $host->runtime->connectionState->val;

	}
}
else {
	logger("Patching Failures....");
	logger($patch_results);
	exit 1;
}

#Get ESXi version after host is back up.
logger("Host is back online, verifying patch level");
$host->update_view_data();
my $esxi_version = $host->config->product->build;
logger("Current ESXi Version: $esxi_version should be Version: $gold_version");

#Exit maintenance mode after patching process
host_ops('ext_maint',$host);

`ssh -q root\@$host_name "chkconfig SSH off;auto-backup.sh"`;
$host_service->StopService(id => 'TSM-SSH');
Util::disconnect();
close(LOG);

sub check_keys {

	my ($ssh_key) = @_;
	print STDOUT "Checking for root ssh key...\n";
	my $key_check = `ssh -o StrictHostKeyChecking=no -q root\@$host_name grep "root\@$vMA_server" /etc/ssh/keys-root/authorized_keys`;
	if($key_check eq "") {
		print "Attempting to add root ssh key...\n";
		`ssh-keygen -R $host_name; ssh-keyscan -H $host_name >> /root/.ssh/known_hosts`;
		`ssh -q root\@$host_name "echo $ssh_key >> /etc/ssh/keys-root/authorized_keys"`;
	}
	else {
		print "SSH Keys are present.\n";
	}
}

sub host_ops {

	my ($operation,$host) = @_;
	my $task_ref;
	$host->update_view_data();

	if($operation eq 'ent_maint') {

		eval {
			$task_ref = $host->EnterMaintenanceMode_Task(timeout => 0, evacuatePoweredOffVms => 'true');
			logger("Entering maintenance mode for host: \"" . $host->name . "\" and evacuating any VMs if host is part of DRS Cluster ...");
			my $msg = "Successfully entered maintenance mode for host: \"" . $host->name . "\"!";
			&getStatus($task_ref,$msg);
		};
		if ($@) {
			# unexpected error
			logger("1-2 Error: " . $@ . "\n\n");
			exit 1;
		}

	} 
	elsif($operation eq 'ext_maint') {

		eval {
			$task_ref = $host->ExitMaintenanceMode_Task(timeout => 0);
			logger("Exiting maintenance mode for host: \"" . $host->name . "\" ...");
			my $msg = "Successfully exited maintenance mode for host: \"" . $host->name . "\"!";
			&getStatus($task_ref,$msg);
		};
		if ($@) {
			# unexpected error
			logger("Error: " . $@ . "\n\n");
			exit 1;
		}

	} 
	elsif($operation eq 'reboot') {

		if($host->runtime->inMaintenanceMode) {
			eval {
				$task_ref = $host->RebootHost_Task(force => 0);
				logger("Rebooting host: \"" . $host->name . "\" ...");
				my $msg = "Successfully kicked off reboot for host: \"" . $host->name . "\"! Please, wait...";
				&getStatus($task_ref,$msg);
			};
			if ($@) {
				# unexpected error
				logger("Error: " . $@ . "\n\n");
				exit 1;
			}
		} else {
			logger("Error: Host " . $host->name . " is not in maintenance mode!\n\n");
			exit 1;
		}

	}	
}

sub getStatus {
        my ($taskRef,$message) = @_;

        my $task_view = Vim::get_view(mo_ref => $taskRef);
        my $taskinfo = $task_view->info->state->val;
        my $continue = 1;
        while ($continue) {
                my $info = $task_view->info;
                if ($info->state->val eq 'success') {
                        logger($message);
                        $continue = 0;
                } elsif ($info->state->val eq 'error') {
                        my $soap_fault = SoapFault->new;
                        $soap_fault->name($info->error->fault);
                        $soap_fault->detail($info->error->fault);
                        $soap_fault->fault_string($info->error->localizedMessage);
			logger($soap_fault);
                        die "$soap_fault\n";
                }
                sleep 5;
                $task_view->ViewBase::update_view_data();
        }
}
sub logger {

	my ($msg) = @_;
	my $time = `date '+ [%m-%d-%y %H:%M]'`;
	chomp($time);
	chomp($msg);
	
	print LOG "$time: $msg\n";
	print "$time: $msg\n";
}

