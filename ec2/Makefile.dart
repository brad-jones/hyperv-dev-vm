import 'dart:convert';
import 'dart:io';

import 'package:dexeca/dexeca.dart';
import 'package:drun/drun.dart';

import '../Makefile.opts.dart';
import '../Makefile.utils.dart';

Future<void> main(List<String> argv) => drun(argv);

/// Using `packer` builds a new ec2 AMI Image.
Future<void> build([
  String instanceType = 't3.micro',
  String vpcFilter = '*',
  String subnetFilter = '*',
]) async {
  await packerBuild(
    packerFilePath: normalisePath('./ec2/Packerfile.yml'),
    tplFilePath: normalisePath('./ec2/userdata.yml.tpl'),
    variables: {
      'tag': Options.tag,
      'ssh_username': Options.userName,
      'ssh_private_key_file': Options.sshKeyFile,
      'ssh_public_key':
          (await File('${Options.sshKeyFile}.pub').readAsString()).trim(),
      'instance_type': instanceType,
      'vpc_filter': vpcFilter,
      'subnet_filter': subnetFilter,
    },
    packerFileMods: (Map<String, dynamic> packerFile) async {
      if (Options.awsTags?.isNotEmpty ?? false) {
        packerFile['builders'][0]['tags'] = {
          ...packerFile['builders'][0]['tags'],
          ...Options.awsTags,
        };
      }
      return packerFile;
    },
  );
}

Future<void> install([bool rebuild = false]) async {
  await uninstall();

  if (!await _amiExists('${Options.name}-${Options.tag}') || rebuild) {
    await build();
  }

  var amiId = await _getAmiId('${Options.name}-${Options.tag}');
  log('registering new instance of vm: ${amiId}');
}

Future<void> uninstall([bool deleteEverything = false]) async {}

Future<void> start() async {}

Future<void> stop() async {}

Future<String> ipAddress() async {}

Future<String> _getAmiId(String name) async {
  var proc = await dexeca(
    'aws',
    ['ec2', 'describe-images', '--filters', 'Name=name,Values=${name}'],
    inheritStdio: false,
  );
  return jsonDecode(proc.stdout)['Images'][0]['ImageId'];
}

Future<bool> _amiExists(String name) async {
  var proc = await dexeca(
    'aws',
    ['ec2', 'describe-images', '--filters', 'Name=name,Values=${name}'],
    inheritStdio: false,
  );
  return jsonDecode(proc.stdout)['Images'].isNotEmpty;
}

Future<String> _getVpcId() async {}

Future<String> _getSubnetId() async {}

Future<String> _createSecurityGroup(String name) async {
  // aws ec2 create-security-group --group-name name --vpc-id <value> --description "rules for dev-server"
  // aws ec2 authorize-security-group-egress --group-id <value> --cidr 0.0.0.0/0 --protocol -1 --port -1
  // aws ec2 authorize-security-group-ingress --group-id <value> --cidr 0.0.0.0/0 --protocol tcp --port 22
}

Future<String> _launchEc2({
  String amiId,
  String name,
  String type = 't2.micro',
  Map<String, String> tags,
}) async {
  var proc = await dexeca(
    'aws',
    [
      'ec2',
      'run-instances',
      '--image-id',
      amiId,
      '--instance-type',
      type,
      '--security-group-ids',
      await _createSecurityGroup(name),
      '--subnet-id',
      await _getSubnetId(),
    ],
    inheritStdio: false,
  );
  print(proc.stdout);
  return '';
  //return jsonDecode(proc.stdout);
}
