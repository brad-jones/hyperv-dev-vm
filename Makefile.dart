import 'dart:io';
import 'dart:async';
import './Makefile.opts.dart';
import './Makefile.utils.dart';
import 'package:drun/drun.dart';
import 'package:uuid/uuid.dart';
import 'package:retry/retry.dart';
import 'package:dexeca/dexeca.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart' as xml;
import './image/Makefile.dart' as image;
import './ssh-server/Makefile.dart' as sshServer;
import './ssh-rtunnel/Makefile.dart' as sshTunnel;

Future<void> main(List<String> argv) => drun(argv);

/// Installs a new instance of the VM image.
///
/// * [rebuild] If an VM image already exists it will not normally be built
///   again unless this flag is set.
///
/// * [replaceDataDisk] If an instance already exists then the data disk will
///   normally not be replaced, you can force the deletion of this disk by using
///   this flag.
Future<void> install([
  bool rebuild = false,
  bool replaceDataDisk = false,
]) async {
  await uninstall(replaceDataDisk);

  var systemDiskSrc = File(p.join(
    Options.repoRoot,
    'image',
    Options.tag,
    'Virtual Hard Disks',
    'packer-hyperv-iso.vhdx',
  ));

  var dataDiskSrc = File(p.join(
    Options.repoRoot,
    'image',
    Options.tag,
    'Virtual Hard Disks',
    'packer-hyperv-iso-0.vhdx',
  ));

  if (!await systemDiskSrc.exists() || rebuild) {
    await image.build();
  }

  log('registering new instance of vm: ${Options.name}');
  await powershell('''
    New-VM -Name "${Options.name}" `
      -NoVHD `
      -Generation 2 `
      -SwitchName "Default Switch" `
      -Path "${Options.hyperVDir}";
  ''');

  var copyJobs = [
    systemDiskSrc.copy(p.join(
      Options.hyperVDir,
      Options.name,
      'system.vhdx',
    )),
  ];

  if (!await File(p.join(Options.hyperVDir, Options.name, 'data.vhdx'))
      .exists()) {
    copyJobs.add(dataDiskSrc.copy(p.join(
      Options.hyperVDir,
      Options.name,
      'data.vhdx',
    )));
  }

  log('copying src disk images to new instance');
  await Future.wait(copyJobs);

  log('configuring vm instance');
  await powershell('''
    Set-VMProcessor "${Options.name}" `
      -Count 2 `
      -ExposeVirtualizationExtensions \$true;

    Set-VMMemory "${Options.name}" `
      -DynamicMemoryEnabled \$true `
      -MinimumBytes 64MB `
      -StartupBytes 512MB `
      -MaximumBytes 8GB `
      -Priority 80 `
      -Buffer 25;

    \$bootDrive = Add-VMHardDiskDrive "${Options.name}" `
      -Path "${p.join(Options.hyperVDir, Options.name, 'system.vhdx')}" `
      -Passthru;

    Add-VMHardDiskDrive "${Options.name}" `
      -Path "${p.join(Options.hyperVDir, Options.name, 'data.vhdx')}";

    Set-VMFirmware "${Options.name}" `
      -EnableSecureBoot Off `
      -FirstBootDevice \$bootDrive;

    Enable-VMIntegrationService "${Options.name}" -Name "Guest Service Interface";

    Set-VM -Name "${Options.name}" `
      -CheckpointType Disabled `
      -AutomaticStartAction Start `
      -AutomaticStopAction Shutdown;
  ''');

  await start();
  await sshServer.install(rebuild);
  await updateHostsFile();
  await installHostUpdater();
  await installSshConfig();
  await installWindowsTerminalEntry();
  await waitForSsh(Options.name);
  await setGuestHostname();
  await authorizeGuestToSshToHost();
  await sshTunnel.install();
}

