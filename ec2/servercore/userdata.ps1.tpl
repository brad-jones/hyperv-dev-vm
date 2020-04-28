<powershell>
# Create User Profile
# ------------------------------------------------------------------------------
# The following functions help to create a new user profile without having the
# user log in. The reason we need to do this is because the windows SSH port
# will not work correctly until the user profile has been created, which normally
# happens upon first "console" login but our user does not have a password and
# cannot login via the console.
#
# credit: https://gist.github.com/MSAdministrator/41df43e780993e48bf637a4ccd0e4c68
function Register-NativeMethod {
	[CmdletBinding()]
	[Alias()]
	[OutputType([int])]
	Param
	(
		# Param1 help description
		[Parameter(Mandatory = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 0)]
		[string]$dll,

		# Param2 help description
		[Parameter(Mandatory = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 1)]
		[string]
		$methodSignature
	)

	$script:nativeMethods += [PSCustomObject]@{ Dll = $dll; Signature = $methodSignature; }
}

function Get-Win32LastError {
	[CmdletBinding()]
	[Alias()]
	[OutputType([int])]
	Param($typeName = 'LastError')
 if (-not ([System.Management.Automation.PSTypeName]$typeName).Type) {
		$lasterrorCode = $script:lasterror | ForEach-Object {
			'[DllImport("kernel32.dll", SetLastError = true)]
         public static extern uint GetLastError();'
		}
		Add-Type @"
        using System;
        using System.Text;
        using System.Runtime.InteropServices;
        public static class $typeName {
            $lasterrorCode
        }
"@
	}
}

function Add-NativeMethods {
	[CmdletBinding()]
	[Alias()]
	[OutputType([int])]
	Param($typeName = 'NativeMethods')

	$nativeMethodsCode = $script:nativeMethods | ForEach-Object { "
        [DllImport(`"$($_.Dll)`")]
        public static extern $($_.Signature);
    " }

	Add-Type @"
        using System;
        using System.Text;
        using System.Runtime.InteropServices;
        public static class $typeName {
            $nativeMethodsCode
        }
"@
}

function Create-NewProfile {
	[CmdletBinding()]
	[Alias()]
	[OutputType([int])]
	Param
	(
		# Param1 help description
		[Parameter(Mandatory = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 0)]
		[string]$UserName
	)

	$MethodName = 'UserEnvCP'
	$script:nativeMethods = @();

	if (-not ([System.Management.Automation.PSTypeName]$MethodName).Type) {
		Register-NativeMethod "userenv.dll" "int CreateProfile([MarshalAs(UnmanagedType.LPWStr)] string pszUserSid,`
         [MarshalAs(UnmanagedType.LPWStr)] string pszUserName,`
         [Out][MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszProfilePath, uint cchProfilePath)";

		Add-NativeMethods -typeName $MethodName;
	}

	$localUser = New-Object System.Security.Principal.NTAccount("$UserName");
	$userSID = $localUser.Translate([System.Security.Principal.SecurityIdentifier]);
	$sb = new-object System.Text.StringBuilder(260);
	$pathLen = $sb.Capacity;

	Write-Verbose "Creating user profile for $Username";

	try {
		[UserEnvCP]::CreateProfile($userSID.Value, $Username, $sb, $pathLen) | Out-Null;
	}
	catch {
		Write-Error $_.Exception.Message;
		break;
	}
}

# Install SSH
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0;
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0;

# Configure sshd
#
# The default config is dumb, Ms have added these extra completely unnecessary
# things that make SSH authentication work in a non-standard, non-intuitive way.
# This config makes SSH work as expected.
New-Item -ItemType "directory" -Path "C:\ProgramData" -Name "ssh" -Force;
New-Item -ItemType "file" -Path "C:\ProgramData\ssh" -Name "sshd_config" -Value @'
SyslogFacility LOCAL0
LogLevel DEBUG3
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
Subsystem sftp sftp-server.exe
'@;

# Set Powershell as the default shell
$psPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';
Set-ItemProperty -Path $path -Name 'Shell' -Value "$psPath -NoExit";
$path = 'HKLM:\SOFTWARE\OpenSSH';
New-Item -Path $path -Force;
New-ItemProperty -Path $path -Name 'DefaultShell' -Value $psPath -PropertyType String -Force;

# Add a non-privilaged user.
#
# Okay so the user is actually part of the Administrators group so technically
# no different to using the built in local administrator account. The reason for
# this is because Windows simply does not have an adequate alternative to "sudo".
#
# The principle is the same though and we get some additional protections,
# the username is different for a start and this user does not have a password
# so no one can login via the console.
#
# NOTE: In the provision-ssh.ps1 script we disable the local admin account,
#       difficult to do when your running as the local admin.
$username = "{{ssh_username}}";
New-LocalUser -Name $username -NoPassword -UserMayNotChangePassword;
Add-LocalGroupMember -Group "Administrators" -Member $username;
Create-NewProfile $username;
New-Item -ItemType "directory" -Path "C:\Users\$username\.ssh" -Name "keys" -Force;
Set-Content -Path "C:\Users\$username\.ssh\authorized_keys" -Value "{{ssh_public_key}}";

# Alternative to baking the key into the image, grab it from the EC2 metadata
# and then it will work like a real EC2 instance should. The only reason we not
# doing this here is because we want the mechanics of all these different types
# of VM's to be the same regardless of where they are running.
# ie: HyperV doesn't have the EC2 metadata service available.
#Invoke-WebRequest "http://169.254.169.254/latest/meta-data/public-keys/0/openssh-key" -OutFile "C:\Users\$username\.ssh\authorized_keys";

# Start sshd
Set-Service -Name sshd -StartupType 'Automatic';
Start-Service -Name sshd;

# The rest of the setup happens via SSH provisioners
</powershell>
