import 'dart:io';
import 'dart:convert';
import '../Makefile.opts.dart';
import './Makefile.utils.dart';
import 'package:drun/drun.dart';
import '../Makefile.utils.dart';
import 'package:retry/retry.dart';
import 'package:dexeca/dexeca.dart';

Future<void> main(List<String> argv) => drun(argv);

/// Using `packer` builds a new ec2 AMI Image.
Future<void> build([
  String instanceType = 't3.micro',
  String vpcFilter = '*',
  String subnetFilter = '*',
]) async {
  await packerBuild(
    environment: await getEnvFromAwsVault(Options.awsProfile),
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
  String instanceSize = 't3.micro',
]) async {
  await uninstall(rebuild);

  var amiId = await getAmiId('dev-server-${Options.tag}');
  if (amiId == null || rebuild) {
    log('rebuilding image');
    await build();
    amiId = await getAmiId('dev-server-${Options.tag}');
  }

  log('registering new instance of vm: ${amiId}');
  var instanceId = await launchEc2(
    amiId: amiId,
    name: '${Options.name}.${Options.domain}',
    tags: Options.awsTags,
    type: instanceSize,
  );

  log('started instance: ${instanceId}');
}

Future<void> uninstall([bool deleteEverything = false]) async {
  log('looking for instance to terminate');
  var instanceId = await getInstanceId('${Options.name}.${Options.domain}');
  if (instanceId != null) {
    log('terminating: ${instanceId}');
    await terminateInstance(instanceId);
  }

  log('looking for security group to delete');
  var groupId = await getSgId('${Options.name}.${Options.domain}');
  if (groupId != null) {
    log('deleting: ${groupId}');
    await deleteSg(groupId);
  }

  if (deleteEverything) {
    log('looking for ami to delete');
    var amiId = await getAmiId('dev-server-${Options.tag}');
    if (amiId != null) {
      log('deleting AMI: ${amiId}');
      await deleteAmi(amiId);
    }

    log('looking for snapshot to delete');
    var snapshotId = await getSnapShotId('${Options.name}-${Options.tag}');
    if (snapshotId != null) {
      log('deleting snapshot: ${snapshotId}');
      await deleteSnapShot(snapshotId);
    }
  }
}

Future<void> start([bool wait = false]) async {
  log('looking for instance to start');
  var instanceId = await getInstanceId('${Options.name}.${Options.domain}');
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
      environment: await getEnvFromAwsVault(Options.awsProfile),
    );
    if (wait) {
      await dexeca(
        'aws',
        ['ec2', 'wait', 'instance-running', '--instance-ids', instanceId],
        environment: await getEnvFromAwsVault(Options.awsProfile),
      );
    }
  } else {
    log('nothing to start');
  }
}

Future<void> stop([bool wait = false]) async {
  log('looking for instance to stop');
  var instanceId = await getInstanceId('${Options.name}.${Options.domain}');
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
      environment: await getEnvFromAwsVault(Options.awsProfile),
    );
    if (wait) {
      await dexeca(
        'aws',
        ['ec2', 'wait', 'instance-stopped', '--instance-ids', instanceId],
        environment: await getEnvFromAwsVault(Options.awsProfile),
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

      var instanceId = await getInstanceId('${Options.name}.${Options.domain}');
      if (instanceId == null) {
        throw Exception('instance not found');
      }

      var ip = await getInstanceIp(instanceId);
      log(ip);
      return ip;
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception(e);
    }
  }, maxAttempts: 100);
}
