import 'dart:io';
import '../Makefile.utils.dart';
import 'package:drun/drun.dart';
import 'package:dexeca/dexeca.dart';
import 'package:path/path.dart' as p;

const _NSSM_SERVICE_NAME = 'wslhv-ssh-server';

Future<void> main(List<String> argv) => drun(argv);

/// Builds an ssh server used to allow the guest vm to connect back to the host.
Future<void> build() async {
  log('building ssh-server.exe');
  await dexeca(
    'go',
    ['build', '-v'],
    workingDirectory: normalisePath('./ssh-server'),
  );
}

/// Using nssm, makes the ssh server run as a Windows background service.
///
/// > This assumes you have already installed <https://nssm.cc/>
Future<void> install([bool reInstall = false]) async {
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
    nssm install ${_NSSM_SERVICE_NAME} "${normalisePath('./ssh-server/ssh-server.exe')}";
    nssm reset ${_NSSM_SERVICE_NAME} ObjectName;
    nssm set ${_NSSM_SERVICE_NAME} Type SERVICE_INTERACTIVE_PROCESS;
    nssm set ${_NSSM_SERVICE_NAME} Start SERVICE_AUTO_START;
    nssm set ${_NSSM_SERVICE_NAME} AppStdout "${logFile}";
    nssm set ${_NSSM_SERVICE_NAME} AppStderr "${logFile}";
    nssm set ${_NSSM_SERVICE_NAME} AppStopMethodSkip 14;
    nssm set ${_NSSM_SERVICE_NAME} AppStopMethodConsole 0;
    nssm set ${_NSSM_SERVICE_NAME} AppKillProcessTree 0;
    nssm set ${_NSSM_SERVICE_NAME} AppEnvironmentExtra `
      "PATH=${Platform.environment['PATH']}" `
      SSH_PORT=22 `
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
