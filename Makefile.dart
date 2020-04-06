import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dexeca/dexeca.dart';
import 'package:drun/drun.dart';
import 'package:path/path.dart' as p;
import 'package:retry/retry.dart';
import 'package:uuid/uuid.dart';
import 'package:xml/xml.dart' as xml;
import 'package:yaml/yaml.dart';
import './Makefile.utils.dart';
import './ssh-server/Makefile.dart' as ssh_server;

Future<void> main(List<String> argv) => drun(argv);

/// Run this before running [build].
///
/// This allows HyperV guests to access the packer HTTP server.
/// Expect to see a UAC prompt as this opens an elevated powershell session.
Future<void> firewallOpen() async {
  log('opening firewall for packer');

  await powershell('''
    New-NetFirewallRule `
      -Name packer_http_server `
      -DisplayName "Packer Http Server" `
      -Direction Inbound `
      -Action Allow `
      -Protocol TCP `
      -LocalPort 8000-9000;
  ''', elevated: true);
}

/// This removes the firewall rule created by [firewallOpen].
///
/// Expect to see a UAC prompt as this opens an elevated powershell session.
Future<void> firewallClose() async {
  log('closing firewall for packer');
  await powershell(
    'Remove-NetFirewallRule packer_http_server -Verbose;',
    elevated: true,
  );
}

/// Executes `packer build` with `./src/Packerfile.yml`.
///
/// We have decided to stick with the Yaml to Json conversion for now instead
/// of using the new Hcl support in packer because documentaion is lacking.
///
/// * [userName] The username to create as part of the kickstart installation.
///
/// * [sshKeyFile] The ssh key to install against the user that is created.
Future<void> build([
  @Env('USERNAME') String userName = 'packer',
  String sshKeyFile = '~/.ssh/id_rsa',
]) async {
  // Install the firewall rule if not installed
  if (!await firewallRuleInstalled('packer_http_server')) {
    await firewallOpen();
  }

  // Read in `./src/Packerfile.yml`.
  log('parsing Packerfile.yml');
  Map<String, dynamic> packerFile = json.decode(json.encode(loadYaml(
    await File(p.absolute('src', 'Packerfile.yml')).readAsString(),
  )));

  // Make the packerfile a little dynamic
  packerFile['min_packer_version'] = await getToolVersion('packer');
  packerFile['builders'][0]['ssh_username'] = userName;
  packerFile['builders'][0]['ssh_private_key_file'] = normalisePath(sshKeyFile);

  // Generate `./src/ks.cfg` from `./src/ks.cfg.tpl`.
  log('generating ks.cfg');
  var kickStart = await File(p.absolute('src', 'ks.cfg.tpl')).readAsString();
  kickStart = kickStart.replaceAll('{{username}}', userName);
  kickStart = kickStart.replaceAll(
    '{{sshkey}}',
    await () async {
      return (await File('${normalisePath(sshKeyFile)}.pub').readAsString())
          .trim();
    }(),
  );
  await File(p.absolute('src', 'ks.cfg')).writeAsString(kickStart);

  // Start packer
  var packer = dexeca(
    'packer',
    ['build', '-force', '-'],
    workingDirectory: p.absolute('src'),
  );

  // Pipe the Packerfile to packer, converting it to JSON on the fly.
  packer.stdin.writeln(jsonEncode(packerFile));
  await packer.stdin.flush();
  await packer.stdin.close();

  // Wait for packer to finish
  await packer;

  // Cleanup
  log('cleanup ks.cfg');
  await File(p.absolute('src', 'ks.cfg')).delete();
}

