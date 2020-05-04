import 'dart:io';
import '../Makefile.utils.dart';
import '../Makefile.opts.dart';
import 'package:drun/drun.dart';
import 'package:path/path.dart' as p;

const _NSSM_SERVICE_NAME = 'wslhv-sshfs-mounter';

Future<void> main(List<String> argv) => drun(argv);

Future<void> install([bool reInstall = false]) async {
  await installScoopPackage('nssm');
  await installScoopPackage('winfsp-np', bucket: 'nonportable');
  await installScoopPackage('sshfs-np', bucket: 'nonportable');

  if (await nssmServiceExists(_NSSM_SERVICE_NAME)) {
    if (reInstall) {
      await uninstall();
    } else {
      log('${_NSSM_SERVICE_NAME} already installed, nothing to do');
      return;
    }
  }

  var logFile = normalisePath('./logs/${_NSSM_SERVICE_NAME}.txt');
  await Directory(p.dirname(logFile)).create(recursive: true);

  log('install nssm ${_NSSM_SERVICE_NAME} service');
  await powershell('''
    nssm install ${_NSSM_SERVICE_NAME} "C:\\Program Files\\SSHFS-Win\\bin\\sshfs-win.exe";
    nssm set ${_NSSM_SERVICE_NAME} Start SERVICE_AUTO_START;
    nssm set ${_NSSM_SERVICE_NAME} AppParameters "svc \\sshfs.k\\${Options.userName}@${Options.name} ${await getNextFreeDriveLetter()} ${await whoAmI()} -FC:\\Users\\${Options.userName}\\.ssh\\config";
    nssm set ${_NSSM_SERVICE_NAME} AppStdout "${logFile}";
    nssm set ${_NSSM_SERVICE_NAME} AppStderr "${logFile}";
    nssm set ${_NSSM_SERVICE_NAME} AppStopMethodSkip 14;
    nssm set ${_NSSM_SERVICE_NAME} AppStopMethodConsole 0;
    nssm set ${_NSSM_SERVICE_NAME} AppKillProcessTree 0;
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