/// Removes an installed instance of the VM image.
///
/// * [deleteEverything] If set to true this will delete all files associated
///   with the VM (if it alread exists), including all disks.
Future<void> uninstall([bool deleteEverything = false]) async {
  if (await vmExists(Options.name)) {
    log('unregistering vm: ${Options.name}');
    await stop();
    await powershell('Remove-VM "${Options.name}" -Force');
  }

  await uninstallHostUpdater();
  await uninstallSshConfig();
  await uninstallWindowsTerminalEntry();
  await unauthorizeGuestToSshToHost();
  await sshTunnel.uninstall();

  if (deleteEverything) {
    await sshServer.uninstall();
    var dir = p.join(Options.hyperVDir, Options.name);
    log('deleting ${dir}');
    await del(dir);
  }
}

/// Starts the Virtual Machine
Future<void> start() async {
  if (!await vmExists(Options.name)) {
    log('can not start vm as it does not exist');
    throw Exception('vm not found');
  }
  log('starting: ${Options.name}');
  await powershell('Start-VM "${Options.name}"');
}

/// Stops the Virtual Machine
Future<void> stop() async {
  if (!await vmExists(Options.name)) {
    log('nothing to do, vm does not exist');
    return;
  }
  log('stopping: ${Options.name}');
  await powershell('Stop-VM "${Options.name}" -Force');
}

