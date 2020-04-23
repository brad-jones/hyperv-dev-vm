import 'dart:io';
import 'dart:convert';

import 'package:drun/drun.dart';

import './Makefile.utils.dart';

class Options extends GlobalOptions {
  @Values(['hyperv', 'ec2'])
  static String get type {
    return GlobalOptions.value ?? 'hyperv';
  }

  static String get name {
    return GlobalOptions.value ?? 'dev-server';
  }

  static String get domain {
    return GlobalOptions.value ??
        (type == 'hyperv' ? 'hyper-v.local' : 'remote');
  }

  @Abbr('t')
  static String get tag {
    return GlobalOptions.value ?? 'latest';
  }

  @Env('USERNAME')
  static String get userName {
    return GlobalOptions.value ?? 'packer';
  }

  static String get sshKeyFile {
    return normalisePath(GlobalOptions.value ?? '~/.ssh/id_rsa');
  }

  static String get sshKnownHostsFile {
    return normalisePath(GlobalOptions.value ?? '~/.ssh/known_hosts');
  }

  static String get sshConfigFile {
    return normalisePath(GlobalOptions.value ?? '~/.ssh/config');
  }

  @Required()
  @Env('LOCALAPPDATA')
  static String get localAppData {
    return GlobalOptions.value;
  }

  static String get hyperVDir {
    return normalisePath(GlobalOptions.value ?? '~/.hyperv');
  }

  @Env('AWS_TAGS')
  static Map<String, dynamic> get awsTags {
    var v = GlobalOptions.value;
    return v != null ? jsonDecode(v) : null;
  }

  static String get repoRoot {
    var path = Directory.current.path;
    while (!Directory('${path}/.git').existsSync()) {
      path = Directory.current.parent.path;
    }
    return path;
  }
}
