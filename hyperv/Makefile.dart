import 'dart:io';

import 'package:drun/drun.dart';
import 'package:retry/retry.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart' as xml;

import '../Makefile.opts.dart';
import '../Makefile.utils.dart';

Future<void> main(List<String> argv) => drun(argv);

/// Opens the port range `8000-9000` used by the packer HTTP server.
///
/// Expect to see a UAC prompt as this opens an elevated powershell session.
Future<void> firewallOpen() async {
  if (await firewallRuleInstalled('packer_http_server')) {
    log('packer_http_server firewall rule is already installed');
    return;
  }

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

/// Closes the port range `8000-9000` used by the packer HTTP server.
///
/// Expect to see a UAC prompt as this opens an elevated powershell session.
Future<void> firewallClose() async {
  if (!await firewallRuleInstalled('packer_http_server')) {
    log('packer_http_server firewall rule is not installed');
    return;
  }

  log('closing firewall for packer');
  await powershell(
    'Remove-NetFirewallRule packer_http_server;',
    elevated: true,
  );
}

/// Using `packer` builds a new Hyper-V VM Image.
Future<void> build() async {
  await firewallOpen();
  await packerBuild(
    packerFilePath: normalisePath('./hyperv/Packerfile.yml'),
    tplFilePath: normalisePath('./hyperv/ks.cfg.tpl'),
    variables: {
      'tag': Options.tag,
      'ssh_username': Options.userName,
      'ssh_private_key_file': Options.sshKeyFile,
      'ssh_public_key':
          (await File('${Options.sshKeyFile}.pub').readAsString()).trim(),
    },
  );
  await firewallClose();
}

/// Creates a new Hyper-V instance of the built vm image.
///
/// If an instance of the same name already exists then it will upgraded
/// with the latest system disk and configuration. The data disk will be
/// left untouched.
///
/// * [rebuild] If set to true then a new build will always be performed
///
/// * [replaceDataDisk] If set to true this will delete all files associated
///   with the VM (if it alread exists).
Future<void> install([
  bool rebuild = false,
  bool replaceDataDisk = false,
]) async {
  await uninstall(replaceDataDisk);

  var systemDiskSrc = File(p.join(
    Options.repoRoot,
    'hyperv',
    'dev-server-${Options.tag}',
    'Virtual Hard Disks',
    'packer-hyperv-iso.vhdx',
  ));

  var dataDiskSrc = File(p.join(
    Options.repoRoot,
    'hyperv',
    'dev-server-${Options.tag}',
    'Virtual Hard Disks',
    'packer-hyperv-iso-0.vhdx',
  ));

  if (!await systemDiskSrc.exists() || rebuild) {
    await build();
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
}

/// Removes an instance of the VM.
///
/// * [deleteEverything] If set to true this will delete all files associated
///   with the VM (if it alread exists), including all disks.
Future<void> uninstall([bool deleteEverything = false]) async {
  if (await _vmExists(Options.name)) {
    log('unregistering vm: ${Options.name}');
    await stop();
    await powershell('Remove-VM "${Options.name}" -Force');
  }

  if (deleteEverything) {
    var dir = p.join(Options.hyperVDir, Options.name);
    log('deleting ${dir}');
    await Directory(dir).delete(recursive: true);
  }
}

/// Starts the Virtual Machine
Future<void> start() async {
  log('starting: ${Options.name}');
  await powershell('Start-VM "${Options.name}"');
}

/// Stops the Virtual Machine
Future<void> stop() async {
  log('stopping: ${Options.name}');
  await powershell('Stop-VM "${Options.name}" -Force');
}

/// Prints the IP Address of a running VM.
Future<String> ipAddress() async {
  return await retry(() async {
    try {
      log('attempting to get ip address of: ${Options.name}');

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

Future<bool> _vmExists(String name) async {
  try {
    await powershell('Get-VM "${name}"', inheritStdio: false);
  } on ProcessResult {
    return false;
  }
  return true;
}