/// Creates a new instance of the built vm image.
///
/// If an instance of the same name already exists then it will upgraded
/// with the latest system disk and configuration. The data disk will be
/// left untouched.
///
/// * [rebuild] If set to true then a new build will always be performed
///
/// * [name] The name of new VM to create in Hyper-V.
///
/// * [dir] The parent directory where the VM files will be kept.
///
/// * [replaceDataDisk] If set to true this will delete all files associated
///   with the VM (if it alread exists).
///
/// * [userName] The username to create as part fo the kickstart installation.
///
/// * [sshKeyFile] The ssh key to install against the user that is created.
///
/// * [localAppData] The path to the local `AppData` dir.
Future<void> install([
  bool rebuild = false,
  String name = 'dev-server',
  String dir = '~/.hyperv',
  bool replaceDataDisk = false,
  @Env('USERNAME') String userName = 'packer',
  String sshKeyFile = '~/.ssh/id_rsa',
  @Env('LocalAppData') String localAppData,
  String sshConfigFile = '~/.ssh/config',
  String domain = 'hyper-v.local',
]) async {
  dir = normalisePath(dir);

  await uninstall(name, dir, replaceDataDisk, localAppData, sshConfigFile,
      domain, userName);

  var systemDiskSrc = File(p.absolute(
    'src',
    'output-hyperv-iso',
    'Virtual Hard Disks',
    'packer-hyperv-iso.vhdx',
  ));

  var dataDiskSrc = File(p.absolute(
    'src',
    'output-hyperv-iso',
    'Virtual Hard Disks',
    'packer-hyperv-iso-0.vhdx',
  ));

  if (!await systemDiskSrc.exists() || rebuild) {
    await build(userName, sshKeyFile);
  }

  log('registering new instance of vm: ${name}');
  await powershell('''
    New-VM -Name "${name}" `
      -NoVHD `
      -Generation 2 `
      -SwitchName "Default Switch" `
      -Path "${dir}";
  ''');

  var copyJobs = [
    systemDiskSrc.copy(p.join(
      dir,
      name,
      'system.vhdx',
    )),
  ];

  if (!await File(p.join(dir, name, 'data.vhdx')).exists()) {
    copyJobs.add(dataDiskSrc.copy(p.join(
      dir,
      name,
      'data.vhdx',
    )));
  }

  log('copying src disk images to new instance');
  await Future.wait(copyJobs);

  log('configuring vm instance');
  await powershell('''
    Set-VMProcessor "${name}" `
      -Count 2 `
      -ExposeVirtualizationExtensions \$true;

    Set-VMMemory "${name}" `
      -DynamicMemoryEnabled \$true `
      -MinimumBytes 64MB `
      -StartupBytes 256MB `
      -MaximumBytes 8GB `
      -Priority 80 `
      -Buffer 25;

    \$bootDrive = Add-VMHardDiskDrive "${name}" `
      -Path "${p.join(dir, name, 'system.vhdx')}" `
      -Passthru;

    Add-VMHardDiskDrive "${name}" `
      -Path "${p.join(dir, name, 'data.vhdx')}";

    Set-VMFirmware "${name}" `
      -EnableSecureBoot Off `
      -FirstBootDevice \$bootDrive;

    Enable-VMIntegrationService "${name}" -Name "Guest Service Interface";

    Set-VM -Name "${name}" `
      -CheckpointType Disabled `
      -AutomaticStartAction Start `
      -AutomaticStopAction Shutdown;
  ''');

  await start(name);
  await updateHostsFile(name, domain);
  await installHostUpdater(name, domain, userName);
  await installSshConfig(name, domain, sshConfigFile, userName, sshKeyFile);
  await installWindowsTerminalEntry(name, localAppData);
  await waitForSsh(name);
  await setGuestHostname(name, domain);
  await authorizeGuestToSshToHost(name, domain, userName);
  await ssh_server.install();
  await mountNfsShare(name, domain, userName);
}

/// Removes an instance of the VM.
///
/// * [name] The name of new VM to create in Hyper-V.
///
/// * [dir] The parent directory where the VM files will be kept.
///
/// * [deleteEverything] If set to true this will delete all files associated
///   with the VM (if it alread exists), including all disks.
Future<void> uninstall([
  String name = 'dev-server',
  String dir = '~/.hyperv',
  bool deleteEverything = false,
  @Env('LocalAppData') String localAppData,
  String sshConfigFile = '~/.ssh/config',
  String domain = 'hyper-v.local',
  @Env('USERNAME') String userName = 'packer',
]) async {
  if (await vmExists(name)) {
    log('unregistering vm: ${name}');
    await stop(name);
    await powershell('Remove-VM "${name}" -Force');
  }

  await uninstallHostUpdater(name);
  await uninstallSshConfig(name, sshConfigFile);
  await uninstallWindowsTerminalEntry(name, localAppData);
  await unauthorizeGuestToSshToHost(name, domain, userName);
  await ssh_server.uninstall();
  await unmountNfsShare(name, domain, userName);
  if (deleteEverything) {
    log('deleting ${p.join(normalisePath(dir), name)}');
    await Directory(p.join(normalisePath(dir), name)).delete(recursive: true);
  }
}

/// Starts the Virtual Machine
///
/// * [name] The name of new VM to start.
Future<void> start([String name = 'dev-server']) async {
  log('starting: ${name}');
  await powershell('Start-VM "${name}"');
}

