// Copyright 2019 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:github/github.dart';
import 'package:meta/meta.dart';
import 'package:yaml/yaml.dart';

import '../request_handling/api_request_handler.dart';
import '../request_handling/authentication.dart';
import '../request_handling/body.dart';
import '../service/bigquery.dart';
import '../service/config.dart';
import '../service/github_service.dart';
import 'flaky_handler_utils.dart';

/// A handler that queries build statistics from luci and file issues and pull
/// requests for tests that have high flaky ratios.
///
/// The query parameter kThresholdKey is required for this handler to use it as
/// the standard when compares the flaky ratios.
@immutable
class FileFlakyIssueAndPR extends ApiRequestHandler<Body> {
  const FileFlakyIssueAndPR(Config config, AuthenticationProvider authenticationProvider)
      : super(config: config, authenticationProvider: authenticationProvider);

  static const String kThresholdKey = 'threshold';

  static const String kCiYamlPath = '.ci.yaml';
  static const String _ciYamlTargetsKey = 'targets';
  static const String _ciYamlTargetBuilderKey = 'builder';
  static const String _ciYamlTargetIsFlakyKey = 'bringup';
  static const String _ciYamlPropertiesKey = 'properties';
  static const String _ciYamlTargetTagsKey = 'tags';
  static const String _ciYamlTargetTagsShard = 'shard';
  static const String _ciYamlTargetTagsDevicelab = 'devicelab';
  static const String _ciYamlTargetTagsFramework = 'framework';
  static const String _ciYamlTargetTagsHostonly = 'hostonly';

  static const String kTestOwnerPath = 'TESTOWNERS';

  static const String kMasterRefs = 'heads/master';
  static const String kModifyMode = '100755';
  static const String kModifyType = 'blob';

  static const int kGracePeriodForClosedFlake = 15; // days

  @override
  Future<Body> get() async {
    final RepositorySlug slug = config.flutterSlug;
    final GithubService gitHub = config.createGithubServiceWithToken(await config.githubOAuthToken);
    final BigqueryService bigquery = await config.createBigQueryService();
    final List<BuilderStatistic> builderStatisticList = await bigquery.listBuilderStatistic(kBigQueryProjectId);
    final YamlMap ci = loadYaml(await gitHub.getFileContent(slug, kCiYamlPath)) as YamlMap;
    final String testOwnerContent = await gitHub.getFileContent(slug, kTestOwnerPath);
    final Map<String, Issue> nameToExistingIssue = await getExistingIssues(gitHub, slug);
    final Map<String, PullRequest> nameToExistingPR = await getExistingPRs(gitHub, slug);
    for (final BuilderStatistic statistic in builderStatisticList) {
      if (statistic.flakyRate < _threshold) {
        continue;
      }
      final _BuilderType type = _getTypeFromTags(_getTags(statistic.name, ci));
      await _fileIssueAndPR(
        gitHub,
        slug,
        builderDetail: _BuilderDetail(
            statistic: statistic,
            existingIssue: nameToExistingIssue[statistic.name],
            existingPullRequest: nameToExistingPR[statistic.name],
            isMarkedFlaky: _getIsMarkedFlaky(statistic.name, ci),
            type: type,
            owner: _getTestOwner(statistic.name, type, testOwnerContent)),
      );
    }
    return Body.forJson(const <String, dynamic>{
      'Status': 'success',
    });
  }

  double get _threshold => double.parse(request.uri.queryParameters[kThresholdKey]);

