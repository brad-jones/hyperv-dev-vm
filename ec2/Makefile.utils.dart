import 'dart:convert';
import '../Makefile.opts.dart';
import '../Makefile.utils.dart';
import 'package:dexeca/dexeca.dart';

Future<String> getInstanceId(String name) async {
  try {
    var proc = await dexeca(
      'aws',
      [
        'ec2',
        'describe-instances',
        '--filters',
        'Name=tag:Name,Values=${name}'
      ],
      environment: await getEnvFromAwsVault(Options.awsProfile),
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

Future<String> getInstanceIp(String id) async {
  try {
    var proc = await dexeca(
      'aws',
      ['ec2', 'describe-instances', '--instance-ids', id],
      environment: await getEnvFromAwsVault(Options.awsProfile),
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

Future<String> getAmiId(String name) async {
  try {
    var proc = await dexeca(
      'aws',
      ['ec2', 'describe-images', '--filters', 'Name=tag:Name,Values=${name}'],
      environment: await getEnvFromAwsVault(Options.awsProfile),
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

Future<String> getSnapShotId(String name) async {
  try {
    var proc = await dexeca(
      'aws',
      [
        'ec2',
        'describe-snapshots',
        '--filters',
        'Name=tag:Name,Values=${name}'
      ],
      environment: await getEnvFromAwsVault(Options.awsProfile),
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

Future<String> getSgId(String name) async {
  try {
    var proc = await dexeca(
      'aws',
      [
        'ec2',
        'describe-security-groups',
        '--filters',
        'Name=tag:Name,Values=${name}'
      ],
      environment: await getEnvFromAwsVault(Options.awsProfile),
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

Future<void> terminateInstance(String id) async {
  await dexeca(
    'aws',
    ['ec2', 'terminate-instances', '--instance-ids', id],
    environment: await getEnvFromAwsVault(Options.awsProfile),
  );
  await dexeca(
    'aws',
    ['ec2', 'wait', 'instance-terminated', '--instance-ids', id],
    environment: await getEnvFromAwsVault(Options.awsProfile),
  );
}

Future<void> deleteAmi(String id) async {
  await dexeca(
    'aws',
    ['ec2', 'deregister-image', '--image-id', id],
    environment: await getEnvFromAwsVault(Options.awsProfile),
  );
}

Future<void> deleteSnapShot(String id) async {
  await dexeca(
    'aws',
    ['ec2', 'delete-snapshot', '--snapshot-id', id],
    environment: await getEnvFromAwsVault(Options.awsProfile),
  );
}

Future<void> deleteSg(String id) async {
  await dexeca(
    'aws',
    ['ec2', 'delete-security-group', '--group-id', id],
    environment: await getEnvFromAwsVault(Options.awsProfile),
  );
}

String _vpcId;
Future<String> getVpcId() async {
  if (_vpcId != null) return _vpcId;
  try {
    var proc = await dexeca(
      'aws',
      ['ec2', 'describe-vpcs'],
      environment: await getEnvFromAwsVault(Options.awsProfile),
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
Future<String> getSubnetId(String vpcId) async {
  if (_subnetIds.containsKey(vpcId)) return _subnetIds[vpcId];
  try {
    var proc = await dexeca(
      'aws',
      ['ec2', 'describe-subnets', '--filters', 'Name=vpc-id,Values=${vpcId}'],
      environment: await getEnvFromAwsVault(Options.awsProfile),
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

Future<String> createSecurityGroup(
  String name, {
  Map<String, String> tags,
}) async {
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
        await getVpcId(),
        '--description',
        'rules for dev-server',
      ],
      environment: await getEnvFromAwsVault(Options.awsProfile),
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
    environment: await getEnvFromAwsVault(Options.awsProfile),
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
      environment: await getEnvFromAwsVault(Options.awsProfile),
    );
  }

  return groupId;
}

Future<dynamic> launchEc2({
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
        await createSecurityGroup(name, tags: tags),
        '--subnet-id',
        await getSubnetId(await getVpcId()),
        '--tag-specifications',
        'ResourceType=instance,Tags=[${tagString}]',
        'ResourceType=volume,Tags=[${tagString}]',
      ],
      inheritStdio: false,
      environment: await getEnvFromAwsVault(Options.awsProfile),
    );
    return jsonDecode(proc.stdout)['Instances'][0]['InstanceId'];
  } on ProcessResult catch (e) {
    print(e.stdout);
    print(e.stderr);
    rethrow;
  }
}

Map<String, Map<String, String>> _cachedEnv = {};
Future<Map<String, String>> getEnvFromAwsVault(String profile) async {
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
