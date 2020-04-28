$dockerVersion = "19.03.5";
$ErrorActionPreference = "Stop";
$ProgressPreference = "SilentlyContinue";

# Disable the local Administrator Account
#
# Keep in mind this script should now be running as the "ec2-user" via SSH.
# Where as before in the "userdata.ps1" script we were running as the local
# Administrator account.
#
# This should make sure that the only way to login to this machine is via SSH
# with a keypair. Attempting to login via RDP or somehow directly via the
# console is impossible.
Disable-LocalUser -Name "Administrator";
Write-Output "Disabled Local Administrator Account";

# Install authorized_keys
#
# This will create a scheduled task that will execute at boot time and inject
# the correct public key as provided by the ec2 metadata service.
#
# > We are not doing this for this VM, see note in the userdata script.
#$T = New-JobTrigger -AtStartup;
#New-Item -Force -ItemType "file" -Path "C:\Users\$env:UserName\.ssh" -Name "authorized_keys.ps1" -Value @"
#	`$out = 'C:\Users\$env:UserName\.ssh\authorized_keys';
#	if (Test-Path `$out) {
#		Remove-Item `$out;
#	}
#	Invoke-WebRequest "http://169.254.169.254/latest/meta-data/public-keys/0/openssh-key" -OutFile `$out;
#"@;
#Register-ScheduledJob -Name "Download EC2 authorized_keys" -Trigger $T -FilePath "C:\Users\$env:UserName\.ssh\authorized_keys.ps1";

# Configure EC2Launch
#
# see: https://docs.aws.amazon.com/AWSEC2/latest/WindowsGuide/ec2launch.html
New-Item -Force -ItemType "file" -Path "C:\ProgramData\Amazon\EC2-Windows\Launch\Config" -Name "LaunchConfig.json" -Value @'
{
	"setComputerName": true,
	"setWallpaper": false,
	"addDnsSuffixList": true,
	"extendBootVolumeSize": true,
	"handleUserData": true,
	"adminPasswordType": "DoNothing"
}
'@;
& "C:\ProgramData\Amazon\EC2-Windows\Launch\Scripts\InitializeInstance.ps1" -Schedule;

# Disable the firewall
# In EC2 land we have things like Security Groups to handle this.
Set-NetFirewallProfile -Profile Domain, Public, Private -Enabled False;

# Disable AV
# This image is for dev and testing and I don't want to waste CPU cycles on this
# If this were a Production machine you might think twice about this.
Uninstall-WindowsFeature Windows-Defender;

# Install Docker
Install-WindowsFeature -Name Containers;
Install-PackageProvider -Name NuGet -Force;
Install-Module -Name DockerMsftProvider -Repository PSGallery -Force;
Install-Package -Name docker -ProviderName DockerMsftProvider -Force -RequiredVersion $dockerVersion;
Set-Service -Name docker -StartupType 'Automatic';
