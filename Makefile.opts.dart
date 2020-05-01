import 'dart:io';
import 'dart:convert';
import './Makefile.utils.dart';
import 'package:drun/drun.dart';

class Options extends GlobalOptions {
  @Values(['hv', 'hv-win', 'ec2', 'ec2-win'])
  static String get type {
    return GlobalOptions.value ?? 'hv';
  }

  static String get name {
    return GlobalOptions.value ?? 'dev-server-${type}';
  }

  static String get domain {
    return GlobalOptions.value ?? 'local';
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

  static String get sshTunnelServiceName {
    return GlobalOptions.value ?? 'dev-server-ssh-tunnel-${name}';
  }

  @Required()
  @Env('LOCALAPPDATA')
  static String get localAppData {
    return GlobalOptions.value;
  }

  static String get hyperVDir {
    return normalisePath(GlobalOptions.value ?? '~/.hyperv');
  }

  @Env('AWS_PROFILE')
  static String get awsProfile {
    return GlobalOptions.value;
  }

  @Env('AWS_TAGS')
  static Map<String, String> get awsTags {
    var v = GlobalOptions.value;
    return v != null ? jsonDecode(v).cast<String, String>() : null;
  }

  static String get repoRoot {
    var path = Directory.current.path;
    while (!Directory('${path}/.git').existsSync()) {
      path = Directory.current.parent.path;
    }
    return path;
  }
}