/// Stops the Virtual Machine
///
/// * [name] The name of new VM to stop.
Future<void> stop([String name = 'dev-server']) async {
  log('stopping: ${name}');
  await powershell('Stop-VM "${name}" -Force');
}

/// Prints the IP Address of a running VM.
///
/// * [name] The name of new VM to query it's IP Address.
Future<String> ipAddress([String name = 'dev-server']) async {
  return await retry(() async {
    try {
      log('attempting to get ip address of: ${name}');

      var result = await powershell(
        '''
        Get-VM "${name}" | `
          Select-Object -ExpandProperty NetworkAdapters | `
          Select-Object IPAddresses;
        ''',
        inheritStdio: false,
      );

      var doc = xml.parse(result.stdout.replaceFirst('#< CLIXML', ''));
      var ipAddresses = doc.descendants
          .singleWhere((n) => n.attributes
              .any((a) => a.name.local == 'N' && a.value == 'IPAddresses'))
          .children
          .singleWhere((n) => n is xml.XmlElement && n.name.local == 'LST')
          .children
          .map((n) => n.text);

      var address = ipAddresses.first;
      if (address.contains(':') && !address.contains('.')) {
        throw Exception('not ipv4');
      }

      log(address);
      return ipAddresses.first;
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception(e);
    }
  });
}

/// Injects a new host file entry for a running VM.
///
/// * [name] The name of new VM to add to your hosts file.
Future<void> updateHostsFile([
  String name = 'dev-server',
  String domain = 'hyper-v.local',
  String ip = '',
  @Env('USERNAME') String userName = 'packer',
  bool dontRunTasks = false,
]) async {
  ip = ip == '' ? await ipAddress(name) : ip;

  if (!await isElevated()) {
    log('elevating to write host file');

    await powershell(
      '''
      ${Platform.resolvedExecutable} ${p.absolute('Makefile.dart')} `
        update-hosts-file `
          --name ${name} `
          --domain ${domain} `
          --ip ${ip} `
          --user-name ${userName}
          --dont-run-tasks;
      ''',
      elevated: true,
    );

    await clearKnownHosts(name);
    return;
  }

  log('updating hosts file');

  var hostsFile = File('C:\\Windows\\System32\\Drivers\\etc\\hosts');

  var newLines = [];
  for (var line in await hostsFile.readAsLines()) {
    if (line.contains(name)) {
      continue;
    }
    newLines.add(line);
  }
  newLines.add('${ip} ${name}.${domain}');

  log(newLines.join('\n'));

  await hostsFile.writeAsString(newLines.join('\r\n'));

  if (!dontRunTasks) {
    await clearKnownHosts(name, 'C:\\Users\\${userName}\\.ssh\\known_hosts');
  }
}

/// Injects a new profile into the Windows Terminal Config.
///
/// This profile will use SSH to connect to the VM.
/// see: https://aka.ms/terminal-documentation
///
/// * [name] The name of the VM that the new profile should connect to.
///
/// * [localAppData] The path to the local `AppData` dir.
Future<void> installWindowsTerminalEntry([
  String name = 'dev-server',
  @Env('LocalAppData') String localAppData,
]) async {
  log('installing windows terminal profile for vm: ${name}');

  await updateWindowsTerminalConfig(
    updater: (config) async {
      (config['profiles'] as List<dynamic>).insert(0, {
        'guid': '{${Uuid().v4()}}',
        'name': name,
        'commandline': 'ssh ${name}',
        'hidden': false,
        'fontSize': 10,
        'padding': '1',
        'icon': p.absolute('bash-icon.png'),
      });

      return config;
    },
    localAppData: localAppData,
  );
}

/// Removes a profile entry from the Windows Terminal config
///
/// * [name] The name of the VM to remove from Windows Terminal
///
/// * [localAppData] The path to the local `AppData` dir.
Future<void> uninstallWindowsTerminalEntry([
  String name = 'dev-server',
  @Env('LocalAppData') String localAppData,
]) async {
  log('uninstalling windows terminal profile for vm: ${name}');

  await updateWindowsTerminalConfig(
    updater: (config) async {
      (config['profiles'] as List<dynamic>)
          .removeWhere((profile) => profile['name'] == name);

      return config;
    },
    localAppData: localAppData,
  );
}

