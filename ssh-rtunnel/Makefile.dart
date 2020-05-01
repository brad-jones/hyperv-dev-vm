import 'dart:io';
import '../Makefile.opts.dart';
import '../Makefile.utils.dart';
import 'package:drun/drun.dart';
import 'package:dexeca/dexeca.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> argv) => drun(argv);

String _name() => 'wslhv-ssh-rtunnel-${Options.name}';

Future<void> build() async {
  log('building ssh-rtunnel.exe');
  await dexeca(
    'go',
    ['build', '-v'],
    workingDirectory: normalisePath('./ssh-rtunnel'),
  );
}

Future<void> install([bool reInstall = false]) async {
  if (await nssmServiceExists(_name())) {
    if (reInstall) {
      await uninstall();
    } else {
      log('${_name()} already installed, nothing to do');
      return;
    }
  }

  await build();

  var logFile = normalisePath('./logs/${_name()}.txt');
  await Directory(p.dirname(logFile)).create(recursive: true);

  log('install nssm ${_name()} service');
  await powershell('''
    nssm install ${_name()} "${normalisePath('./ssh-rtunnel/ssh-rtunnel.exe')}";
    nssm set ${_name()} Start SERVICE_AUTO_START;
    nssm set ${_name()} AppStdout "${logFile}";
    nssm set ${_name()} AppStderr "${logFile}";
    nssm set ${_name()} AppStopMethodSkip 14;
    nssm set ${_name()} AppStopMethodConsole 0;
    nssm set ${_name()} AppKillProcessTree 0;
    nssm set ${_name()} AppEnvironmentExtra `
      REMOTE_SERVER=${Options.name}.${Options.domain}:22 `
      REMOTE_SERVER_USER=${Options.userName} `
      REMOTE_SERVER_KEY=${normalisePath('~/.ssh/id_rsa')};
    nssm start ${_name()} confirm;
  ''', elevated: true);
}

Future<void> uninstall() async {
  if (!await nssmServiceExists(_name())) {
    log('${_name()} does not exist, nothing to do');
    return;
  }

  log('remove nssm ${_name()} service');
  await powershell('''
    nssm stop ${_name()} confirm;
    nssm remove ${_name()} confirm;
  ''', elevated: true);
}

Future<void> start() async {
  log('starting nssm ${_name()} service');

  await powershell(
    'nssm start ${_name()} confirm',
    elevated: true,
  );
}

Future<void> stop() async {
  log('stopping nssm ${_name()} service');

  await powershell(
    'nssm stop ${_name()} confirm',
    elevated: true,
  );
}

// sudo kill $(sudo lsof -t -i:2222)
// https://superuser.com/questions/1194105/ssh-troubleshooting-remote-port-forwarding-failed-for-listen-port-errors
