import 'dart:io';
import 'dart:cli';
import 'dart:math';
import 'dart:convert';
import 'package:utf/utf.dart';
import './Makefile.opts.dart';
import 'package:retry/retry.dart';
import 'package:dexeca/dexeca.dart';
import 'package:recase/recase.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart' as xml;
import 'package:ansicolor/ansicolor.dart';
import 'package:pretty_json/pretty_json.dart';
import 'package:stack_trace/stack_trace.dart';

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

Future<void> del(String path) async {
  path = normalisePath(path);

  if (await Directory(path).exists()) {
    await Directory(path).delete(recursive: true);
    return;
  }

  if (await File(path).exists()) {
    await File(path).delete(recursive: true);
    return;
  }
}

Future<String> whoAmI() async {
  var result = await powershell('whoami', inheritStdio: false);
  var doc = xml.parse(result.stdout.replaceFirst('#< CLIXML', ''));
  return doc.descendants
      .singleWhere((n) =>
          n.attributes.any((a) => a.name.local == 'S' && a.value == 'Output'))
      .text;
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

Future<bool> cmdExists(String name) async {
  var result = await powershell('''
    function Test-CommandExists {
      param(\$Command);
      \$oldPreference = \$ErrorActionPreference;
      \$ErrorActionPreference = 'stop';
      try {if(Get-Command \$Command){return \$true}}
      catch {return \$false}
      finally {\$ErrorActionPreference=\$oldPreference}
    }
    Test-CommandExists -Command "${name}" | Write-Output;
    ''', inheritStdio: false);
  var doc = xml.parse(result.stdout.replaceFirst('#< CLIXML', ''));
  return doc.descendants
          .singleWhere((n) => n.attributes
              .any((a) => a.name.local == 'S' && a.value == 'Output'))
          .text ==
      'true';
}

Future<bool> scoopPackageExists(String name) async {
  var result = await powershell('scoop list ${name}', inheritStdio: false);
  var doc = xml.parse(result.stdout.replaceFirst('#< CLIXML', ''));
  return doc.descendants
      .where((n) =>
          n.attributes.any((a) => a.name.local == 'S' && a.value == 'Output'))
      .any((n) => n.text.trim() == name);
}

Future<bool> scoopBucketExists(String name) async {
  var result = await powershell('scoop bucket list', inheritStdio: false);
  var doc = xml.parse(result.stdout.replaceFirst('#< CLIXML', ''));
  return doc.descendants
      .where((n) =>
          n.attributes.any((a) => a.name.local == 'S' && a.value == 'Output'))
      .any((n) => n.text.trim() == name);
}

Future<void> installScoop() async {
  if (await cmdExists('scoop')) {
    log('scoop in already installed, nothing to do');
    return;
  }

  await powershell('''
    Set-ExecutionPolicy RemoteSigned -scope CurrentUser;
    iwr -useb get.scoop.sh | iex;
  ''');
}

Future<void> installScoopPackage(
  String name, {
  String version,
  String bucket,
}) async {
  await installScoop();

  if (bucket != null) {
    if (await scoopBucketExists(bucket)) {
      log('scoop bucket ${bucket} already exists, nothing to do');
    } else {
      log('adding scoop bucket ${bucket}');
      await powershell('scoop bucket add ${bucket}');
    }
  }

  if (await scoopPackageExists(name)) {
    log('scoop package ${name} already installed, nothing to do');
    return;
  }

  version = version == null ? '' : '@${version}';
  await powershell('scoop install ${name}${version}');
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

Future<bool> nssmServiceExists(String name) async {
  try {
    await dexeca('nssm', ['status', name], inheritStdio: false);
  } on ProcessResult {
    return false;
  }
  return true;
}

Future<bool> vmExists(String name) async {
  try {
    await powershell('Get-VM "${name}"', inheritStdio: false);
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
  Directory(normalisePath('./logs')).createSync(recursive: true);
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