/// Removes entries from the SSH known_hosts file.
///
/// * [name] The name of the VM that will be removed from the file.
///
/// * [knownHostsFile] Location of the file to edit.
Future<void> clearKnownHosts([
  String name = 'dev-server',
  String knownHostsFile = '~/.ssh/known_hosts',
]) async {
  log('clearing ${knownHostsFile} file');

  var knownHosts = File(normalisePath(knownHostsFile));

  var newLines = [];
  for (var line in await knownHosts.readAsLines()) {
    if (line.contains(name)) continue;
    newLines.add(line);
  }

  await knownHosts.writeAsString(newLines.join('\r\n'));
}

/// Creates a new Scheduled Task that will run on boot to update the hosts file.
///
/// * [name] The name or the VM to create the task for.
Future<void> installHostUpdater([
  String name = 'dev-server',
  String domain = 'hyper-v.local',
  @Env('USERNAME') String userName = 'packer',
]) async {
  log('install host updater');

  await powershell('''
    \$Stt = New-ScheduledTaskTrigger -AtStartup;

    \$Sta = New-ScheduledTaskAction `
      -Execute "${Platform.resolvedExecutable}" `
      -Argument "${p.absolute('Makefile.dart')} update-hosts-file --name ${name} --domain ${domain} --user-name ${userName}" `
      -WorkingDirectory "${p.current}";

    \$STPrincipal = New-ScheduledTaskPrincipal `
      -UserID "NT AUTHORITY\\SYSTEM" `
      -LogonType ServiceAccount `
      -RunLevel Highest;

    Register-ScheduledTask "VMUpdateHostFile for ${name}" `
      -Principal \$STPrincipal `
      -Trigger \$Stt `
      -Action \$Sta;

    sleep 3;
  ''', elevated: true);
}

/// Removes the Scheduled Task that runs on boot to update the hosts file.
Future<void> uninstallHostUpdater([String name = 'dev-server']) async {
  log('uninstall host updater');

  await powershell('''
    Unregister-ScheduledTask "VMUpdateHostFile for ${name}" -Confirm:\$false;
  ''', elevated: true);
}

/// Inserts a new entry into ~/.ssh/config
Future<void> installSshConfig([
  String name = 'dev-server',
  String domain = 'hyper-v.local',
  String sshConfigFile = '~/.ssh/config',
  @Env('USERNAME') String userName = 'packer',
  String sshKeyFile = '~/.ssh/id_rsa',
]) async {
  log(
    'inserting a new entry for ${name} into ${normalisePath(sshConfigFile)}',
  );

  var sshConfig = File(normalisePath(sshConfigFile));
  var config = await sshConfig.readAsString();
  config = '''
${config}

Host ${name}
  HostName ${name}.${domain}
  User ${userName}
  IdentityFile ${normalisePath(sshKeyFile)}
''';

  await sshConfig.writeAsString(config);
}

/// Removes an entry from ~/.ssh/config
Future<void> uninstallSshConfig([
  String name = 'dev-server',
  String sshConfigFile = '~/.ssh/config',
]) async {
  log('removing the ${name} entry from ${normalisePath(sshConfigFile)}');

  var sshConfig = File(normalisePath(sshConfigFile));

  var skip = false;
  var newLines = [];
  for (var line in await sshConfig.readAsLines()) {
    if (line.startsWith('Host')) skip = false;
    if (line == 'Host ${name}' || skip) {
      skip = true;
      continue;
    }
    newLines.add(line);
  }

  await sshConfig.writeAsString(newLines.join('\r\n'));
}

/// Logs into the guest and configures it's internal hostname.
///
/// This relys on [installSshConfig]
Future<void> setGuestHostname([
  String name = 'dev-server',
  String domain = 'hyper-v.local',
]) async {
  log('sudo hostnamectl set-hostname ${name}.${domain}');

  await dexeca('ssh', [
    '-o',
    'StrictHostKeyChecking=no',
    name,
    'sudo',
    'hostnamectl',
    'set-hostname',
    '${name}.${domain}',
  ]);
}

