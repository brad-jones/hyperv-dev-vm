import 'dart:io';
import '../Makefile.utils.dart';
import 'package:drun/drun.dart';
import 'package:dexeca/dexeca.dart';
import 'package:path/path.dart' as p;

// with respect to doing this the other way around. ie: mounting the c driver inside the vm.
// To get sshd working prioperly we have toi do https://github.com/PowerShell/Win32-OpenSSH/issues/1027#issuecomment-359449663
// the scoop instalation failed to run sshd properly
// And then the next issue is that sshd will not authenticate a domain account when not connected to a domain controller. ie: the vpn need to be up
// so we could create a `localbrad` and give that user permissions to my `brad.jones` home dir but this seems hacky
// we could look at https://github.com/pkg/sftp/blob/master/examples/go-sftp-server/main.go
// and possibly https://github.com/hectane/go-acl to resolve file permissions issues related to running the SFTP server as SYSTEM

const _NSSM_SERVICE_NAME = 'wslhv-sftp-server';

Future<void> main(List<String> argv) => drun(argv);

Future<void> build() async {
  log('building sftp-server.exe');
  await dexeca(
    'go',
    ['build', '-v'],
    workingDirectory: normalisePath('./sftp-server'),
  );
}

Future<void> install([bool reInstall = false]) async {
  await installScoopPackage('nssm');

  if (await nssmServiceExists(_NSSM_SERVICE_NAME)) {
    if (reInstall) {
      await uninstall();
    } else {
      log('${_NSSM_SERVICE_NAME} already installed, nothing to do');
      return;
    }
  }

  await build();

  var logFile = normalisePath('./logs/${_NSSM_SERVICE_NAME}.txt');
  await Directory(p.dirname(logFile)).create(recursive: true);

  log('install nssm ${_NSSM_SERVICE_NAME} service');
  await powershell('''
    nssm install ${_NSSM_SERVICE_NAME} "${normalisePath('./sftp-server/sftp-server.exe')}";
    nssm set ${_NSSM_SERVICE_NAME} Start SERVICE_AUTO_START;
    nssm set ${_NSSM_SERVICE_NAME} AppStdout "${logFile}";
    nssm set ${_NSSM_SERVICE_NAME} AppStderr "${logFile}";
    nssm set ${_NSSM_SERVICE_NAME} AppStopMethodSkip 14;
    nssm set ${_NSSM_SERVICE_NAME} AppStopMethodConsole 0;
    nssm set ${_NSSM_SERVICE_NAME} AppKillProcessTree 0;
    nssm set ${_NSSM_SERVICE_NAME} AppDirectory "${normalisePath('~/')}";
    nssm set ${_NSSM_SERVICE_NAME} AppEnvironmentExtra `
      SSH_PORT=2223 `
      SSH_HOST_KEY_PATH=${normalisePath('~/.ssh/host_key')} `
      SSH_AUTHORIZED_KEYS_PATH=${normalisePath('~/.ssh/authorized_keys')};
    nssm start ${_NSSM_SERVICE_NAME} confirm;
  ''', elevated: true);
}

/// Stops and removes the nssm background service that runs the ssh server.
Future<void> uninstall() async {
  if (!await nssmServiceExists(_NSSM_SERVICE_NAME)) {
    log('${_NSSM_SERVICE_NAME} does not exist, nothing to do');
    return;
  }

  log('remove nssm ${_NSSM_SERVICE_NAME} service');
  await powershell('''
    nssm stop ${_NSSM_SERVICE_NAME} confirm;
    nssm remove ${_NSSM_SERVICE_NAME} confirm;
  ''', elevated: true);

  await del('./logs/${_NSSM_SERVICE_NAME}.txt');
}

/// Starts the nssm ssh background service.
Future<void> start() async {
  log('starting nssm ${_NSSM_SERVICE_NAME} service');

  await powershell(
    'nssm start ${_NSSM_SERVICE_NAME} confirm',
    elevated: true,
  );
}

/// Stops the nssm ssh background service.
Future<void> stop() async {
  log('stopping nssm ${_NSSM_SERVICE_NAME} service');

  await powershell(
    'nssm stop ${_NSSM_SERVICE_NAME} confirm',
    elevated: true,
  );
}
