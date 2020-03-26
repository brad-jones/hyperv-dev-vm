import 'dart:cli';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:ansicolor/ansicolor.dart';
import 'package:dexeca/dexeca.dart';
import 'package:path/path.dart' as p;
import 'package:pretty_json/pretty_json.dart';
import 'package:recase/recase.dart';
import 'package:retry/retry.dart';
import 'package:stack_trace/stack_trace.dart';
import 'package:utf/utf.dart';
import 'package:xml/xml.dart' as xml;

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
}

var _allColors = <int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
var _prefixToColor = <String, int>{};

Future<String> getToolVersion(String tool) async {
  return (await File(p.absolute('.${tool}-version')).readAsString()).trim();
}

String normalisePath(String input) {
  return p.normalize(
    input.replaceFirst(
      '~',
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'],
    ),
  );
}

Future<void> updateWindowsTerminalConfig({
  Future<dynamic> Function(dynamic) updater,
  String localAppData,
}) async {
  var configFile = File(p.join(
    localAppData,
    'Packages',
    'Microsoft.WindowsTerminal_8wekyb3d8bbwe',
    'LocalState',
    'profiles.json',
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

Process powershell(
  String script, {
  bool elevated = false,
  bool inheritStdio = true,
}) {
  if (elevated && !waitFor(isElevated())) {
    return powershell('''
    Start-Process powershell -Verb RunAs `
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

Future<bool> vmExists(String name) async {
  try {
    await powershell('Get-VM "${name}"', inheritStdio: false);
  } on ProcessResult {
    return false;
  }
  return true;
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

Future<String> whoAmI() async {
  var result = await powershell('whoami', inheritStdio: false);
  var doc = xml.parse(result.stdout.replaceFirst('#< CLIXML', ''));
  return doc.descendants
      .singleWhere((n) =>
          n.attributes.any((a) => a.name.local == 'S' && a.value == 'Output'))
      .text;
}

String projectRoot([String cwd]) {
  cwd ??= p.current;
  if (Directory(p.join(cwd, '.git')).existsSync()) {
    return cwd;
  }
  return projectRoot(p.join(cwd, '..'));
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
  });
}
