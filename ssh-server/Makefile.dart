import 'dart:io';
import '../Makefile.utils.dart';
import 'package:drun/drun.dart';
import 'package:dexeca/dexeca.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> argv) => drun(argv);

Future<void> build() async {
  log('building ssh-server.exe');
  await dexeca(
    'go',
    ['build', '-v'],
    workingDirectory: p.join(projectRoot(), 'ssh-server'),
  );
}

Future<void> install() async {
  await build();
  await firewallOpen();

  log('install nssm hyperv-dev-vm-host-sshd service');
  await powershell('''
    nssm stop hyperv-dev-vm-host-sshd confirm;
    nssm remove hyperv-dev-vm-host-sshd confirm;
    nssm install hyperv-dev-vm-host-sshd "${p.join(projectRoot(), 'ssh-server', 'ssh-server.exe')}";
    nssm reset hyperv-dev-vm-host-sshd ObjectName;
    nssm set hyperv-dev-vm-host-sshd Type SERVICE_INTERACTIVE_PROCESS;
    nssm set hyperv-dev-vm-host-sshd Start SERVICE_AUTO_START;
    nssm set hyperv-dev-vm-host-sshd AppStdout "${p.join(projectRoot(), 'ssh-server', 'log.txt')}";
    nssm set hyperv-dev-vm-host-sshd AppStderr "${p.join(projectRoot(), 'ssh-server', 'log.txt')}";
    nssm set hyperv-dev-vm-host-sshd AppStopMethodSkip 14;
    nssm set hyperv-dev-vm-host-sshd AppStopMethodConsole 0;
    nssm set hyperv-dev-vm-host-sshd AppKillProcessTree 0;
    nssm set hyperv-dev-vm-host-sshd AppEnvironmentExtra `
      "PATH=${Platform.environment['PATH']}" `
      SSH_PORT=22 `
      SSH_HOST_KEY_PATH=${normalisePath('~/.ssh/host_key')} `
      SSH_AUTHORIZED_KEYS_PATH=${normalisePath('~/.ssh/authorized_keys')};
    nssm start hyperv-dev-vm-host-sshd confirm;
  ''', elevated: true);
}

Future<void> uninstall() async {
  await firewallClose();

  log('remove nssm hyperv-dev-vm-host-sshd service');
  await powershell('''
    nssm stop hyperv-dev-vm-host-sshd confirm;
    nssm remove hyperv-dev-vm-host-sshd confirm;
  ''', elevated: true);
}

Future<void> start() async {
  log('starting nssm hyperv-dev-vm-host-sshd service');

  await powershell(
    'nssm start hyperv-dev-vm-host-sshd confirm',
    elevated: true,
  );
}

Future<void> stop() async {
  log('stopping nssm hyperv-dev-vm-host-sshd service');

  await powershell(
    'nssm stop hyperv-dev-vm-host-sshd confirm',
    elevated: true,
  );
}

/// Opens port 22 for SSH.
///
/// Expect to see a UAC prompt as this opens an elevated powershell session.
Future<void> firewallOpen() async {
  if (await firewallRuleInstalled('sshd')) {
    log('ssh firewall rule is already installed');
    return;
  }

  log('opening firewall for ssh');
  await powershell('''
    New-NetFirewallRule `
      -Name sshd `
      -DisplayName "OpenSSH Server (sshd)" `
      -Direction Inbound `
      -Action Allow `
      -Protocol TCP `
      -LocalPort 22;
  ''', elevated: true);
}

/// Close port 22 for SSH.
///
/// Expect to see a UAC prompt as this opens an elevated powershell session.
Future<void> firewallClose() async {
  if (!await firewallRuleInstalled('sshd')) {
    log('ssh firewall rule is not installed');
    return;
  }

  log('closing firewall for ssh');
  await powershell('Remove-NetFirewallRule sshd', elevated: true);
}
