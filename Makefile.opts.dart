import 'dart:io';
import './Makefile.utils.dart';
import 'package:drun/drun.dart';

class Options extends GlobalOptions {
  static String get name {
    return GlobalOptions.value ?? 'dev-server';
  }

  static String get domain {
    return GlobalOptions.value ?? 'wslhv.local';
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

  static String get sshConfigFile {
    return normalisePath(GlobalOptions.value ?? '~/.ssh/config');
  }

  static String get sshKnownHostsFile {
    return normalisePath(GlobalOptions.value ?? '~/.ssh/known_hosts');
  }

  static String get sshAuthorizedKeysFile {
    return normalisePath(GlobalOptions.value ?? '~/.ssh/authorized_keys');
  }

  @Required()
  @Env('LOCALAPPDATA')
  static String get localAppData {
    return GlobalOptions.value;
  }

  static String get hyperVDir {
    return normalisePath(GlobalOptions.value ?? '~/.hyperv');
  }

  static String get repoRoot {
    var path = Directory.current.path;
    while (!Directory('${path}/.git').existsSync()) {
      path = Directory.current.parent.path;
    }
    return path;
  }
}