/// Prints the IP Address of a running VM.
Future<String> ipAddress() async {
  return await retry(() async {
    try {
      log('attempting to get ip address of: ${Options.name}.${Options.domain}');

      var result = await powershell(
        '''
        Get-VM "${Options.name}" | `
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
  }, maxAttempts: 100);
}

/// Injects a new host file entry for a running VM.
Future<void> updateHostsFile([
  String ip = '',
  bool dontRunTasks = false,
]) async {
  if (ip == '') {
    ip = await ipAddress();
  }

  if (!await isElevated()) {
    log('elevating to write host file');

    await powershell(
      '''
      cd ${Options.repoRoot};
      drun update-hosts-file `
        --name ${Options.name} `
        --domain ${Options.domain} `
        --ip ${ip} `
        --user-name ${Options.userName} `
        --dont-run-tasks;
      ''',
      elevated: true,
    );

    await clearKnownHosts();
    return;
  }

  log('updating hosts file');

  var hostsFile = File('C:\\Windows\\System32\\Drivers\\etc\\hosts');

  var newLines = [];
  for (var line in await hostsFile.readAsLines()) {
    if (line.contains(Options.name)) {
      continue;
    }
    newLines.add(line);
  }
  newLines.add('${ip} ${Options.name}.${Options.domain}');

  log(newLines.join('\n'));

  await hostsFile.writeAsString(newLines.join('\r\n'));

  if (!dontRunTasks) {
    await clearKnownHosts();
  }
}

/// Removes entries from the SSH known_hosts file.
Future<void> clearKnownHosts() async {
  log('clearing ${Options.sshKnownHostsFile} file');

  var knownHosts = File(Options.sshKnownHostsFile);

  var newLines = [];
  for (var line in await knownHosts.readAsLines()) {
    if (line.contains(Options.name)) continue;
    newLines.add(line);
  }

  await knownHosts.writeAsString(newLines.join('\r\n'));
}

/// Creates a new Scheduled Task that will run on boot to update the hosts file.
Future<void> installHostUpdater() async {
  log('Register-ScheduledTask wslhv-host-updater-${Options.name}');

  await powershell('''
    \$Stt = New-ScheduledTaskTrigger -AtStartup;

    \$Sta = New-ScheduledTaskAction `
      -Execute "${Platform.resolvedExecutable}" `
      -Argument "${normalisePath('./Makefile.dart')} update-hosts-file --name ${Options.name} --domain ${Options.domain} --user-name ${Options.userName}" `
      -WorkingDirectory "${normalisePath('./')}";

    \$STPrincipal = New-ScheduledTaskPrincipal `
      -UserID "NT AUTHORITY\\SYSTEM" `
      -LogonType ServiceAccount `
      -RunLevel Highest;

    Register-ScheduledTask "wslhv-host-updater-${Options.name}" `
      -Principal \$STPrincipal `
      -Trigger \$Stt `
      -Action \$Sta;
  ''', elevated: true);
}

/// Removes the Scheduled Task that runs on boot to update the hosts file.
Future<void> uninstallHostUpdater() async {
  log('Unregister-ScheduledTask wslhv-host-updater-${Options.name}');

  await powershell('''
    Unregister-ScheduledTask "wslhv-host-updater-${Options.name}" -Confirm:\$false;
  ''', elevated: true);
}

/// Inserts a new entry into ~/.ssh/config
Future<void> installSshConfig() async {
  log(
    'inserting a new entry for ${Options.name} into ${Options.sshConfigFile}',
  );

  var sshConfig = File(Options.sshConfigFile);
  var config = await sshConfig.readAsString();
  config = '''
${config}

Host ${Options.name}
  HostName ${Options.name}.${Options.domain}
  User ${Options.userName}
  IdentityFile ${Options.sshKeyFile}
  StrictHostKeyChecking no
''';

  await sshConfig.writeAsString(config);
}

/// Removes an entry from ~/.ssh/config
Future<void> uninstallSshConfig() async {
  log('removing the ${Options.name} entry from ${Options.sshConfigFile}');

  var sshConfig = File(Options.sshConfigFile);

  var skip = false;
  var newLines = [];
  for (var line in await sshConfig.readAsLines()) {
    if (line.startsWith('Host')) skip = false;
    if (line == 'Host ${Options.name}' || skip) {
      skip = true;
      continue;
    }
    newLines.add(line);
  }

  await sshConfig.writeAsString(newLines.join('\r\n'));
}

/// Injects a new profile into the Windows Terminal Config.
///
/// This profile will use SSH to connect to the VM.
/// see: https://aka.ms/terminal-documentation
Future<void> installWindowsTerminalEntry() async {
  log('installing windows terminal profile for vm: ${Options.name}');

  await updateWindowsTerminalConfig(
    updater: (config) async {
      (config['profiles']['list'] as List<dynamic>).insert(0, {
        'guid': '{${Uuid().v4()}}',
        'name': Options.name,
        'commandline': 'ssh ${Options.name}',
        'icon': normalisePath('./bash-icon.png'),
      });

      return config;
    },
    localAppData: Options.localAppData,
  );
}

/// Removes a profile entry from the Windows Terminal config
Future<void> uninstallWindowsTerminalEntry() async {
  log('uninstalling windows terminal profile for vm: ${Options.name}');

  await updateWindowsTerminalConfig(
    updater: (config) async {
      (config['profiles']['list'] as List<dynamic>)
          .removeWhere((profile) => profile['name'] == Options.name);

      return config;
    },
    localAppData: Options.localAppData,
  );
}

/// Inserts the guest's public key into the host's authorized_keys file.
///
/// This will execute `ssh-keygen` and replace any pre-existing key at
/// `~/.ssh/id_rsa`.
///
/// This relys on [installSshConfig]
Future<void> authorizeGuestToSshToHost() async {
  var comment = '${Options.userName}@${Options.name}.${Options.domain}';

  log('ssh-keygen -t rsa -b 4096 -C ${comment} -N "" -f ~/.ssh/id_rsa');
  await dexeca('ssh', [
    '-o',
    'StrictHostKeyChecking=no',
    Options.name,
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
      Options.name,
      'cat',
      '~/.ssh/id_rsa.pub',
    ],
    inheritStdio: false,
  );

  var pubKey = result.stdout.trim();
  var authKeysFile = File(Options.sshAuthorizedKeysFile);

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
Future<void> unauthorizeGuestToSshToHost() async {
  var comment = '${Options.userName}@${Options.name}.${Options.domain}';
  var authKeysFile = File(Options.sshAuthorizedKeysFile);

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

/// Logs into the guest and configures it's internal hostname.
///
/// This relys on [installSshConfig]
Future<void> setGuestHostname() async {
  log('sudo hostnamectl set-hostname ${Options.name}.${Options.domain}');

  await dexeca('ssh', [
    '-o',
    'StrictHostKeyChecking=no',
    Options.name,
    'sudo',
    'hostnamectl',
    'set-hostname',
    '${Options.name}.${Options.domain}',
  ]);
}