/// Inserts the guest's public key into the host's authorized_keys file.
///
/// This will execute `ssh-keygen` and replace any pre-existing key at
/// `~/.ssh/id_rsa`.
///
/// This relys on [installSshConfig]
Future<void> authorizeGuestToSshToHost([
  String name = 'dev-server',
  String domain = 'hyper-v.local',
  @Env('USERNAME') String userName = 'packer',
]) async {
  var comment = '${userName}@${name}.${domain}';

  log('rm -f ~/.ssh/id_rsa');
  await dexeca('ssh', [
    '-o',
    'StrictHostKeyChecking=no',
    name,
    'rm',
    '-f',
    '~/.ssh/id_rsa',
  ]);

  log('rm -f ~/.ssh/id_rsa.pub');
  await dexeca('ssh', [
    '-o',
    'StrictHostKeyChecking=no',
    name,
    'rm',
    '-f',
    '~/.ssh/id_rsa.pub',
  ]);

  log('ssh-keygen -t rsa -b 4096 -C ${comment} -N "" -f ~/.ssh/id_rsa');
  await dexeca('ssh', [
    '-o',
    'StrictHostKeyChecking=no',
    name,
    'ssh-keygen',
    '-t',
    'rsa',
    '-b',
    '4096',
    '-C',
    comment,
    '-N',
    '""',
    '-f',
    '~/.ssh/id_rsa',
  ]);

  log('injecting guest public key into host ~/.ssh/authorized_keys file');
  var result = await dexeca(
    'ssh',
    [
      '-o',
      'StrictHostKeyChecking=no',
      name,
      'cat',
      '~/.ssh/id_rsa.pub',
    ],
    inheritStdio: false,
  );

  var pubKey = result.stdout.trim();
  var authKeysFile = File(normalisePath('~/.ssh/authorized_keys'));

  var newLines = <String>[];
  if (await authKeysFile.exists()) {
    for (var line in await authKeysFile.readAsLines()) {
      if (line.contains(comment)) continue;
      newLines.add(line);
    }
  }
  newLines.add(pubKey);

  await authKeysFile.writeAsString(newLines.join('\n'));
}

/// Removes the guest's public key from the host's authorized_keys file.
///
/// This leaves the guest's key intact, it only removes it from the host's
/// `~/.ssh/authorized_keys` file.
///
/// This relys on [installSshConfig]
Future<void> unauthorizeGuestToSshToHost([
  String name = 'dev-server',
  String domain = 'hyper-v.local',
  @Env('USERNAME') String userName = 'packer',
]) async {
  var comment = '${userName}@${name}.${domain}';
  var authKeysFile = File(normalisePath('~/.ssh/authorized_keys'));

  if (!await authKeysFile.exists()) {
    log('${authKeysFile.path} does not exist, nothign to do');
    return;
  }

  var newLines = <String>[];
  if (await authKeysFile.exists()) {
    for (var line in await authKeysFile.readAsLines()) {
      if (line.contains(comment)) continue;
      newLines.add(line);
    }
  }

  await authKeysFile.writeAsString(newLines.join('\n'));
  log('removed ${comment} from ${authKeysFile.path}');
}

Future<void> mountNfsShare([
  String name = 'dev-server',
  String domain = 'hyper-v.local',
  @Env('USERNAME') String userName = 'packer',
]) async {
  if (!await nfsClientInstalled()) {
    log('installing nfs client');
    await powershell('''
    Enable-WindowsOptionalFeature -FeatureName NFS-Administration -All -Online;
    Enable-WindowsOptionalFeature -FeatureName ClientForNFS-Infrastructure -All -Online;
    Enable-WindowsOptionalFeature -FeatureName ServicesForNFS-ClientOnly -All -Online;
    Set-ItemProperty -Path HKLM:\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default -Name AnonymousUid -Value 1000 -Type DWord;
    Set-ItemProperty -Path HKLM:\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default -Name AnonymousGid -Value 1000 -Type DWord;
    ''', elevated: true);
  }

  var mounted = await isNfsMounted(name, domain, userName);
  if (mounted != null) {
    log('drive already mounted ${mounted.driveLetter}:\\ => nfs:${mounted.path}');
    return;
  }

  var driveLetter = await getNextFreeDriveLetter();
  var path = '\\\\${name}.${domain}\\home\\${userName}';

  log('mounting drive ${driveLetter}\\ => nfs:${path}');
  await dexeca(
    'net',
    ['use', driveLetter, path, '/persistent:yes'],
    runInShell: true,
  );
}

Future<void> unmountNfsShare([
  String name = 'dev-server',
  String domain = 'hyper-v.local',
  @Env('USERNAME') String userName = 'packer',
]) async {
  var mounted = await isNfsMounted(name, domain, userName);
  if (mounted == null) {
    log('could not find a drive to unmount');
    return;
  }
  log('un-mounting ${mounted.driveLetter}:\\');
  await dexeca('umount', ['${mounted.driveLetter}:', '-f'], runInShell: true);
}
