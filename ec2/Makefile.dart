import 'dart:convert';
import 'dart:io';

import 'package:dexeca/dexeca.dart';
import 'package:drun/drun.dart';
import 'package:retry/retry.dart';

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
    environment: await _getEnvFromAwsVault(Options.awsProfile),
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

Future<void> install([
  bool rebuild = false,
  String instanceSize = 't2.micro',
]) async {
  await uninstall(rebuild);

  var amiId = await _getAmiId('dev-server-${Options.tag}');
  if (amiId == null || rebuild) {
    log('rebuilding image');
    await build();
    amiId = await _getAmiId('dev-server-${Options.tag}');
  }

  log('registering new instance of vm: ${amiId}');
  var instanceId = await _launchEc2(
    amiId: amiId,
    name: '${Options.name}.${Options.domain}',
    tags: Options.awsTags,
    type: instanceSize,
  );

  log('started instance: ${instanceId}');
}

Future<void> uninstall([bool deleteEverything = false]) async {
  log('looking for instance to terminate');
  var instanceId = await _getInstanceId('${Options.name}.${Options.domain}');
  if (instanceId != null) {
    log('terminating: ${instanceId}');
    await _terminateInstance(instanceId);
  }

  log('looking for security group to delete');
  var groupId = await _getSgId('${Options.name}.${Options.domain}');
  if (groupId != null) {
    log('deleting: ${groupId}');
    await _deleteSg(groupId);
  }

  if (deleteEverything) {
    log('looking for ami to delete');
    var amiId = await _getAmiId('dev-server-${Options.tag}');
    if (amiId != null) {
      log('deleting AMI: ${amiId}');
      await _deleteAmi(amiId);
    }

    log('looking for snapshot to delete');
    var snapshotId = await _getSnapShotId('${Options.name}-${Options.tag}');
    if (snapshotId != null) {
      log('deleting snapshot: ${snapshotId}');
      await _deleteSnapShot(snapshotId);
    }
  }
}

Future<void> start([bool wait = false]) async {
  log('looking for instance to start');
  var instanceId = await _getInstanceId('${Options.name}.${Options.domain}');
  if (instanceId != null) {
    log('starting: ${instanceId}');
    await dexeca(
      'aws',
      [
        'ec2',
        'start-instances',
        '--instance-ids',
        instanceId,
      ],
      environment: await _getEnvFromAwsVault(Options.awsProfile),
    );
    if (wait) {
      await dexeca(
        'aws',
        ['ec2', 'wait', 'instance-running', '--instance-ids', instanceId],
        environment: await _getEnvFromAwsVault(Options.awsProfile),
      );
    }
  } else {
    log('nothing to start');
  }
}

Future<void> stop([bool wait = false]) async {
  log('looking for instance to stop');
  var instanceId = await _getInstanceId('${Options.name}.${Options.domain}');
  if (instanceId != null) {
    log('stopping: ${instanceId}');
    await dexeca(
      'aws',
      [
        'ec2',
        'stop-instances',
        '--instance-ids',
        instanceId,
      ],
      environment: await _getEnvFromAwsVault(Options.awsProfile),
    );
    if (wait) {
      await dexeca(
        'aws',
        ['ec2', 'wait', 'instance-stopped', '--instance-ids', instanceId],
        environment: await _getEnvFromAwsVault(Options.awsProfile),
      );
    }
  } else {
    log('nothing to stop');
  }
}

Future<String> ipAddress() async {
  return await retry(() async {
    try {
      log('attempting to get ip address of: ${Options.name}');

      var instanceId =
          await _getInstanceId('${Options.name}.${Options.domain}');
      if (instanceId == null) {
        throw Exception('instance not found');
      }

      var ip = await _getInstanceIp(instanceId);
      log(ip);
      return ip;
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception(e);
    }
  });
}

Future<String> _getInstanceId(String name) async {
  try {
    var proc = await dexeca(
      'aws',
      [
        'ec2',
        'describe-instances',
        '--filters',
        'Name=tag:Name,Values=${name}'
      ],
      environment: await _getEnvFromAwsVault(Options.awsProfile),
      inheritStdio: false,
    );
    var result = jsonDecode(proc.stdout);
    for (var r in result['Reservations']) {
      for (var i in r['Instances']) {
        if (i['State']['Name'] != 'terminated') {
          return i['InstanceId'];
        }
      }
    }
    return null;
  } on ProcessResult catch (e) {
    print(e.stdout);
    print(e.stderr);
    rethrow;
  }
}

