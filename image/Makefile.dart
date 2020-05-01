import 'dart:io';
import 'dart:convert';
import '../Makefile.opts.dart';
import 'package:drun/drun.dart';
import 'package:yaml/yaml.dart';
import '../Makefile.utils.dart';
import 'package:dexeca/dexeca.dart';
import 'package:path/path.dart' as p;

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
  var packerFilePath = normalisePath('./image/Packerfile.yml');
  var kickStartTplPath = normalisePath('./image/ks.cfg.tpl');

  var variables = {
    'tag': Options.tag,
    'ssh_username': Options.userName,
    'ssh_private_key_file': Options.sshKeyFile,
    'ssh_public_key':
        (await File('${Options.sshKeyFile}.pub').readAsString()).trim(),
  };

  await firewallOpen();

  log('parsing ${packerFilePath}');
  Map<String, dynamic> packerFile = json.decode(json.encode(loadYaml(
    await File(packerFilePath).readAsString(),
  )));

  log('injecting variables into packerfile');
  packerFile['min_packer_version'] = await getToolVersion('packer');
  for (var e in variables.entries) {
    packerFile['variables'][e.key] = e.value;
  }

  log('generating ${kickStartTplPath} => ${kickStartTplPath.replaceFirst('.tpl', '')}');
  var tpl = await File(kickStartTplPath).readAsString();
  for (var e in variables.entries) {
    tpl = tpl.replaceAll('{{${e.key}}}', e.value);
  }
  await File(kickStartTplPath.replaceFirst('.tpl', '')).writeAsString(tpl);

  log('starting packer');
  var packer = dexeca(
    'packer',
    ['build', '-force', '-'],
    workingDirectory: p.dirname(packerFilePath),
  );

  packer.stdin.writeln(jsonEncode(packerFile));
  await packer.stdin.flush();
  await packer.stdin.close();

  await packer;

  log('cleanup ${kickStartTplPath.replaceFirst('.tpl', '')}');
  await File(kickStartTplPath.replaceFirst('.tpl', '')).delete();

  await firewallClose();
}