  Future<void> _fileIssueAndPR(
    GithubService gitHub,
    RepositorySlug slug, {
    @required _BuilderDetail builderDetail,
  }) async {
    Issue issue = builderDetail.existingIssue;
    // Don't create a new issue if there is a recent closed issue within
    // kGracePeriodForClosedFlake days. It takes time for the flaky ratio to go
    // down after the fix is merged.
    if (issue == null ||
        (issue.state == 'closed' &&
            DateTime.now().difference(issue.closedAt) > const Duration(days: kGracePeriodForClosedFlake))) {
      final IssueBuilder issueBuilder = IssueBuilder(statistic: builderDetail.statistic, threshold: _threshold);
      issue = await gitHub.createIssue(
        slug,
        title: issueBuilder.issueTitle,
        body: issueBuilder.issueBody,
        labels: issueBuilder.issueLabels,
        assignee: builderDetail.owner,
      );
    }

    if (issue == null ||
        builderDetail.type == _BuilderType.shard ||
        builderDetail.existingPullRequest != null ||
        builderDetail.isMarkedFlaky) {
      return;
    }
    final String modifiedContent = _marksBuildFlakyInContent(
        await gitHub.getFileContent(slug, kCiYamlPath), builderDetail.statistic.name, issue.htmlUrl);
    final GitReference masterRef = await gitHub.getReference(slug, kMasterRefs);
    final PullRequestBuilder prBuilder = PullRequestBuilder(statistic: builderDetail.statistic, issue: issue);
    final PullRequest pullRequest = await gitHub.createPullRequest(slug,
        title: prBuilder.pullRequestTitle,
        body: prBuilder.pullRequestBody,
        commitMessage: prBuilder.pullRequestTitle,
        baseRef: masterRef,
        entries: <CreateGitTreeEntry>[
          CreateGitTreeEntry(
            kCiYamlPath,
            kModifyMode,
            kModifyType,
            content: modifiedContent,
          )
        ]);
    await gitHub.assignReviewer(slug, reviewer: builderDetail.owner, pullRequestNumber: pullRequest.number);
  }

  bool _getIsMarkedFlaky(String builderName, YamlMap ci) {
    final YamlList targets = ci[_ciYamlTargetsKey] as YamlList;
    final YamlMap target = targets.firstWhere(
      (dynamic element) => element[_ciYamlTargetBuilderKey] == builderName,
      orElse: () => null,
    ) as YamlMap;
    return target != null && target[_ciYamlTargetIsFlakyKey] == true;
  }

  List<dynamic> _getTags(String builderName, YamlMap ci) {
    final YamlList targets = ci[_ciYamlTargetsKey] as YamlList;
    final YamlMap target = targets.firstWhere(
      (dynamic element) => element[_ciYamlTargetBuilderKey] == builderName,
      orElse: () => null,
    ) as YamlMap;
    if (target == null) {
      return null;
    }
    return jsonDecode(target[_ciYamlPropertiesKey][_ciYamlTargetTagsKey] as String) as List<dynamic>;
  }

  _BuilderType _getTypeFromTags(List<dynamic> tags) {
    if (tags == null) {
      return _BuilderType.unknown;
    }
    bool hasFrameworkTag = false;
    bool hasHostOnlyTag = false;
    // If tags contain 'shard', it must be a shard test.
    // If tags contain 'devicelab', it must be a devicelab test.
    // Otherwise, it is framework host only test if its tags contain both
    // 'framework' and 'hostonly'.
    for (dynamic tag in tags) {
      if (tag == _ciYamlTargetTagsShard) {
        return _BuilderType.shard;
      } else if (tag == _ciYamlTargetTagsDevicelab) {
        return _BuilderType.devicelab;
      } else if (tag == _ciYamlTargetTagsFramework) {
        hasFrameworkTag = true;
      } else if (tag == _ciYamlTargetTagsHostonly) {
        hasHostOnlyTag = true;
      }
    }
    return hasFrameworkTag && hasHostOnlyTag ? _BuilderType.frameworkHostOnly : _BuilderType.unknown;
  }

  String _getTestNameFromBuilderName(String builderName) {
    // The builder names is in the format '<platform> <test name>'.
    final List<String> words = builderName.split(' ');
    return words.length < 2 ? words[0] : words[1];
  }