Future<String> _getInstanceIp(String id) async {
  try {
    var proc = await dexeca(
      'aws',
      ['ec2', 'describe-instances', '--instance-ids', id],
      environment: await _getEnvFromAwsVault(Options.awsProfile),
      inheritStdio: false,
    );
    return jsonDecode(proc.stdout)['Reservations'][0]['Instances'][0]
        ['PrivateIpAddress'];
  } on ProcessResult catch (e) {
    print(e.stdout);
    print(e.stderr);
    rethrow;
  }
}

Future<String> _getAmiId(String name) async {
  try {
    var proc = await dexeca(
      'aws',
      ['ec2', 'describe-images', '--filters', 'Name=tag:Name,Values=${name}'],
      environment: await _getEnvFromAwsVault(Options.awsProfile),
      inheritStdio: false,
    );
    var result = jsonDecode(proc.stdout);
    return result['Images'].isNotEmpty ? result['Images'][0]['ImageId'] : null;
  } on ProcessResult catch (e) {
    print(e.stdout);
    print(e.stderr);
    rethrow;
  }
}

Future<String> _getSnapShotId(String name) async {
  try {
    var proc = await dexeca(
      'aws',
      [
        'ec2',
        'describe-snapshots',
        '--filters',
        'Name=tag:Name,Values=${name}'
      ],
      environment: await _getEnvFromAwsVault(Options.awsProfile),
      inheritStdio: false,
    );
    var result = jsonDecode(proc.stdout);
    return result['Snapshots'].isNotEmpty
        ? result['Snapshots'][0]['SnapshotId']
        : null;
  } on ProcessResult catch (e) {
    print(e.stdout);
    print(e.stderr);
    rethrow;
  }
}

Future<String> _getSgId(String name) async {
  try {
    var proc = await dexeca(
      'aws',
      [
        'ec2',
        'describe-security-groups',
        '--filters',
        'Name=tag:Name,Values=${name}'
      ],
      environment: await _getEnvFromAwsVault(Options.awsProfile),
      inheritStdio: false,
    );
    var result = jsonDecode(proc.stdout);
    return result['SecurityGroups'].isNotEmpty
        ? result['SecurityGroups'][0]['GroupId']
        : null;
  } on ProcessResult catch (e) {
    print(e.stdout);
    print(e.stderr);
    rethrow;
  }
}

Future<void> _terminateInstance(String id) async {
  await dexeca(
    'aws',
    ['ec2', 'terminate-instances', '--instance-ids', id],
    environment: await _getEnvFromAwsVault(Options.awsProfile),
  );
  await dexeca(
    'aws',
    ['ec2', 'wait', 'instance-terminated', '--instance-ids', id],
    environment: await _getEnvFromAwsVault(Options.awsProfile),
  );
}

Future<void> _deleteAmi(String id) async {
  await dexeca(
    'aws',
    ['ec2', 'deregister-image', '--image-id', id],
    environment: await _getEnvFromAwsVault(Options.awsProfile),
  );
}

Future<void> _deleteSnapShot(String id) async {
  await dexeca(
    'aws',
    ['ec2', 'delete-snapshot', '--snapshot-id', id],
    environment: await _getEnvFromAwsVault(Options.awsProfile),
  );
}

Future<void> _deleteSg(String id) async {
  await dexeca(
    'aws',
    ['ec2', 'delete-security-group', '--group-id', id],
    environment: await _getEnvFromAwsVault(Options.awsProfile),
  );
}

String _vpcId;
Future<String> _getVpcId() async {
  if (_vpcId != null) return _vpcId;
  try {
    var proc = await dexeca(
      'aws',
      ['ec2', 'describe-vpcs'],
      environment: await _getEnvFromAwsVault(Options.awsProfile),
      inheritStdio: false,
    );
    var result = jsonDecode(proc.stdout);
    _vpcId = result['Vpcs'].isNotEmpty ? result['Vpcs'][0]['VpcId'] : null;
    log('vpc: ${_vpcId}');
    return _vpcId;
  } on ProcessResult catch (e) {
    print(e.stdout);
    print(e.stderr);
    rethrow;
  }
}

