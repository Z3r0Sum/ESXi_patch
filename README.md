<p>ESXi Patch Guide - "Free yourself of update manager"</p>
<p>This was written to easily patch ESXi Hosts without Update Manager.</p>
<p>This was inspired by: http://www.chriscolotti.us/vmware/vsphere/how-to-patch-vsphere-5-esxi-without-update-manager/
It was also brought on by the unreliability, at least in our organization, that Update Manager possessed.
A nice benefit is that this is much faster than Update Manager ever was...</p>
<p>Before I delve into the setup and instructions, I would like to thank William Lam for providing the community with an immense amount of content regarding the Perl SDK.  I am taking advantge of his host_ops and task status code with a few of my own wrinkles.</p>
<p>What you'll need:</p>
<p>1.) vMA
2.) NFS server
3.) vCenter
4.) Hopefully you have some ESXi servers to patch...</p>
<p>Initial Setup:</p>
<p>1.) On the NFS server you need to create a share that will house the payload that the patching script will leverage.<br />
</p>
<p>It will look something like this:
    cat /etc/exports 
        /export/ESXi_patch esxihost(rw,async,no_root_squash)
    ls -1 /export/ESXi_patch
        update-from-esxi5.5-5.5_update01.zip
        VMware-ESXi-5.5.0-1331820-depot.zip</p>
<p>You should share it to whatever ESXi hosts you plan on patching. Put all your ESXi depots inside there, they MUST be depots (i.g. ending in .depot.zip or .zip).</p>
<p>2.) On the vMA you will need to install git, or perform a 'git clone https://github.com/Z3r0Sum/ESXi_patch.git ' on another server and copy it over to the vMA.</p>
<p>3.) To increase ease of use, you should add whatever vCenter admin account that is setup to the credstore of an account on vMA. 
    See: /usr/lib/vmware-vcli/apps/general/credstore_admin.pl help</p>
<p>4.) To further increase ease of use for the patching script, you should generate ssh keys for root on the vMA. The public key will later be distributed to the ESXi host(s) being patched.</p>
<p>5.) Carefully read and edit the 'patchESXi.conf' file. I have left sample values for your reference.</p>
<p>6.) Run the patch script: "patchESXi.pl --server vcenter --username vcenter-admin --host esxihost"</p>
<p>7.) You can loop through a list of servers and run the patching script in the background for multiple servers at once (this functionality might be included in the script at a later date).</p>