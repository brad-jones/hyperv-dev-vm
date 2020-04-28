import 'dart:io';
import 'dart:async';
import './Makefile.opts.dart';
import './Makefile.utils.dart';
import 'package:drun/drun.dart';
import 'package:uuid/uuid.dart';
import 'package:dexeca/dexeca.dart';
import './ec2/Makefile.dart' as ec2;
import 'package:path/path.dart' as p;
import './hyperv/Makefile.dart' as hyperv;
import './ssh-server/Makefile.dart' as ssh;
import './ec2/servercore/Makefile.dart' as servercore;

Future<void> main(List<String> argv) => drun(argv);

Future<void> install([
  bool rebuild = false,
  bool replaceDataDisk = false,
]) async {
  await uninstall(replaceDataDisk);

  switch (Options.type) {
    case 'hyperv':
      await hyperv.install(rebuild, replaceDataDisk);
      break;
    case 'ec2':
      await ec2.install(rebuild);
      break;
    case 'servercore':
      await servercore.install(rebuild);
      break;
  }

  await ssh.install();
  await updateHostsFile();
  await installHostUpdater();
  await installSshConfig();
  await installWindowsTerminalEntry();
  await waitForSsh(Options.name);
  await setGuestHostname();
  await authorizeGuestToSshToHost();
  if (Options.type == 'hyperv') await mountNfsShare();
  //await executeFirstLogin();
}

Future<void> uninstall([
  bool deleteEverything = false,
]) async {
  if (Options.type == 'hyperv') await unmountNfsShare();
  await uninstallHostUpdater();
  await uninstallSshConfig();
  await uninstallWindowsTerminalEntry();
  await unauthorizeGuestToSshToHost();

  switch (Options.type) {
    case 'hyperv':
      await hyperv.uninstall(deleteEverything);
      break;
    case 'ec2':
      await ec2.uninstall(deleteEverything);
      break;
    case 'servercore':
      await servercore.uninstall(deleteEverything);
      break;
  }

  if (deleteEverything) {
    await ssh.uninstall();
  }
}

/// Injects a new host file entry for a running VM.
Future<void> updateHostsFile([
  String ip = '',
  bool dontRunTasks = false,
]) async {
  if (ip == '') {
    switch (Options.type) {
      case 'hyperv':
        ip = await hyperv.ipAddress();
        break;
      case 'ec2':
        ip = await ec2.ipAddress();
        break;
      case 'servercore':
        ip = await servercore.ipAddress();
        break;
    }
  }

  if (!await isElevated()) {
    log('elevating to write host file');

    await powershell(
      '''
      cd ${Options.repoRoot};
      drun update-hosts-file `
        --type ${Options.type} `
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

Future<void> mountNfsShare() async {
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

  var mounted =
      await isNfsMounted(Options.name, Options.domain, Options.userName);
  if (mounted != null) {
    log('drive already mounted ${mounted.driveLetter}:\\ => nfs:${mounted.path}');
    return;
  }

  var driveLetter = await getNextFreeDriveLetter();
  var path = '\\\\${Options.name}.${Options.domain}\\home\\${Options.userName}';

  log('mounting drive ${driveLetter}\\ => nfs:${path}');
  await dexeca(
    'net',
    ['use', driveLetter, path, '/persistent:yes'],
    runInShell: true,
  );
}

Future<void> unmountNfsShare() async {
  var mounted =
      await isNfsMounted(Options.name, Options.domain, Options.userName);
  if (mounted == null) {
    log('could not find a drive to unmount');
    return;
  }
  log('un-mounting ${mounted.driveLetter}:\\');
  await dexeca('umount', ['${mounted.driveLetter}:', '-f'], runInShell: true);
}

/// Creates a new Scheduled Task that will run on boot to update the hosts file.
Future<void> installHostUpdater() async {
  log('install host updater');

  await powershell('''
    \$Stt = New-ScheduledTaskTrigger -AtStartup;

    \$Sta = New-ScheduledTaskAction `
      -Execute "${Platform.resolvedExecutable}" `
      -Argument "${normalisePath('./Makefile.dart')} update-hosts-file --type ${Options.type} --name ${Options.name} --domain ${Options.domain} --user-name ${Options.userName}" `
      -WorkingDirectory "${normalisePath('./')}";

    \$STPrincipal = New-ScheduledTaskPrincipal `
      -UserID "NT AUTHORITY\\SYSTEM" `
      -LogonType ServiceAccount `
      -RunLevel Highest;

    Register-ScheduledTask "VMUpdateHostFile for ${Options.name}.${Options.domain}" `
      -Principal \$STPrincipal `
      -Trigger \$Stt `
      -Action \$Sta;
  ''', elevated: true);
}

/// Removes the Scheduled Task that runs on boot to update the hosts file.
Future<void> uninstallHostUpdater() async {
  log('uninstall host updater');

  await powershell('''
    Unregister-ScheduledTask "VMUpdateHostFile for ${Options.name}.${Options.domain}" -Confirm:\$false;
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
        'hidden': false,
        'fontSize': 10,
        'padding': '1',
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

  log('rm -f ~/.ssh/id_rsa');
  await dexeca('ssh', [
    '-o',
    'StrictHostKeyChecking=no',
    Options.name,
    'rm',
    '-f',
    '~/.ssh/id_rsa',
  ]);

  log('rm -f ~/.ssh/id_rsa.pub');
  await dexeca('ssh', [
    '-o',
    'StrictHostKeyChecking=no',
    Options.name,
    'rm',
    '-f',
    '~/.ssh/id_rsa.pub',
  ]);

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
Future<void> unauthorizeGuestToSshToHost() async {
  var comment = '${Options.userName}@${Options.name}.${Options.domain}';
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

Future<void> executeFirstLogin() async {
  await dexeca('scp', [
    '-o',
    'StrictHostKeyChecking=no',
    p.absolute('first-login'),
    '${Options.name}:/tmp/script',
  ]);
  await dexeca('ssh', [
    '-o',
    'StrictHostKeyChecking=no',
    Options.name,
    'chmod',
    '+x',
    '/tmp/script',
  ]);
  await dexeca('ssh', [
    '-o',
    'StrictHostKeyChecking=no',
    Options.name,
    '/tmp/script',
  ]);
  await dexeca('ssh', [
    '-o',
    'StrictHostKeyChecking=no',
    Options.name,
    'rm',
    '-f',
    '/tmp/script',
  ]);
}