Map<String, String> _subnetIds = {};
Future<String> _getSubnetId(String vpcId) async {
  if (_subnetIds.containsKey(vpcId)) return _subnetIds[vpcId];
  try {
    var proc = await dexeca(
      'aws',
      ['ec2', 'describe-subnets', '--filters', 'Name=vpc-id,Values=${vpcId}'],
      environment: await _getEnvFromAwsVault(Options.awsProfile),
      inheritStdio: false,
    );
    var result = jsonDecode(proc.stdout);
    _subnetIds[vpcId] =
        result['Subnets'].isNotEmpty ? result['Subnets'][0]['SubnetId'] : null;
    log('subnet: ${_subnetIds[vpcId]}');
    return _subnetIds[vpcId];
  } on ProcessResult catch (e) {
    print(e.stdout);
    print(e.stderr);
    rethrow;
  }
}

Future<String> _createSecurityGroup(String name,
    {Map<String, String> tags}) async {
  String groupId;

  try {
    var proc = await dexeca(
      'aws',
      [
        'ec2',
        'create-security-group',
        '--group-name',
        name,
        '--vpc-id',
        await _getVpcId(),
        '--description',
        'rules for dev-server',
      ],
      environment: await _getEnvFromAwsVault(Options.awsProfile),
      inheritStdio: false,
    );
    groupId = jsonDecode(proc.stdout)['GroupId'];
    log('security-group: ${groupId}');
  } on ProcessResult catch (e) {
    print(e.stdout);
    print(e.stderr);
    rethrow;
  }

  log('adding security group ingress rules');
  await dexeca(
    'aws',
    [
      'ec2',
      'authorize-security-group-ingress',
      '--group-id',
      groupId,
      '--cidr',
      '0.0.0.0/0',
      '--protocol',
      'tcp',
      '--port',
      '22',
    ],
    environment: await _getEnvFromAwsVault(Options.awsProfile),
  );

  if (tags?.isNotEmpty ?? false) {
    log('tagging security group');
    var args = [
      'ec2',
      'create-tags',
      '--resources',
      groupId,
      '--tags',
    ];
    for (var e in tags.entries) {
      args.add('Key=${e.key},Value=${e.value}');
    }
    await dexeca(
      'aws',
      args,
      environment: await _getEnvFromAwsVault(Options.awsProfile),
    );
  }

  return groupId;
}

Future<dynamic> _launchEc2({
  String amiId,
  String name,
  String type = 't2.micro',
  Map<String, String> tags,
}) async {
  try {
    var tagString = '';
    tags['Name'] = name;
    for (var e in tags.entries) {
      tagString = '${tagString}{Key=${e.key},Value=${e.value}},';
    }
    tagString = tagString.substring(0, tagString.length - 1);

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
        await _createSecurityGroup(name, tags: tags),
        '--subnet-id',
        await _getSubnetId(await _getVpcId()),
        '--tag-specifications',
        'ResourceType=instance,Tags=[${tagString}]',
        'ResourceType=volume,Tags=[${tagString}]',
      ],
      inheritStdio: false,
      environment: await _getEnvFromAwsVault(Options.awsProfile),
    );
    return jsonDecode(proc.stdout)['Instances'][0]['InstanceId'];
  } on ProcessResult catch (e) {
    print(e.stdout);
    print(e.stderr);
    rethrow;
  }
}

Map<String, Map<String, String>> _cachedEnv = {};
Future<Map<String, String>> _getEnvFromAwsVault(String profile) async {
  if (profile?.isEmpty ?? true) {
    return {};
  }

  if (!_cachedEnv.containsKey(profile ?? '')) {
    var env = <String, String>{};

    ProcessResult result;
    try {
      result = await dexeca(
        'dart',
        [
          normalisePath('~/.local/sbin/bin/aws-vault'),
          'exec',
          profile,
          '--',
          'cmd.exe',
          '/C',
          'SET'
        ],
        inheritStdio: false,
      );
    } on ProcessResult catch (e) {
      print(e.stdout);
      print(e.stderr);
      rethrow;
    }

    for (var line in result.stdout.replaceAll('\r\n', '\n').split('\n')) {
      if (line.contains('=') && line.startsWith('AWS_')) {
        var parts = line.split('=');
        env[parts[0]] = parts[1];
      }
    }

    _cachedEnv[profile] = env;
  }

  return _cachedEnv[profile];
}