  String _getTestOwner(String builderName, _BuilderType type, String testOwnersContent) {
    final String testName = _getTestNameFromBuilderName(builderName);
    String owner;
    switch (type) {
      case _BuilderType.shard:
        {
          // The format looks like this:
          //   # build_tests @zanderso @flutter/tool
          final RegExpMatch match = shardTestOwners.firstMatch(testOwnersContent);
          if (match != null && match.namedGroup(kOwnerGroupName) != null) {
            final List<String> lines =
                match.namedGroup(kOwnerGroupName).split('\n').where((String line) => line.contains('@')).toList();

            for (final String line in lines) {
              final List<String> words = line.trim().split(' ');
              // e.g. words = ['#', 'build_test', '@zanderso' '@flutter/tool']
              if (testName.contains(words[1])) {
                owner = words[2].substring(1); // Strip out the lead '@'
                break;
              }
            }
          }
          break;
        }
      case _BuilderType.devicelab:
        {
          // The format looks like this:
          //   /dev/devicelab/bin/tasks/dart_plugin_registry_test.dart @stuartmorgan @flutter/plugin
          final RegExpMatch match = devicelabTestOwners.firstMatch(testOwnersContent);
          if (match != null && match.namedGroup(kOwnerGroupName) != null) {
            final List<String> lines = match
                .namedGroup(kOwnerGroupName)
                .split('\n')
                .where((String line) => line.isNotEmpty || !line.startsWith('#'))
                .toList();

            for (final String line in lines) {
              final List<String> words = line.trim().split(' ');
              // e.g. words = ['/xxx/xxx/xxx_test.dart', '@stuartmorgan' '@flutter/tool']
              if (words[0].endsWith('$testName.dart')) {
                owner = words[1].substring(1); // Strip out the lead '@'
                break;
              }
            }
          }
          break;
        }
      case _BuilderType.frameworkHostOnly:
        {
          // The format looks like this:
          //   # Linux analyze
          //   /dev/bots/analyze.dart @HansMuller @flutter/framework
          final RegExpMatch match = frameworkHostOnlyTestOwners.firstMatch(testOwnersContent);
          if (match != null && match.namedGroup(kOwnerGroupName) != null) {
            final List<String> lines =
                match.namedGroup(kOwnerGroupName).split('\n').where((String line) => line.isNotEmpty).toList();
            int index = 0;
            while (index < lines.length) {
              if (lines[index].startsWith('#') && index + 1 < lines.length) {
                final List<String> commentWords = lines[index].trim().split(' ');
                // e.g. commentWords = ['#', 'Linux' 'analyze']
                index += 1;
                if (lines[index].startsWith('#')) {
                  // The next line should not be a comment. This can happen if
                  // someone adds an additional comment to framework host only
                  // session.
                  continue;
                }
                if (testName.contains(commentWords[2])) {
                  final List<String> ownerWords = lines[index].trim().split(' ');
                  // e.g. ownerWords = ['/xxx/xxx/xxx_test.dart', '@HansMuller' '@flutter/framework']
                  owner = ownerWords[1].substring(1); // Strip out the lead '@'
                  break;
                }
              }
              index += 1;
            }
          }
          break;
        }
      case _BuilderType.unknown:
        break;
    }
    return owner;
  }

  String _marksBuildFlakyInContent(String content, String builder, String issueUrl) {
    final List<String> lines = content.split('\n');
    final int builderLineNumber = lines.indexWhere((String line) => line.contains('builder: $builder'));
    // Takes care the case if is _ciYamlTargetIsFlakyKey is already defined to false
    int nextLine = builderLineNumber + 1;
    while (nextLine < lines.length && !lines[nextLine].contains('builder:')) {
      if (lines[nextLine].contains('$_ciYamlTargetIsFlakyKey:')) {
        lines[nextLine] = lines[nextLine].replaceFirst('false', 'true # Flaky $issueUrl');
        return lines.join('\n');
      }
      nextLine += 1;
    }
    lines.insert(builderLineNumber + 1, '    $_ciYamlTargetIsFlakyKey: true # Flaky $issueUrl');
    return lines.join('\n');
  }

  Future<RepositorySlug> getSlugFor(GitHub client, String repository) async {
    return RepositorySlug((await client.users.getCurrentUser()).login, repository);
  }
}

class _BuilderDetail {
  const _BuilderDetail({
    @required this.statistic,
    @required this.existingIssue,
    @required this.existingPullRequest,
    @required this.isMarkedFlaky,
    @required this.owner,
    @required this.type,
  });
  final BuilderStatistic statistic;
  final Issue existingIssue;
  final PullRequest existingPullRequest;
  final String owner;
  final bool isMarkedFlaky;
  final _BuilderType type;
}

enum _BuilderType {
  devicelab,
  frameworkHostOnly,
  shard,
  unknown,
}
