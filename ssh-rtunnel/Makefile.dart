import 'dart:io';
import '../Makefile.opts.dart';
import '../Makefile.utils.dart';
import 'package:drun/drun.dart';
import 'package:dexeca/dexeca.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> argv) => drun(argv);

String _name(String port) => 'wslhv-ssh-rtunnel-${port}-${Options.name}';

Future<void> build() async {
  log('building ssh-rtunnel.exe');
  await dexeca(
    'go',
    ['build', '-v'],
    workingDirectory: normalisePath('./ssh-rtunnel'),
  );
}

Future<void> install([bool reInstall = false]) async {
  var binFile = normalisePath('./ssh-rtunnel/ssh-rtunnel.exe');

  if (reInstall) {
    await uninstall();
    await File(binFile).delete();
  }

  if (!await File(binFile).exists()) {
    await build();
  }

  if (await nssmServiceExists(_name('2222'))) {
    log('${_name('2222')} already installed, nothing to do');
  } else {
    var logFile = normalisePath('./logs/${_name('2222')}.txt');
    await Directory(p.dirname(logFile)).create(recursive: true);

    log('install nssm ${_name('2222')} service');
    await powershell('''
    nssm install ${_name('2222')} "${binFile}";
    nssm set ${_name('2222')} Start SERVICE_AUTO_START;
    nssm set ${_name('2222')} AppStdout "${logFile}";
    nssm set ${_name('2222')} AppStderr "${logFile}";
    nssm set ${_name('2222')} AppStopMethodSkip 14;
    nssm set ${_name('2222')} AppStopMethodConsole 0;
    nssm set ${_name('2222')} AppKillProcessTree 0;
    nssm set ${_name('2222')} AppEnvironmentExtra `
      LOCAL_ENDPOINT=127.0.0.1:2222 `
      REMOTE_ENDPOINT=127.0.0.1:2222 `
      REMOTE_SERVER=${Options.name}.${Options.domain}:22 `
      REMOTE_SERVER_USER=${Options.userName} `
      REMOTE_SERVER_KEY=${normalisePath('~/.ssh/id_rsa')};
    nssm start ${_name('2222')} confirm;
  ''', elevated: true);
  }

  if (await nssmServiceExists(_name('2223'))) {
    log('${_name('2223')} already installed, nothing to do');
  } else {
    var logFile = normalisePath('./logs/${_name('2223')}.txt');
    await Directory(p.dirname(logFile)).create(recursive: true);

    log('install nssm ${_name('2223')} service');
    await powershell('''
    nssm install ${_name('2223')} "${binFile}";
    nssm set ${_name('2223')} Start SERVICE_AUTO_START;
    nssm set ${_name('2223')} AppStdout "${logFile}";
    nssm set ${_name('2223')} AppStderr "${logFile}";
    nssm set ${_name('2223')} AppStopMethodSkip 14;
    nssm set ${_name('2223')} AppStopMethodConsole 0;
    nssm set ${_name('2223')} AppKillProcessTree 0;
    nssm set ${_name('2223')} AppEnvironmentExtra `
      LOCAL_ENDPOINT=127.0.0.1:2223 `
      REMOTE_ENDPOINT=127.0.0.1:2223 `
      REMOTE_SERVER=${Options.name}.${Options.domain}:22 `
      REMOTE_SERVER_USER=${Options.userName} `
      REMOTE_SERVER_KEY=${normalisePath('~/.ssh/id_rsa')};
    nssm start ${_name('2223')} confirm;
  ''', elevated: true);
  }
}

Future<void> uninstall() async {
  if (!await nssmServiceExists(_name('2222'))) {
    log('${_name('2222')} does not exist, nothing to do');
  } else {
    log('remove nssm ${_name('2222')} service');
    await powershell('''
    nssm stop ${_name('2222')} confirm;
    nssm remove ${_name('2222')} confirm;
  ''', elevated: true);

    await del('./logs/${_name('2222')}.txt');
  }

  if (!await nssmServiceExists(_name('2223'))) {
    log('${_name('2223')} does not exist, nothing to do');
  } else {
    log('remove nssm ${_name('2223')} service');
    await powershell('''
    nssm stop ${_name('2223')} confirm;
    nssm remove ${_name('2223')} confirm;
  ''', elevated: true);

    await del('./logs/${_name('2223')}.txt');
  }
}

Future<void> start() async {
  log('starting nssm ${_name('2222')} service');
  await powershell('nssm start ${_name('2222')} confirm', elevated: true);
  log('starting nssm ${_name('2223')} service');
  await powershell('nssm start ${_name('2223')} confirm', elevated: true);
}

Future<void> stop() async {
  log('stopping nssm ${_name('2222')} service');
  await powershell('nssm stop ${_name('2222')} confirm', elevated: true);
  log('stopping nssm ${_name('2223')} service');
  await powershell('nssm stop ${_name('2223')} confirm', elevated: true);
}
