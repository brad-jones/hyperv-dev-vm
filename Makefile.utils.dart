import 'dart:io';
import 'dart:cli';
import 'dart:math';
import 'dart:convert';

import 'package:utf/utf.dart';
import 'package:yaml/yaml.dart';
import 'package:retry/retry.dart';
import 'package:dexeca/dexeca.dart';
import 'package:recase/recase.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart' as xml;
import 'package:ansicolor/ansicolor.dart';
import 'package:pretty_json/pretty_json.dart';
import 'package:stack_trace/stack_trace.dart';

import './Makefile.opts.dart';

String normalisePath(String input) {
  return p.normalize(
    input
        .replaceFirst(
          '~',
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'],
        )
        .replaceFirst(
          './',
          Options.repoRoot + '/',
        ),
  );
}

Future<String> getToolVersion(String tool) async {
  return (await File(normalisePath('./.${tool}-version')).readAsString())
      .trim();
}

Future<String> whoAmI() async {
  var result = await powershell('whoami', inheritStdio: false);
  var doc = xml.parse(result.stdout.replaceFirst('#< CLIXML', ''));
  return doc.descendants
      .singleWhere((n) =>
          n.attributes.any((a) => a.name.local == 'S' && a.value == 'Output'))
      .text;
}

Future<bool> firewallRuleInstalled(String name) async {
  try {
    await powershell(
      'Get-NetFirewallRule ${name}',
      inheritStdio: false,
    );
  } on ProcessResult {
    return false;
  }
  return true;
}

Future<void> waitForSsh(String name) async {
  await retry(() async {
    try {
      log('attempting to connect to: ${name}');
      await dexeca('ssh', [
        '-o',
        'StrictHostKeyChecking=no',
        name,
        'true',
      ]);
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception(e);
    }
  }, maxAttempts: 20);
}

Future<void> updateWindowsTerminalConfig({
  Future<dynamic> Function(dynamic) updater,
  String localAppData,
}) async {
  var configFile = File(p.join(
    localAppData,
    'Microsoft',
    'Windows Terminal',
    'settings.json',
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

Future<bool> nfsClientInstalled() async {
  try {
    await powershell(
      'nfsadmin.exe client /?',
      inheritStdio: false,
    );
  } on ProcessResult {
    return false;
  }
  return true;
}

Future<String> getNextFreeDriveLetter() async {
  var result = await powershell(
    'ls function:[d-z]: -n | ?{ !(test-path \$_) } | select -First 1',
    inheritStdio: false,
  );
  var doc = xml.parse(result.stdout.replaceFirst('#< CLIXML', ''));
  return doc.descendants
      .singleWhere((n) =>
          n.attributes.any((a) => a.name.local == 'S' && a.value == 'Output'))
      .text;
}

class Mounted {
  final String driveLetter;
  final String path;
  const Mounted(this.driveLetter, this.path);
}

Future<Mounted> isNfsMounted(
  String name,
  String domain,
  String userName,
) async {
  var path = '\\\\${name}.${domain}\\home\\${userName}';
  var result = await powershell('Get-PSDrive', inheritStdio: false);
  var doc = xml.parse(result.stdout.replaceFirst('#< CLIXML', ''));
  var mount = doc.descendants
      .where((n) => n.attributes
          .any((a) => a.name.local == 'N' && a.value == 'DisplayRoot'))
      .where((n) => n.text == path);
  if (mount.isEmpty) {
    return null;
  }
  var driveLetter = mount.first.parent.children
      .singleWhere((n) =>
          n.attributes.any((a) => a.name.local == 'N' && a.value == 'Name'))
      .text;
  return Mounted(driveLetter, path);
}

Future<void> packerBuild({
  String packerFilePath,
  String tplFilePath,
  Map<String, String> variables,
  Map<String, String> environment,
  Future<Map<String, dynamic>> Function(Map<String, dynamic>) packerFileMods,
}) async {
  log('parsing ${packerFilePath}');
  Map<String, dynamic> packerFile = json.decode(json.encode(loadYaml(
    await File(packerFilePath).readAsString(),
  )));

  log('injecting variables into packerfile');
  packerFile['min_packer_version'] = await getToolVersion('packer');
  for (var e in variables.entries) {
    packerFile['variables'][e.key] = e.value;
  }
  if (packerFileMods != null) packerFile = await packerFileMods(packerFile);

  log('generating ${tplFilePath} => ${tplFilePath.replaceFirst('.tpl', '')}');
  var tpl = await File(tplFilePath).readAsString();
  for (var e in variables.entries) {
    tpl = tpl.replaceAll('{{${e.key}}}', e.value);
  }
  await File(tplFilePath.replaceFirst('.tpl', '')).writeAsString(tpl);

  log('starting packer');
  var packer = dexeca(
    'packer',
    ['build', '-force', '-'],
    workingDirectory: p.dirname(packerFilePath),
    environment: environment ?? {},
  );

  packer.stdin.writeln(jsonEncode(packerFile));
  await packer.stdin.flush();
  await packer.stdin.close();

  await packer;

  log('cleanup ${tplFilePath.replaceFirst('.tpl', '')}');
  await File(tplFilePath.replaceFirst('.tpl', '')).delete();
}

// prefix: TURN THIS INTO A STANDALONE DART PACKAGE
// -----------------------------------------------------------------------------
void log(String message, {String prefix}) {
  prefix ??= Trace.current().frames[1].member.paramCase;

  if (!_prefixToColor.containsKey(prefix)) {
    var availableColors = <int>[];
    var choosenColors = _prefixToColor.values;
    if (choosenColors.length >= _allColors.length) {
      // We reached the maximum number of available colors so
      // we will just have to reuse a color.
      availableColors = _allColors;
    } else {
      // Restrict avaliable color to ones we have not used yet
      for (var color in _allColors) {
        if (!choosenColors.contains(color)) {
          availableColors.add(color);
        }
      }
    }

    // Choose a new color
    int choosen;
    if (availableColors.length == 1) {
      choosen = availableColors[0];
    } else {
      choosen = availableColors[Random().nextInt(availableColors.length)];
    }
    _prefixToColor[prefix] = choosen;
  }

  var pen = AnsiPen()..xterm(_prefixToColor[prefix]);
  print('${pen(prefix)} | ${message}');
  File(p.absolute(normalisePath('./logs/drun.txt'))).writeAsStringSync(
      '${DateTime.now().toIso8601String()} - ${prefix} | ${message}\n',
      mode: FileMode.append);
}

var _allColors = <int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
var _prefixToColor = <String, int>{};
// -----------------------------------------------------------------------------

// pwsh: TURN THIS INTO A STANDALONE DART PACKAGE
// -----------------------------------------------------------------------------
// plus some sort of sudo thing that actually works.
// ie: no second console window, stream all io back to the unprivilaged proc.
Process powershell(
  String script, {
  bool elevated = false,
  bool inheritStdio = true,
}) {
  if (elevated && !waitFor(isElevated())) {
    return powershell('''
    Start-Process powershell -Wait -Verb RunAs `
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

Future<bool> isElevated() async {
  var result = await powershell(
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
// -----------------------------------------------------------------------------

Future<bool> nssmServiceExists(String name) async {
  try {
    await dexeca('nssm', ['status', name], inheritStdio: false);
  } on ProcessResult {
    return false;
  }
  return true;
}
