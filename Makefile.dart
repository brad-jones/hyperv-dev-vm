import 'dart:async';
import 'dart:cli';
import 'dart:convert';
import 'dart:io';
import 'package:dexeca/dexeca.dart';
import 'package:drun/drun.dart';
import 'package:path/path.dart' as p;
import 'package:pretty_json/pretty_json.dart';
import 'package:retry/retry.dart';
import 'package:utf/utf.dart';
import 'package:uuid/uuid.dart';
import 'package:xml/xml.dart' as xml;
import 'package:yaml/yaml.dart';

Future<void> main(List<String> argv) => drun(argv);

/// Run this before running [build].
///
/// This allows HyperV guests to access the packer HTTP server.
/// Expect to see a UAC prompt as this opens an elevated powershell session.
Future<void> firewallOpen() async {
  print('opening firewall for packer');

  await _powershell('''
    New-NetFirewallRule `
      -DisplayName "packer_http_server" `
      -Direction Inbound `
      -Action Allow `
      -Protocol TCP `
      -LocalPort 8000-9000;
    sleep 1;
  ''', elevated: true);
}

/// This removes the firewall rule created by [firewallOpen].
///
/// Expect to see a UAC prompt as this opens an elevated powershell session.
Future<void> firewallClose() async {
  print('closing firewall for packer');

  await _powershell('''
    Remove-NetFirewallRule `
      -DisplayName "packer_http_server" `
      -Verbose;
    sleep 1;
  ''', elevated: true);
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
  if (!await _firewallRuleInstalled()) {
    await firewallOpen();
  }

  // Read in `./src/Packerfile.yml`.
  print('parsing Packerfile.yml');
  Map<String, dynamic> packerFile = json.decode(json.encode(loadYaml(
    await File(p.absolute('src', 'Packerfile.yml')).readAsString(),
  )));

  // Make the packerfile a little dynamic
  packerFile['min_packer_version'] = await _getToolVersion('packer');
  packerFile['builders'][0]['ssh_username'] = userName;
  packerFile['builders'][0]['ssh_private_key_file'] =
      _normalisePath(sshKeyFile);

  // Generate `./src/ks.cfg` from `./src/ks.cfg.tpl`.
  print('generating ks.cfg');
  var kickStart = await File(p.absolute('src', 'ks.cfg.tpl')).readAsString();
  kickStart = kickStart.replaceAll('{{username}}', userName);
  kickStart = kickStart.replaceAll(
    '{{sshkey}}',
    await () async {
      return (await File('${_normalisePath(sshKeyFile)}.pub').readAsString())
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
  print('cleanup ks.cfg');
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
]) async {
  dir = _normalisePath(dir);

  await uninstall(name, dir, replaceDataDisk, localAppData);

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

  print('registering new instance of vm: ${name}');
  await _powershell('''
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

  print('copying src disk images to new instance');
  await Future.wait(copyJobs);

  print('configuring vm instance');
  await _powershell('''
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
  await updateHostsFile(name);
  await installHostUpdater(name);
  await installWindowsTerminalEntry(name, userName, sshKeyFile, localAppData);
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
]) async {
  if (await _vmExists(name)) {
    await stop(name);
    print('unregistering vm: ${name}');
    await _powershell('Remove-VM "${name}" -Force');
    await uninstallHostUpdater(name);
    await uninstallWindowsTerminalEntry(name, localAppData);
    if (deleteEverything) {
      print('deleting ${p.join(_normalisePath(dir), name)}');
      await Directory(p.join(_normalisePath(dir), name))
          .delete(recursive: true);
    }
  } else {
    print('vm does not exist nothing to uninstall');
  }
}

/// Starts the Virtual Machine
///
/// * [name] The name of new VM to start.
Future<void> start([String name = 'dev-server']) async {
  print('starting: ${name}');
  await _powershell('Start-VM "${name}"');
}

/// Stops the Virtual Machine
///
/// * [name] The name of new VM to stop.
Future<void> stop([String name = 'dev-server']) async {
  print('stopping: ${name}');
  await _powershell('Stop-VM "${name}" -Force');
}

/// Prints the IP Address of a running VM.
///
/// * [name] The name of new VM to query it's IP Address.
Future<String> ipAddress([String name = 'dev-server']) async {
  return await retry(() async {
    try {
      print('attempting to get ip address of: ${name}');

      var result = await _powershell(
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

      print(address);
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
  String ip = '',
]) async {
  ip = ip == '' ? await ipAddress(name) : ip;

  if (!await _isElevated()) {
    print('elevating to write host file');

    await _powershell(
      '''
      ${Platform.resolvedExecutable} ${p.absolute('Makefile.dart')} `
        update-hosts-file --name ${name} --ip ${ip};
      sleep 1;
      ''',
      elevated: true,
    );
    return;
  }

  print('updating hosts file');

  var hostsFile = File('C:\\Windows\\System32\\Drivers\\etc\\hosts');

  var newLines = [];
  for (var line in await hostsFile.readAsLines()) {
    if (line.contains(name)) {
      continue;
    }
    newLines.add(line);
  }
  newLines.add('${ip} ${name}');

  print(newLines.join('\n'));

  await hostsFile.writeAsString(newLines.join('\r\n'));

  await clearKnownHosts(name);
}

/// Injects a new profile into the Windows Terminal Config.
///
/// This profile will use SSH to connect to the VM.
/// see: https://aka.ms/terminal-documentation
///
/// * [name] The name of the VM that the new profile should connect to.
///
/// * [userName] The user used to the connect via SSH to the VM.
///
/// * [sshKeyFile] The path to the SSH Key to use to connect to the VM.
///
/// * [localAppData] The path to the local `AppData` dir.
Future<void> installWindowsTerminalEntry([
  String name = 'dev-server',
  @Env('USERNAME') String userName = 'packer',
  String sshKeyFile = '~/.ssh/id_rsa',
  @Env('LocalAppData') String localAppData,
]) async {
  print('installing windows terminal profile for vm: ${name}');

  await _updateWindowsTerminalConfig(
    updater: (config) async {
      (config['profiles'] as List<dynamic>).insert(0, {
        'guid': '{${Uuid().v4()}}',
        'name': name,
        'commandline':
            'ssh -i ${_normalisePath(sshKeyFile)} ${userName}@${name}',
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
  print('uninstalling windows terminal profile for vm: ${name}');

  await _updateWindowsTerminalConfig(
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
  print('clearing ${knownHostsFile} file');

  var knownHosts = File(_normalisePath(knownHostsFile));

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
Future<void> installHostUpdater([String name = 'dev-server']) async {
  print('install host updater');

  await _powershell('''
    \$Stt = New-ScheduledTaskTrigger -AtStartup;

    \$Sta = New-ScheduledTaskAction `
      -Execute "${Platform.resolvedExecutable}" `
      -Argument "${p.absolute('Makefile.dart')} update-hosts-file --name ${name}" `
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
  print('uninstall host updater');

  await _powershell('''
    Unregister-ScheduledTask "VMUpdateHostFile for ${name}" -Confirm:\$false;
  ''', elevated: true);
}

Future<void> _updateWindowsTerminalConfig({
  Future<dynamic> Function(dynamic) updater,
  String localAppData,
}) async {
  var configFile = File(p.join(
    localAppData,
    'Packages',
    'Microsoft.WindowsTerminal_8wekyb3d8bbwe',
    'LocalState',
    'profiles.json',
  ));

  if (!await configFile.exists()) {
    throw 'windows terminal does not appear to be installed, see: https://aka.ms/terminal-documentation';
  }

  var jsonWithoutComments = [];
  for (var line in await configFile.readAsLines()) {
    if (line.trimLeft().startsWith('//')) continue;
    jsonWithoutComments.add(line);
  }

  await configFile.writeAsString(
    prettyJson(
      await updater(
        jsonDecode(
          jsonWithoutComments.join(''),
        ),
      ),
    ),
  );
}

Future<String> _getToolVersion(String tool) async {
  return (await File(p.absolute('.${tool}-version')).readAsString()).trim();
}

Process _powershell(
  String script, {
  bool elevated = false,
  bool inheritStdio = true,
}) {
  if (elevated && !waitFor(_isElevated())) {
    return _powershell('''
    Start-Process powershell -Verb RunAs `
    -ArgumentList "-NoLogo", "-NoProfile", `
    "-EncodedCommand", "${base64.encode(encodeUtf16le(script))}";
    ''');
  }

  if (inheritStdio) {
    var tmpDir = p.normalize(Directory.systemTemp.createTempSync().path);
    File(p.join(tmpDir, 'script.ps1')).writeAsStringSync(script);

    var proc = dexeca(
      'powershell',
      [
        '-NoLogo',
        '-NoProfile',
        '-File',
        p.join(tmpDir, 'script.ps1'),
      ],
    );

    proc.whenComplete(() {
      if (tmpDir != null && Directory(tmpDir).existsSync()) {
        Directory(tmpDir).deleteSync(recursive: true);
      }
    });

    return proc;
  }

  return dexeca(
    'powershell',
    [
      '-NoLogo',
      '-NoProfile',
      '-Output',
      'XML',
      '-EncodedCommand',
      base64.encode(encodeUtf16le(script)),
    ],
    inheritStdio: false,
  );
}

Future<bool> _isElevated() async {
  var result = await _powershell(
    '''
      \$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent());
      \$currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);
    ''',
    inheritStdio: false,
  );

  var doc = xml.parse(result.stdout.replaceFirst('#< CLIXML', ''));
  var elevated = doc.descendants
          .singleWhere((n) => n.attributes
              .any((a) => a.name.local == 'S' && a.value == 'Output'))
          .text ==
      'true';

  return elevated;
}

String _normalisePath(String input) {
  return p.normalize(
    input.replaceFirst(
      '~',
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'],
    ),
  );
}

Future<bool> _vmExists(String name) async {
  try {
    await _powershell('Get-VM "${name}"', inheritStdio: false);
  } on ProcessResult {
    return false;
  }
  return true;
}

Future<bool> _firewallRuleInstalled() async {
  try {
    await _powershell(
      'Get-NetFirewallRule -DisplayName "packer_http_server"',
      inheritStdio: false,
    );
  } on ProcessResult {
    return false;
  }
  return true;
}
